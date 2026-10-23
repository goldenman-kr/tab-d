import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit
import VideoToolbox

/// Captures one virtual display. Callbacks run on the private serial video queue.
/// The transport must preserve callback order and must never discard H.264 reference frames.
// Set callbacks before start and keep them installed until stop returns. Mutable
// capture/encoder state is confined to queue; framework callbacks hop onto it.
final class DisplayStreamer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onConfig: (([String: Any]) -> Void)?
    var onVideo: ((Data) -> Void)?
    /// The coordinator must compare this source epoch again after hopping queues.
    var onError: ((UInt32, String, Bool) -> Void)?
    var onStats: (([String: Any]) -> Void)?

    private let queue = DispatchQueue(label: "xyz.kryp.app.tabd.video", qos: .userInteractive)
    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var generation: UInt64 = 0
    private var epoch: UInt32 = 0
    private var width = 0
    private var height = 0
    private var sequence: UInt64 = 0
    private var encoding = false
    private var forceKeyFrame = true
    private var hardware = false
    private var encoderID = ""
    private var configuration: Data?
    private var lastStatsTime = ProcessInfo.processInfo.systemUptime
    private var submittedFrames = 0
    private var encodedFrames = 0
    private var skippedFrames = 0
    private var encodedBytes = 0
    private var latestImage: CVPixelBuffer?
    private var lastSubmittedPTS: CMTime = .invalid

    private struct VideoError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private final class FrameContext {
        weak var owner: DisplayStreamer?
        let generation: UInt64
        let epoch: UInt32
        #if TABD_VIDEO_TESTING
        var testCallback: ((OSStatus, VTEncodeInfoFlags, CMSampleBuffer?) -> Void)?
        #endif
        init(owner: DisplayStreamer, generation: UInt64, epoch: UInt32) {
            self.owner = owner
            self.generation = generation
            self.epoch = epoch
        }
    }

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, epoch: UInt32) async throws {
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width % 2 == 0, height % 2 == 0 else {
            throw VideoError(message: "Video dimensions must be even and between 2 and 8192 pixels.")
        }
        await stop()
        let expectedGeneration: UInt64 = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.generation) }
        }
        let content: SCShareableContent = try await FrameworkDeadline.wait(seconds: 6, operation: "display discovery") { completion in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
                if let error { completion(.failure(error)) }
                else if let content { completion(.success(content)) }
                else { completion(.failure(VideoError(message: "ScreenCaptureKit returned no shareable content."))) }
            }
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw VideoError(message: "The Tab-D display is not available to ScreenCaptureKit (ID \(displayID)).")
        }
        let prepared: (SCStream, UInt64) = try await withCurrentGeneration(expectedGeneration) {
            do {
                self.generation &+= 1
                self.epoch = epoch
                self.width = width
                self.height = height
                self.sequence = 0
                self.encoding = false
                self.forceKeyFrame = true
                self.configuration = nil
                self.latestImage = nil
                self.lastSubmittedPTS = .invalid
                self.submittedFrames = 0
                self.encodedFrames = 0
                self.skippedFrames = 0
                self.encodedBytes = 0
                self.lastStatsTime = ProcessInfo.processInfo.systemUptime
                self.encoder = try self.makeEncoder(width: width, height: height)
                let settings = SCStreamConfiguration()
                settings.width = width
                settings.height = height
                settings.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                settings.queueDepth = 3
                settings.pixelFormat = kCVPixelFormatType_32BGRA
                settings.colorSpaceName = CGColorSpace.sRGB
                settings.showsCursor = true
                settings.capturesAudio = false
                settings.scalesToFit = true
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let capture = SCStream(filter: filter, configuration: settings, delegate: self)
                try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                self.stream = capture
                return (capture, self.generation)
            } catch {
                self.invalidateEncoder()
                throw error
            }
        }
        do {
            let capture = prepared.0
            let _: Void = try await FrameworkDeadline.wait(seconds: 6, operation: "capture start",
                onLateSuccess: { [weak capture] _ in
                    // A timed-out start can still succeed later. Stop that exact
                    // obsolete stream, without touching a replacement generation.
                    capture?.stopCapture(completionHandler: { _ in })
                }) { completion in
                    capture.startCapture { error in
                        if let error { completion(.failure(error)) }
                        else { completion(.success(())) }
                    }
                }
            let active = await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: self.generation == prepared.1 && self.stream === prepared.0) }
            }
            guard active else {
                throw CancellationError()
            }
        } catch {
            await discardIfCurrent(prepared.1)
            await Self.stopCaptureBounded(prepared.0)
            throw error
        }
    }

    func stop() async {
        let capture: SCStream? = await withCheckedContinuation { continuation in
            queue.async {
                self.generation &+= 1
                let capture = self.stream
                self.stream = nil
                self.invalidateEncoder()
                continuation.resume(returning: capture)
            }
        }
        if let capture { await Self.stopCaptureBounded(capture) }
    }

    private static func stopCaptureBounded(_ capture: SCStream) async {
        let _: Void? = try? await FrameworkDeadline.wait(seconds: 2, operation: "capture stop") { completion in
            capture.stopCapture { error in
                if let error { completion(.failure(error)) }
                else { completion(.success(())) }
            }
        }
    }

    /// All setup after discovery must cross this queue-confined generation gate.
    /// stop() can invalidate a pending discovery without creating an old encoder.
    private func withCurrentGeneration<Value>(_ token: UInt64, action: @escaping () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.generation == token else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do { continuation.resume(returning: try action()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func requestKeyFrame(expectedEpoch: UInt32) {
        queue.async {
            guard self.epoch == expectedEpoch, self.stream != nil else { return }
            self.forceKeyFrame = true
            // ScreenCaptureKit reports idle frames for an unchanged desktop.
            // Resubmit the latest image so decoder recovery does not require motion.
            if let image = self.latestImage, !self.encoding {
                self.encode(image, pts: CMClockGetTime(CMClockGetHostTimeClock()))
            }
        }
    }

    private func discardIfCurrent(_ token: UInt64) async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.generation == token {
                    self.generation &+= 1
                    self.stream = nil
                    self.invalidateEncoder()
                }
                continuation.resume()
            }
        }
    }

    private func invalidateEncoder() {
        if let encoder {
            // Callers invalidate the generation before arriving here. CompleteFrames
            // returns retained source-frame contexts before the session is released.
            VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(encoder)
        }
        encoder = nil
        encoding = false
        configuration = nil
        latestImage = nil
        lastSubmittedPTS = .invalid
    }

    private func makeEncoder(width: Int, height: Int, profile: CFString = kVTProfileLevel_H264_High_AutoLevel,
                             referenceBufferCount: Int? = nil) throws -> VTCompressionSession {
        var session: VTCompressionSession?
        // On the tested M4/macOS 26.6.2, EnableLowLatencyRateControl chooses an
        // rtvc encoder that cannot report hardware use. RealTime + no reordering
        // keeps the verified hardware encoder; do not silently assume rtvc is HW.
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
        ]
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, compressedDataAllocator: nil,
            outputCallback: { _, sourceFrame, status, flags, sample in
                guard let sourceFrame else { return }
                let context = Unmanaged<FrameContext>.fromOpaque(sourceFrame).takeRetainedValue()
                #if TABD_VIDEO_TESTING
                if let callback = context.testCallback {
                    callback(status, flags, sample)
                    return
                }
                #endif
                guard let owner = context.owner else { return }
                owner.queue.async {
                    guard owner.generation == context.generation, owner.epoch == context.epoch,
                          owner.stream != nil else { return }
                    owner.encoding = false
                    if status != noErr {
                        owner.reportError("H.264 encoding failed (\(status)).", epoch: context.epoch, generation: context.generation)
                        return
                    }
                    guard !flags.contains(.frameDropped), let sample else {
                        owner.forceKeyFrame = true
                        return
                    }
                    do {
                        try owner.deliver(sample)
                        if owner.forceKeyFrame, let image = owner.latestImage {
                            owner.encode(image, pts: CMClockGetTime(CMClockGetHostTimeClock()))
                        }
                    }
                    catch {
                        owner.forceKeyFrame = true
                        owner.reportError(error.localizedDescription, epoch: context.epoch, generation: context.generation)
                    }
                }
            }, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else {
            throw VideoError(message: "Hardware H.264 encoder creation failed (\(status)).")
        }
        do {
            let properties: [CFString: Any] = [
                kVTCompressionPropertyKey_RealTime: true,
                kVTCompressionPropertyKey_AllowFrameReordering: false,
                kVTCompressionPropertyKey_ProfileLevel: profile,
                kVTCompressionPropertyKey_ExpectedFrameRate: 60,
                kVTCompressionPropertyKey_MaxKeyFrameInterval: 120,
                kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
                kVTCompressionPropertyKey_AverageBitRate: width * height > 3_000_000 ? 40_000_000 : 16_000_000,
                kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_sRGB,
                kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2
            ]
            for (key, value) in properties {
                let result = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
                guard result == noErr else { throw VideoError(message: "Encoder property \(key) failed (\(result)).") }
            }
            if let referenceBufferCount {
                let result = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ReferenceBufferCount,
                    value: referenceBufferCount as CFNumber)
                guard result == noErr else { throw VideoError(message: "Encoder ReferenceBufferCount failed (\(result)).") }
            }
            let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
            guard prepared == noErr else { throw VideoError(message: "Encoder preparation failed (\(prepared)).") }
            var acceleration: Unmanaged<CFTypeRef>?
            let queried = VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                allocator: kCFAllocatorDefault, valueOut: &acceleration)
            let accelerationValue = acceleration?.takeRetainedValue()
            hardware = queried == noErr && (accelerationValue as? Bool == true)
            guard hardware else { throw VideoError(message: "Hardware encoder use could not be verified (\(queried)).") }
            var identifier: Unmanaged<CFTypeRef>?
            _ = VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_EncoderID,
                allocator: kCFAllocatorDefault, valueOut: &identifier)
            encoderID = identifier?.takeRetainedValue() as? String ?? "unknown"
            return session
        } catch {
            VTCompressionSessionInvalidate(session)
            throw error
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, self.stream === stream, sampleBuffer.isValid,
              let image = CMSampleBufferGetImageBuffer(sampleBuffer), encoder != nil else { return }
        let frameEpoch = epoch
        let frameGeneration = generation
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let status = attachments.first?[.status] as? Int, status != SCFrameStatus.complete.rawValue { return }
        guard CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height else {
            reportError("Capture returned unexpected dimensions \(CVPixelBufferGetWidth(image))×\(CVPixelBufferGetHeight(image)).",
                epoch: frameEpoch, generation: frameGeneration)
            return
        }
        latestImage = image
        encode(image, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    private func encode(_ image: CVPixelBuffer, pts: CMTime) {
        guard let encoder, stream != nil else { return }
        guard !encoding else { skippedFrames += 1; return }
        guard pts.isNumeric else { return }
        if lastSubmittedPTS.isNumeric, CMTimeCompare(pts, lastSubmittedPTS) <= 0 { return }
        lastSubmittedPTS = pts
        encoding = true
        submittedFrames += 1
        let frameEpoch = epoch
        let frameGeneration = generation
        let context = Unmanaged.passRetained(FrameContext(owner: self, generation: frameGeneration, epoch: frameEpoch))
        let options: CFDictionary? = forceKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKeyFrame = false
        let status = VTCompressionSessionEncodeFrame(encoder, imageBuffer: image,
            presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: 60), frameProperties: options,
            sourceFrameRefcon: context.toOpaque(), infoFlagsOut: nil)
        if status != noErr {
            context.release()
            encoding = false
            forceKeyFrame = true
            reportError("Submitting a captured frame failed (\(status)).", epoch: frameEpoch, generation: frameGeneration)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard self.stream === stream else { return }
            let stoppedEpoch = self.epoch
            self.generation &+= 1
            self.stream = nil
            self.invalidateEncoder()
            // The source stream was verified before teardown. Keep its epoch even
            // if the coordinator processes this callback after a new start.
            self.onError?(stoppedEpoch, "Display capture stopped: \(error.localizedDescription)",
                          Self.canAutomaticallyRecover(error))
        }
    }

    private func reportError(_ message: String, epoch errorEpoch: UInt32, generation errorGeneration: UInt64) {
        guard epoch == errorEpoch, generation == errorGeneration else { return }
        onError?(errorEpoch, message, true)
    }

    /// User intent and authorization failures must survive NSError wrapping and
    /// must not trigger automatic capture restart after an OS Stop action.
    static func canAutomaticallyRecover(_ error: Error) -> Bool {
        var current = error as NSError
        var visited: Set<ObjectIdentifier> = []
        while visited.insert(ObjectIdentifier(current)).inserted {
            if current.domain == SCStreamErrorDomain,
               let code = SCStreamError.Code(rawValue: current.code),
               code == .userStopped || code == .userDeclined || code == .missingEntitlements {
                return false
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? Error else { break }
            current = underlying as NSError
        }
        return true
    }

    private func deliver(_ sample: CMSampleBuffer) throws {
        guard CMSampleBufferDataIsReady(sample), let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var nalHeaderLength: Int32 = 0
        let originalSPS = try parameterSet(format, index: 0, nalHeaderLength: &nalHeaderLength)
        let sps = try H264SPS.declaringNoReordering(originalSPS)
        let pps = try parameterSet(format, index: 1, nalHeaderLength: &nalHeaderLength)
        var signature = sps
        signature.append(pps)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        // A decoder-ready acknowledgement requests an IDR. Repeating identical
        // configuration for that IDR would trigger a configure/ready/IDR loop.
        // New starts clear configuration; changed parameter sets resend it.
        if configuration != signature {
            configuration = signature
            onConfig?(["type": "videoConfig", "epoch": epoch, "width": width, "height": height,
                "csd0": sps.base64EncodedString(), "csd1": pps.base64EncodedString(), "hardware": hardware,
                "encoderID": encoderID, "latencyMode": "realtime-no-reordering"])
        }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length <= 32 * 1024 * 1024 else { throw VideoError(message: "Invalid encoded frame length.") }
        var avcc = Data(count: length)
        let copied = avcc.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { throw VideoError(message: "Unable to read encoded frame (\(copied)).") }
        let annexB = try Self.annexB(from: avcc, lengthBytes: Int(nalHeaderLength), declaringNoReordering: true)
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric, pts.seconds >= 0, pts.seconds.isFinite,
              pts.seconds < Double(UInt64.max) / 1_000_000 else { throw VideoError(message: "Invalid capture timestamp.") }
        var packet = Data()
        Self.appendBigEndian(epoch, to: &packet)
        Self.appendBigEndian(sequence, to: &packet)
        Self.appendBigEndian(UInt64(pts.seconds * 1_000_000), to: &packet)
        packet.append(keyframe ? 1 : 0)
        packet.append(annexB)
        sequence &+= 1
        onVideo?(packet)
        encodedFrames += 1
        encodedBytes += packet.count
        reportStats()
    }

    private func parameterSet(_ format: CMFormatDescription, index: Int, nalHeaderLength: inout Int32) throws -> Data {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        var count = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
            parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalHeaderLength)
        guard status == noErr, let pointer, size > 0, size <= 65536 else {
            throw VideoError(message: "H.264 parameter set \(index) unavailable (\(status)).")
        }
        var result = Data([0, 0, 0, 1])
        result.append(pointer, count: size)
        return result
    }

    /// AVCC uses big-endian NAL lengths; Annex B uses start codes. Reject truncated
    /// or unbounded units rather than forwarding malformed bytes to the decoder.
    static func annexB(from avcc: Data, lengthBytes: Int, declaringNoReordering: Bool = false) throws -> Data {
        guard (1...4).contains(lengthBytes), !avcc.isEmpty else { throw VideoError(message: "Invalid AVCC header size.") }
        var result = Data()
        var offset = 0
        while offset < avcc.count {
            guard avcc.count - offset >= lengthBytes else { throw VideoError(message: "Truncated AVCC NAL length.") }
            var length = 0
            for byte in avcc[offset..<(offset + lengthBytes)] { length = (length << 8) | Int(byte) }
            offset += lengthBytes
            guard length > 0, length <= avcc.count - offset else { throw VideoError(message: "Invalid AVCC NAL payload length.") }
            if declaringNoReordering, avcc[offset] & 0x1f == 7 {
                var sps = Data([0, 0, 0, 1])
                sps.append(avcc[offset..<(offset + length)])
                result.append(try H264SPS.declaringNoReordering(sps))
            } else {
                result.append(contentsOf: [0, 0, 0, 1])
                result.append(avcc[offset..<(offset + length)])
            }
            offset += length
        }
        return result
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private func reportStats() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastStatsTime
        guard elapsed >= 1 else { return }
        onStats?(["type": "videoStats", "epoch": epoch, "fps": Double(encodedFrames) / elapsed,
            "submittedFrames": submittedFrames, "encodedFrames": encodedFrames,
            "skippedFrames": skippedFrames, "bitsPerSecond": Double(encodedBytes * 8) / elapsed,
            "hardware": hardware])
        lastStatsTime = now
        submittedFrames = 0
        encodedFrames = 0
        skippedFrames = 0
        encodedBytes = 0
    }

    #if TABD_VIDEO_TESTING
    static func verifyObsoleteSetupForTests() async -> Bool {
        let owner = DisplayStreamer()
        owner.queue.sync { owner.generation = 41 }
        // Models stop/wake invalidation while discovery's callback is pending.
        await owner.stop()
        var obsoleteSetupRan = false
        do {
            let _: Bool = try await owner.withCurrentGeneration(41) {
                obsoleteSetupRan = true
                return true
            }
            return false
        } catch is CancellationError { }
        catch { return false }
        let replacementAccepted = try? await owner.withCurrentGeneration(42) { true }
        return !obsoleteSetupRan && replacementAccepted == true
    }

    static func verifyErrorEpochRoutingForTests() -> Bool {
        let owner = DisplayStreamer()
        var received: [(UInt32, String, Bool)] = []
        owner.onError = { received.append(($0, $1, $2)) }
        owner.queue.sync {
            owner.epoch = 17
            owner.generation = 4
            owner.reportError("active", epoch: 17, generation: 4)
            owner.reportError("stale epoch", epoch: 16, generation: 4)
            owner.reportError("stale generation", epoch: 17, generation: 3)
            owner.epoch = 18
            owner.generation = 5
            owner.reportError("previous stream", epoch: 17, generation: 4)
            owner.reportError("replacement", epoch: 18, generation: 5)
        }
        return received.count == 2 && received[0].0 == 17 && received[0].1 == "active" && received[0].2
            && received[1].0 == 18 && received[1].1 == "replacement" && received[1].2
    }

    /// Uses the production encoder configuration without screen recording or a display.
    struct EncoderProbe {
        let encoderID: String
        let sps: Data
    }

    static func verifyHardwareEncoderForTests(width: Int, height: Int, baseline: Bool = false,
                                             referenceBufferCount: Int? = nil) throws -> EncoderProbe {
        let owner = DisplayStreamer()
        let encoder = try owner.makeEncoder(width: width, height: height,
            profile: baseline ? kVTProfileLevel_H264_Baseline_AutoLevel : kVTProfileLevel_H264_High_AutoLevel,
            referenceBufferCount: referenceBufferCount)
        defer { VTCompressionSessionInvalidate(encoder) }
        var image: CVPixelBuffer?
        let created = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image)
        guard created == kCVReturnSuccess, let image else { throw VideoError(message: "Test pixel buffer failed (\(created)).") }
        CVPixelBufferLockBaseAddress(image, [])
        if let base = CVPixelBufferGetBaseAddress(image) {
            memset(base, 0x40, CVPixelBufferGetBytesPerRow(image) * height)
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        let done = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>?
        let context = FrameContext(owner: owner, generation: 0, epoch: 0)
        context.testCallback = { status, flags, sample in
            do {
                guard status == noErr, !flags.contains(.frameDropped), let sample,
                      let format = CMSampleBufferGetFormatDescription(sample),
                      let block = CMSampleBufferGetDataBuffer(sample) else {
                    throw VideoError(message: "Test encode callback failed (\(status)).")
                }
                var lengthBytes: Int32 = 0
                let sps = try owner.parameterSet(format, index: 0, nalHeaderLength: &lengthBytes)
                _ = try owner.parameterSet(format, index: 1, nalHeaderLength: &lengthBytes)
                let length = CMBlockBufferGetDataLength(block)
                var avcc = Data(count: length)
                let copied = avcc.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                guard copied == noErr else { throw VideoError(message: "Test encoded bytes unavailable.") }
                let annexB = try annexB(from: avcc, lengthBytes: Int(lengthBytes))
                guard annexB.count > 4 else { throw VideoError(message: "Test encoded frame empty.") }
                result = .success(sps)
            } catch { result = .failure(error) }
            done.signal()
        }
        let retained = Unmanaged.passRetained(context)
        let submitted = VTCompressionSessionEncodeFrame(encoder, imageBuffer: image,
            presentationTimeStamp: CMTime(value: 1, timescale: 60), duration: CMTime(value: 1, timescale: 60),
            frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary,
            sourceFrameRefcon: retained.toOpaque(), infoFlagsOut: nil)
        guard submitted == noErr else {
            retained.release()
            throw VideoError(message: "Test encode submission failed (\(submitted)).")
        }
        // Do not flush before waiting: one-in-flight production mode must deliver
        // its first frame without needing another submitted frame or CompleteFrames.
        guard done.wait(timeout: .now() + 5) == .success else {
            VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
            throw VideoError(message: "Hardware encoder did not emit its first frame within five seconds.")
        }
        let sps = try result!.get()
        return EncoderProbe(encoderID: owner.encoderID, sps: sps)
    }
    #endif
}
