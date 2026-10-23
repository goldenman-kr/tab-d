import Foundation
import ScreenCaptureKit

@main
enum VideoPacketTests {
    static func main() async throws {
        try await verifyFrameworkDeadlines()
        verifyRecoveryClassification()
        var checked = 0
        func equal(_ input: [UInt8], _ lengthBytes: Int, _ expected: [UInt8]) throws {
            let actual = try DisplayStreamer.annexB(from: Data(input), lengthBytes: lengthBytes)
            precondition(actual == Data(expected), "Annex B conversion mismatch")
            checked += 1
        }
        func reject(_ input: [UInt8], _ lengthBytes: Int) {
            do {
                _ = try DisplayStreamer.annexB(from: Data(input), lengthBytes: lengthBytes)
                preconditionFailure("Malformed AVCC was accepted")
            } catch { checked += 1 }
        }
        try equal([0, 0, 0, 3, 0x65, 0x11, 0x22], 4, [0, 0, 0, 1, 0x65, 0x11, 0x22])
        try equal([0, 2, 0x65, 0x11, 0, 1, 0x41], 2, [0, 0, 0, 1, 0x65, 0x11, 0, 0, 0, 1, 0x41])
        try equal([1, 0x65], 1, [0, 0, 0, 1, 0x65])
        try equal([0, 0, 1, 0x65], 3, [0, 0, 0, 1, 0x65])
        reject([], 4)
        reject([0, 0, 0], 4)
        reject([0, 0, 0, 0], 4)
        reject([0, 0, 0, 3, 0x65], 4)
        reject([0xff, 0xff, 0xff, 0xff], 4)
        reject([0, 0, 0, 1, 0x65, 0], 4)
        reject([1, 0x65], 0)
        reject([1, 0x65], 5)
        print("PASS: \(checked) video packet cases (four length widths, multi-NAL, truncation, zero/oversized lengths)")
        for fixture in ["AAAAASdkADKsVoB4Al6agIaAgQ==", "AAAAASdCADKrQDwBL01AQ0BAgA=="] {
            let original = Data(base64Encoded: fixture)!
            let before = try H264SPS.inspect(original)
            precondition(before.referenceFrames == 1 && before.reorderFrames == nil && before.decoderBuffers == nil)
            let rewritten = try H264SPS.declaringNoReordering(original)
            let after = try H264SPS.inspect(rewritten)
            precondition(after.referenceFrames == before.referenceFrames && after.profile == before.profile)
            precondition(after.pictureOrderCountType == before.pictureOrderCountType)
            precondition(after.reorderFrames == 0 && after.decoderBuffers == 1)
            let secondRewrite = try H264SPS.declaringNoReordering(rewritten)
            precondition(secondRewrite == rewritten)
            var avcc = Data([0, 0, 0, UInt8(original.count - 4)])
            avcc.append(original.dropFirst(4))
            let inBand = try DisplayStreamer.annexB(from: avcc, lengthBytes: 4, declaringNoReordering: true)
            precondition(inBand == rewritten)
            for count in 0..<8 {
                do {
                    _ = try H264SPS.declaringNoReordering(Data(original.prefix(count)))
                    preconditionFailure("Truncated SPS accepted")
                } catch { }
            }
        }
        print("PASS: High/Baseline SPS fixtures, explicit reorder=0/DPB=1, idempotence, in-band SPS and truncated-data rejection")
        var recovery = StartupRecovery()
        precondition(recovery.epoch != 41, "An unready epoch must remain subject to the global readiness deadline")
        precondition(recovery.begin(epoch: 41) && recovery.isPending(epoch: 41))
        precondition(recovery.epoch == 41, "Readiness replaces the global deadline with the presentation deadline")
        precondition(!recovery.begin(epoch: 41), "Duplicate decoderReady must not reset retries/deadline")
        precondition(!recovery.isPending(epoch: 40))
        recovery.cancel()
        precondition(!recovery.isPending(epoch: 41))
        precondition(!recovery.begin(epoch: 41), "A completed epoch must not restart recovery")
        precondition(recovery.begin(epoch: 42) && recovery.isPending(epoch: 42))
        precondition(!recovery.isPending(epoch: 41))
        precondition(StartupRecovery.retryOffsetsNanoseconds == [100_000_000, 300_000_000])
        precondition(StartupRecovery.timeoutNanoseconds == 3_000_000_000)
        precondition(StartupRecovery.readinessTimeoutNanoseconds == 12_000_000_000)
        print("PASS: finite startup recovery, duplicate-readiness suppression, cancellation and replacement epochs")
        #if TABD_VIDEO_TESTING
        let obsoleteSetupRejected = await DisplayStreamer.verifyObsoleteSetupForTests()
        precondition(obsoleteSetupRejected)
        print("PASS: stop invalidates pending discovery setup; a replacement generation remains usable")
        precondition(DisplayStreamer.verifyErrorEpochRoutingForTests())
        print("PASS: active error keeps source epoch; stale epoch/generation and previous-stream errors are suppressed")
        if CommandLine.arguments.contains("--hardware") {
            let probe = try DisplayStreamer.verifyHardwareEncoderForTests(width: 1920, height: 1200)
            let source = try H264SPS.inspect(probe.sps)
            let corrected = try H264SPS.declaringNoReordering(probe.sps)
            let info = try H264SPS.inspect(corrected)
            precondition(info.referenceFrames == source.referenceFrames && info.reorderFrames == 0)
            precondition(info.decoderBuffers == max(1, source.referenceFrames))
            print("PASS: production 1920×1200 hardware H.264 creation, preparation, hardware-use query, first synthetic frame without flush, SPS/PPS and encoded Annex B (\(probe.encoderID)); SPS=\(probe.sps.base64EncodedString())")
            print("PASS: actual hardware SPS refs=\(source.referenceFrames) reorder=\(String(describing: source.reorderFrames)) → explicit reorder=\(info.reorderFrames!) DPB=\(info.decoderBuffers!); correctedSPS=\(corrected.base64EncodedString())")
        }
        if CommandLine.arguments.contains("--sps-variants") {
            for (baseline, references) in [(false, nil), (false, 1), (true, nil), (true, 1)] as [(Bool, Int?)] {
                do {
                    let probe = try DisplayStreamer.verifyHardwareEncoderForTests(width: 1920, height: 1200,
                        baseline: baseline, referenceBufferCount: references)
                    print("baseline=\(baseline) refs=\(String(describing: references)) encoder=\(probe.encoderID) SPS=\(probe.sps.base64EncodedString())")
                } catch { print("baseline=\(baseline) refs=\(String(describing: references)) ERROR=\(error)") }
            }
        }
        #endif
    }

    static func verifyFrameworkDeadlines() async throws {
        let started = ContinuousClock.now
        do {
            let _: Int = try await FrameworkDeadline.wait(seconds: 0.02, operation: "never-callback test") { _ in }
            preconditionFailure("A missing callback must time out")
        } catch is FrameworkDeadline.Timeout { }
        precondition(started.duration(to: .now) < .seconds(1), "Timeout must not wait for a stuck framework operation")

        var lateCompletion: ((Result<Int, Error>) -> Void)?
        var lateValues: [Int] = []
        do {
            let _: Int = try await FrameworkDeadline.wait(seconds: 0.02, operation: "late-start test",
                onLateSuccess: { lateValues.append($0) }) { lateCompletion = $0 }
            preconditionFailure("A delayed callback must time out")
        } catch is FrameworkDeadline.Timeout { }
        lateCompletion?(.success(7))
        lateCompletion?(.success(8))
        precondition(lateValues == [7], "A late successful start must receive cleanup exactly once")

        var successfulCleanup = 0
        let accepted: Int = try await FrameworkDeadline.wait(seconds: 0.02, operation: "duplicate callback test",
            onLateSuccess: { _ in successfulCleanup += 1 }) { completion in
                completion(.success(11))
                completion(.success(12))
            }
        precondition(accepted == 11)
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(successfulCleanup == 0, "A duplicate callback must not stop an active capture")

        enum ProbeError: Error { case failed }
        var failedCompletion: ((Result<Int, Error>) -> Void)?
        var failedCleanup = 0
        do {
            let _: Int = try await FrameworkDeadline.wait(seconds: 0.02, operation: "late-error test",
                onLateSuccess: { _ in failedCleanup += 1 }) { failedCompletion = $0 }
            preconditionFailure("A delayed error must time out")
        } catch is FrameworkDeadline.Timeout { }
        failedCompletion?(.failure(ProbeError.failed))
        failedCompletion?(.success(13))
        precondition(failedCleanup == 0, "Late errors and duplicate successes cannot trigger cleanup")
        do {
            let _: Int = try await FrameworkDeadline.wait(seconds: 1, operation: "framework error test") {
                $0(.failure(ProbeError.failed))
            }
            preconditionFailure("The framework error must propagate")
        } catch ProbeError.failed { }
        print("PASS: framework deadline without callback, bounded return, late-success cleanup, duplicate/error callback isolation")
    }

    static func verifyRecoveryClassification() {
        for code in [SCStreamError.Code.userStopped, .userDeclined, .missingEntitlements] {
            let error = NSError(domain: SCStreamErrorDomain, code: code.rawValue)
            precondition(!DisplayStreamer.canAutomaticallyRecover(error))
            let wrapped = NSError(domain: "TabD.Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: error])
            let nested = NSError(domain: "TabD.Outer", code: 2, userInfo: [NSUnderlyingErrorKey: wrapped])
            precondition(!DisplayStreamer.canAutomaticallyRecover(nested), "Wrapped authorization/user-stop errors must remain terminal")
            let otherDomain = NSError(domain: "TabD.OtherDomain", code: code.rawValue)
            precondition(DisplayStreamer.canAutomaticallyRecover(otherDomain), "Codes only have meaning in their own domain")
        }
        for code in [SCStreamError.Code.failedToStart, .internalError] {
            let error = NSError(domain: SCStreamErrorDomain, code: code.rawValue)
            precondition(DisplayStreamer.canAutomaticallyRecover(error))
        }
        precondition(DisplayStreamer.canAutomaticallyRecover(NSError(domain: NSOSStatusErrorDomain, code: -12903)))
        print("PASS: SDK SCK user-stop/authorization errors prevent automatic recovery, including wrapped errors; transient/encoder errors remain recoverable")
    }
}
