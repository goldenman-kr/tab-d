import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor final class AppModel: ObservableObject {
    @Published var phase: SessionPhase = .idle
    @Published var route = "USB"
    @Published var deviceName = "Android 태블릿"
    @Published var message = "태블릿에서 Mr. Tab-D를 열어주세요"
    @Published var lastError: String?
    @Published var allowLAN = false { didSet { UserDefaults.standard.set(allowLAN, forKey:"wirelessAllowed") } }
    @Published var peerConnected = false
    @Published var hasCapturePermission = CGPreflightScreenCaptureAccess()
    @Published var hasInputPermission = CGPreflightPostEventAccess()
    @Published var inputMessage: String?
    @Published var selectedMode = 0 { didSet { UserDefaults.standard.set(selectedMode, forKey:"displayMode") } }
    @Published private(set) var isStopping = false

    let stateDirectory: URL
    private var server: HostServer?
    private let usb = USBConnector()
    private var usbTimerTicks = 0
    private let display = TBDVirtualDisplay()
    private let video = DisplayStreamer()
    private var machine = SessionMachine()
    private var mediaTask: Task<Void,Never>?
    private var startupRecovery = StartupRecovery()
    private var startupRecoveryTask: Task<Void,Never>?
    private var readinessDeadlineTask: Task<Void,Never>?
    private var modeInfo: [String:Any] = [:]
    private var displayBaseline: [[String:Any]] = []
    private var lastDisplayObservation: [String:Any] = [:]
    private var pendingRemovalID: CGDirectDisplayID?
    private var stats: [String:Any] = [:]
    private var events: [[String:Any]] = []
    private var framesSent: UInt64 = 0
    private var framesPresented: UInt64 = 0
    private var terminating = false
    private var clickGate = PointerClickGate()
    private let pointer = PointerInput()
    private let scrollInput = ScrollInput()
    private var scrollGate = PointerClickGate()
    private var lastScroll: [String:Any] = [:]
    private var pointerTimer: Timer?
    private var requestedInputPermission = false
    private var inputAccepted: UInt64 = 0
    private var inputRejected: UInt64 = 0
    private var diagnosticTimer: Timer?
    private let environment = HostEnvironment()
    private var wakeRecovery = WakeRecovery()
    private var wakeTask: Task<Void,Never>?
    private var peerVisible = false
    private var lastWakeRecovery: TimeInterval = 0
    private var physicalScreens: [String] = []
    private var disconnectQueued = false
    private var listenerRetryTask: Task<Void,Never>?
    private var listenerAttempts = 0
    var hasDisplay: Bool { machine.displayID != nil }
    var isBusy: Bool { isStopping || phase == .starting || phase == .recovering }

    init() {
        if let override = ProcessInfo.processInfo.environment["TABD_STATE_DIR"] {
            stateDirectory = URL(fileURLWithPath:override, isDirectory:true)
        } else if let development = Bundle.main.object(forInfoDictionaryKey:"TabDDevelopmentStateDirectory") as? String {
            stateDirectory = URL(fileURLWithPath:development, isDirectory:true)
        } else {
            stateDirectory = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Tab-D",isDirectory:true)
        }
        video.onConfig = { [weak self] config in
            // Serial video callbacks enqueue onto the same serial main queue.
            // This preserves config-before-access-unit ordering across the hop.
            DispatchQueue.main.async {
                guard let self, (config["epoch"] as? NSNumber)?.uint32Value == self.machine.epoch,
                      self.machine.phase == .starting || self.machine.phase == .streaming else { return }
                self.server?.sendConfig(config)
            }
        }
        video.onVideo = { [weak self] data in
            DispatchQueue.main.async {
                guard let self, data.count >= 4,
                      self.machine.phase == .starting || self.machine.phase == .streaming else { return }
                let epoch = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard epoch == self.machine.epoch else { return }
                self.server?.sendVideo(data)
                self.framesSent &+= 1
            }
        }
        video.onError = { [weak self] epoch, error, recoveryAllowed in
            DispatchQueue.main.async {
                guard let self, epoch == self.machine.epoch,
                      self.machine.phase == .starting || self.machine.phase == .streaming else { return }
                if !recoveryAllowed {
                    self.wakeRecovery.requestStop(); self.wakeTask?.cancel()
                } else if self.machine.phase == .streaming, self.wakeRecovery.intent == .streaming {
                    self.wakeRecovery.recover()
                }
                self.fail(error)
            }
        }
        video.onStats = { [weak self] value in
            DispatchQueue.main.async {
                guard let self, (value["epoch"] as? NSNumber)?.uint32Value == self.machine.epoch else { return }
                self.stats = value
            }
        }
    }

    func launch() {
        selectedMode = ProcessInfo.processInfo.arguments.contains("--native") ? 1 : (UserDefaults.standard.integer(forKey:"displayMode") == 1 ? 1 : 0)
        allowLAN = ProcessInfo.processInfo.arguments.contains("--allow-lan") || UserDefaults.standard.bool(forKey:"wirelessAllowed")
        do {
            try FileManager.default.createDirectory(at:stateDirectory,withIntermediateDirectories:true,
                attributes:[.posixPermissions:0o700])
            let network = try HostServer(stateDirectory:stateDirectory)
            network.onConnected = { [weak self] route in
                guard let self else { return }
                self.record("peerConnected")
                self.route = route; self.peerConnected = true; self.machine.peerReady()
                self.lastError = nil; self.publish(); self.sendStatus()
            }
            network.onJSON = { [weak self] value in self?.receive(value) }
            network.onDisconnected = { [weak self] in self?.peerLost() }
            network.onError = { [weak self] text in self?.lastError = text; self?.writeDiagnostics() }
            server = network
            try network.start(allowLAN:allowLAN)
            physicalScreens = physicalScreenSignature()
            environment.onChange = { [weak self] reason, blocked in self?.hostChanged(reason,blocked:blocked) }
            environment.onWakeHint = { [weak self] in self?.hostWakeHint() }
            environment.onTopologyChange = { [weak self] in self?.topologyChanged() }
            environment.start()
            // This development pairing file is deliberately private and ignored by Git.
            let pairing = try JSONSerialization.data(withJSONObject:network.pairing,options:[.sortedKeys])
            let pairingURL = stateDirectory.appendingPathComponent("pairing.json")
            try pairing.write(to:pairingURL,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:pairingURL.path)
            usb.onStatus = { [weak self] error in
                guard let self, !self.peerConnected else { return }
                self.lastError = error
            }
            usb.ensurePairing(network.pairing)
            diagnosticTimer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.usbTimerTicks += 1
                    self.environment.refresh()
                    if self.usbTimerTicks % 5 == 0, let pairing=self.server?.pairing { self.usb.ensurePairing(pairing) }
                    self.hasInputPermission = CGPreflightPostEventAccess()
                    if self.hasInputPermission { self.inputMessage = nil }
                    self.writeDiagnostics()
                }
            }
            pointerTimer = Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.pointer.held {
                        if !CGPreflightPostEventAccess() { self.pointer.release(reason:"permissionLost") }
                        else if self.machine.phase != .streaming || self.machine.displayID != self.display.displayID || CGDisplayIsActive(self.display.displayID) == 0 {
                            self.pointer.release(reason:"displayUnavailable")
                        } else { self.pointer.expire(now:ProcessInfo.processInfo.systemUptime) }
                        self.writeDiagnostics()
                    }
                }
            }
            publish()
            if ProcessInfo.processInfo.arguments.contains("--request-capture") { requestPermission() }
            if ProcessInfo.processInfo.arguments.contains("--request-input") { requestInputPermission() }
        } catch { lastError = error.localizedDescription; publish() }
    }

    func connect(resuming: Bool = false, automaticWake: Bool = false) {
        record(resuming ? "resumeRequested" : "startRequested")
        if !automaticWake {
            if wakeRecovery.pending {
                scheduleWakeAttempt(delay:0.3); sendStatus(); return
            }
            wakeRecovery.requestStart()
            wakeTask?.cancel()
        }
        guard !wakeRecovery.blocked else { publish(); sendStatus(); return }
        guard peerConnected else {
            let states=server?.diagnostics["listenerStates"] as? [String:String] ?? [:]
            if states.values.contains("failed") { listenerAttempts=0; restartWakeTransport() }
            lastError = "태블릿에서 Mr. Tab-D를 열어주세요"; return
        }
        guard pendingRemovalID == nil else {
            lastError="가상 화면 제거를 확인하지 못했습니다. Mr. Tab-D를 종료한 뒤 다시 실행해주세요"; return
        }
        guard !isStopping, phase != .starting, phase != .streaming,
              phase != .recovering || resuming else { sendStatus(); return }
        // Preflight is advisory. ScreenCaptureKit's actual capture request is
        // authoritative, and the OS enforces consent before any frames arrive.
        hasCapturePermission = CGPreflightScreenCaptureAccess()
        lastError = nil
        cancelStartupRecovery()
        scrollInput.reset()
        pointer.release(reason:"newEpoch")
        let requested = selectedMode == 1 ? (3504,2190,false) : (1920,1200,false)
        do {
            if automaticWake {
                // A power/topology change may legitimately alter physical screens.
                // Keep the owned virtual screen unless a fresh process proves it gone.
                let observed = try observeDisplays()["displays"] as? [[String:Any]] ?? []
                guard !observed.isEmpty else { throw displayError("깨어난 Mac의 디스플레이를 기다리는 중입니다") }
                if display.displayID != 0, !observed.contains(where:{ ($0["displayID"] as? NSNumber)?.uint32Value == display.displayID }) {
                    display.remove(); machine.end()
                }
                displayBaseline = observed.filter { ($0["displayID"] as? NSNumber)?.uint32Value != display.displayID }
            }
            let creatingDisplay = display.displayID == 0
            let epoch = machine.begin()
            beginReadinessDeadline(epoch:epoch)
            if creatingDisplay {
                displayBaseline = try observeDisplays()["displays"] as? [[String:Any]] ?? []
                guard !displayBaseline.isEmpty else { throw displayError("현재 디스플레이 배치를 확인할 수 없습니다") }
                try display.create(withPixelWidth:UInt32(requested.0),height:UInt32(requested.1),hiDPI:requested.2)
            }
            guard machine.attach(display.displayID,epoch:epoch) else { return }
            publish(); sendStatus()
            enqueueMedia { [weak self] in
                guard let self else { return }
                await self.video.stop()
                guard self.machine.epoch == epoch, self.machine.phase == .starting else { return }
                do {
                    // Let WindowServer settle, then verify with two independent,
                    // read-only processes. Never select a CG display mode.
                    let settlingDelays: [UInt64] = creatingDisplay ? [2_000_000_000, 1_000_000_000] : [0]
                    for delay in settlingDelays {
                        if delay > 0 { try await Task.sleep(nanoseconds:delay) }
                        guard self.machine.epoch == epoch, self.machine.phase == .starting else { return }
                        self.modeInfo = try self.verifyDisplay(width:requested.0,height:requested.1)
                    }
                    let width = (self.modeInfo["pixelWidth"] as? NSNumber)?.intValue ?? requested.0
                    let height = (self.modeInfo["pixelHeight"] as? NSNumber)?.intValue ?? requested.1
                    try await self.video.start(displayID:self.display.displayID,width:width,height:height,epoch:epoch)
                    self.hasCapturePermission = true
                    if self.machine.epoch != epoch { await self.video.stop() }
                } catch {
                    if self.machine.epoch == epoch {
                        if !DisplayStreamer.canAutomaticallyRecover(error) {
                            self.wakeRecovery.requestStop(); self.wakeTask?.cancel()
                        }
                        self.fail(error.localizedDescription)
                    }
                }
            }
        } catch { fail(error.localizedDescription) }
    }

    private func displayError(_ text:String) -> NSError {
        NSError(domain:"Tab-D",code:1,userInfo:[NSLocalizedDescriptionKey:text])
    }

    private func observeDisplays(target:CGDirectDisplayID = 0, timeout:Double = 1) throws -> [String:Any] {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/TabDDisplayInspector")
        let task=Process(); let pipe=Pipe()
        task.executableURL=helper; task.arguments=[String(target)]; task.standardOutput=pipe
        try task.run()
        let expiry=DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline:.now()+max(0.05,timeout),execute:expiry)
        defer { expiry.cancel() }
        let data=pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let result=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else {
            throw displayError("디스플레이 상태를 확인할 수 없습니다")
        }
        return result
    }

    private func verifyDisplay(width:Int,height:Int) throws -> [String:Any] {
        let result = try observeDisplays(target:display.displayID)
        lastDisplayObservation=result
        let observed = result["displays"] as? [[String:Any]] ?? []
        for baseline in displayBaseline {
            guard let current = observed.first(where:{ ($0["displayID"] as? NSNumber) == (baseline["displayID"] as? NSNumber) }),
                  ["main","active","mirrored","bounds","logicalWidth","logicalHeight","pixelWidth","pixelHeight"].allSatisfy({ key in
                      guard let old=baseline[key] as? NSObject, let new=current[key] as? NSObject else { return false }
                      return old.isEqual(new)
                  }) else { throw displayError("기존 디스플레이 배치가 변경되어 확장 화면을 종료했습니다") }
        }
        guard (result["displayID"] as? NSNumber)?.uint32Value == display.displayID,
              (result["main"] as? NSNumber)?.boolValue == false,
              (result["active"] as? NSNumber)?.boolValue == true,
              (result["mirrored"] as? NSNumber)?.boolValue == false,
              (result["pixelWidth"] as? NSNumber)?.intValue == width,
              (result["pixelHeight"] as? NSNumber)?.intValue == height,
              (result["logicalWidth"] as? NSNumber)?.intValue == width,
              (result["logicalHeight"] as? NSNumber)?.intValue == height else {
            throw displayError("요청한 가상 화면의 실제 해상도·확장 배치를 확인할 수 없습니다")
        }
        return result
    }

    private func removeDisplay() async -> Bool {
        let removed = display.displayID != 0 ? display.displayID : pendingRemovalID ?? 0
        pendingRemovalID = removed == 0 ? nil : removed
        display.remove(); modeInfo=[:]
        guard removed != 0 else { displayBaseline=[]; return true }
        let deadline=ProcessInfo.processInfo.systemUptime+5
        while ProcessInfo.processInfo.systemUptime < deadline {
            let remaining=deadline-ProcessInfo.processInfo.systemUptime
            if let snapshot=try? observeDisplays(timeout:min(1,remaining)), let displays=snapshot["displays"] as? [[String:Any]],
               !displays.contains(where:{ ($0["displayID"] as? NSNumber)?.uint32Value == removed }) {
                displayBaseline=[]; pendingRemovalID=nil; return true
            }
            try? await Task.sleep(nanoseconds:UInt64(max(0,min(0.1,deadline-ProcessInfo.processInfo.systemUptime))*1_000_000_000))
        }
        lastError="가상 화면 제거가 지연됩니다. Mr. Tab-D를 종료하면 macOS가 화면을 회수합니다"
        return false
    }

    private func pause() {
        wakeRecovery.requestPause(); wakeTask?.cancel()
        guard !isStopping, machine.displayID != nil else { sendStatus(); return }
        if machine.phase == .paused {
            server?.sendJSON(["type":"pauseAck","displayID":machine.displayID ?? 0]); sendStatus(); return
        }
        cancelStartupRecovery()
        scrollInput.reset()
        pointer.release(reason:"pause")
        let epoch = machine.pause()
        publish()
        enqueueMedia { [weak self] in
            guard let self else { return }
            await self.video.stop()
            guard self.machine.epoch == epoch else { return }
            self.server?.sendJSON(["type":"pauseAck","displayID":self.machine.displayID ?? 0])
            self.sendStatus(); self.writeDiagnostics()
        }
    }

    func disconnect() {
        record("disconnectRequested")
        wakeRecovery.requestStop(); wakeTask?.cancel()
        if isStopping {
            // A user Stop must still remove the display if capture teardown is
            // already in progress (including a failed automatic wake attempt).
            guard !disconnectQueued else { return }
            disconnectQueued = true
            enqueueMedia { [weak self] in
                guard let self else { return }
                self.disconnectQueued = false; self.isStopping = false
                self.disconnect()
            }
            return
        }
        isStopping = true
        cancelStartupRecovery()
        scrollInput.reset()
        pointer.release(reason:"disconnect")
        machine.end()
        publish()
        enqueueMedia { [weak self] in
            guard let self else { return }
            await self.video.stop()
            // Do not remove a display created by a later explicit connection.
            guard self.machine.displayID == nil else { return }
            let removed = await self.removeDisplay()
            self.isStopping = false
            if removed { self.server?.sendJSON(["type":"disconnectAck"]) }
            else { self.machine.end(failed:true) }
            self.publish(); self.sendStatus(); self.writeDiagnostics()
        }
    }

    private func receive(_ value:[String:Any]) {
        if let type=value["type"] as? String, type != "ping", type != "pointer", type != "scroll" { record("control:" + type) }
        switch value["type"] as? String {
        case "hello":
            let name = (value["device"] as? String ?? "").components(separatedBy:.controlCharacters).joined().trimmingCharacters(in:.whitespacesAndNewlines)
            deviceName = name.isEmpty ? "Android 태블릿" : String(name.prefix(128))
            peerVisible = value["visible"] as? Bool ?? false
            sendStatus()
            if wakeRecovery.pending, peerVisible { scheduleWakeAttempt(delay:0.3) }
        case "start": connect()
        case "resume":
            peerVisible = true
            if machine.displayID != nil || wakeRecovery.pending { connect(resuming:true) }
            else { server?.sendJSON(["type":"status","state":"stopped"]) }
        case "pause": pause()
        case "disconnect": disconnect()
        case "click": receiveClick(value)
        case "pointer": receivePointer(value)
        case "scroll": receiveScroll(value)
        case "decoderReady":
            guard let epoch=(value["epoch"] as? NSNumber)?.uint32Value,
                  epoch == machine.epoch,
                  machine.phase == .starting || machine.phase == .streaming else { return }
            if machine.phase == .starting { beginStartupRecovery(epoch:epoch) }
        case "keyframe":
            guard let epoch=(value["epoch"] as? NSNumber)?.uint32Value,
                  epoch == machine.epoch,
                  machine.phase == .starting || machine.phase == .streaming else { return }
            video.requestKeyFrame(expectedEpoch:epoch)
        case "presented":
            if let epoch=(value["epoch"] as? NSNumber)?.uint32Value, machine.presented(epoch:epoch) {
                cancelStartupRecovery()
                if wakeRecovery.pending { wakeRecovery.complete(); wakeTask?.cancel() }
                framesPresented &+= 1
                if phase != .streaming { publish(); sendStatus() }
            }
        case "ping": server?.sendJSON(["type":"pong"])
        default: break
        }
    }

    private func receiveClick(_ value:[String:Any]) {
        guard let click=PointerClick(value) else { inputRejected &+= 1; return }
        func reply(_ accepted:Bool, _ text:String) {
            if accepted { inputAccepted &+= 1 } else { inputRejected &+= 1 }
            server?.sendJSON(["type":"clickResult","epoch":click.epoch,"id":click.id,"accepted":accepted,"message":text])
            writeDiagnostics()
        }
        guard !pointer.held, clickGate.accept(click,session:machine,peerConnected:peerConnected), !isStopping,
              let target=machine.displayID, target == display.displayID,
              CGDisplayIsActive(target) != 0, CGDisplayIsInMirrorSet(target) == 0 else {
            reply(false,"화면을 다시 연결한 뒤 탭해주세요"); return
        }
        guard let point=click.point(in:CGDisplayBounds(target)) else {
            reply(false,"가상 화면 위치를 확인할 수 없습니다"); return
        }
        hasInputPermission=CGPreflightPostEventAccess()
        guard hasInputPermission else {
            inputMessage="Mac의 손쉬운 사용 설정에서 Mr. Tab-D를 허용해주세요"
            reply(false,inputMessage!)
            if !requestedInputPermission { requestInputPermission() }
            return
        }
        let posted=pointer.click(at:point,button:click.button,clickCount:click.clickCount)
        reply(posted,posted ? "" : "Mac 클릭을 전달하지 못했습니다")
    }

    private func receiveScroll(_ value:[String:Any]) {
        guard let request=ScrollRequest(value) else { inputRejected &+= 1; return }
        let position=request.position
        var accepted=false
        var text="화면을 다시 연결한 뒤 스크롤해주세요"
        if !pointer.held, !isStopping,
           scrollGate.accept(position,session:machine,peerConnected:peerConnected),
           let target=machine.displayID, target == display.displayID,
           CGDisplayIsActive(target) != 0, CGDisplayIsInMirrorSet(target) == 0,
           let point=position.point(in:CGDisplayBounds(target)) {
            hasInputPermission=CGPreflightPostEventAccess()
            if hasInputPermission {
                accepted=scrollInput.post(request,point:point,displayHeight:CGDisplayBounds(target).height)
                text=accepted ? "" : "Mac으로 스크롤을 전달하지 못했습니다"
            } else {
                inputMessage="Mac의 손쉬운 사용 설정에서 Mr. Tab-D를 허용해주세요"
                text=inputMessage!
                if !requestedInputPermission { requestInputPermission() }
            }
        }
        if accepted { inputAccepted &+= 1 } else { inputRejected &+= 1 }
        lastScroll=["id":position.id,"epoch":position.epoch,"x":position.x,"y":position.y,
            "deltaY":request.deltaY,"pixels":accepted ? scrollInput.lastPixels : 0,"accepted":accepted,"message":text]
        server?.sendJSON(["type":"scrollResult","id":position.id,"epoch":position.epoch,"accepted":accepted,"message":text])
    }

    private func receivePointer(_ value:[String:Any]) {
        guard let request=PointerRequest(value) else { inputRejected &+= 1; return }
        var accepted=false
        var text="화면을 다시 연결한 뒤 터치해주세요"
        if !isStopping, peerConnected, machine.phase == .streaming, request.epoch == machine.epoch,
           let target=machine.displayID, target == display.displayID, CGDisplayIsActive(target) != 0,
           CGDisplayIsInMirrorSet(target) == 0, let point=request.position.point(in:CGDisplayBounds(target)) {
            hasInputPermission=CGPreflightPostEventAccess()
            if hasInputPermission {
                accepted=pointer.handle(request,point:point,now:ProcessInfo.processInfo.systemUptime)
                text=accepted ? "" : "드래그가 종료되었거나 입력 순서가 맞지 않습니다"
            } else {
                pointer.release(reason:"permissionLost")
                inputMessage="Mac의 손쉬운 사용 설정에서 Mr. Tab-D를 허용해주세요"
                text=inputMessage!
                if !requestedInputPermission { requestInputPermission() }
            }
        }
        if accepted { inputAccepted &+= 1 } else { inputRejected &+= 1 }
        // Moves are bounded and ordered on the same connection; ACK only lifecycle edges.
        if request.phase != .move {
            server?.sendJSON(["type":"pointerResult","epoch":request.epoch,"id":request.id,
                "phase":request.phase.rawValue,"accepted":accepted,"message":text])
            writeDiagnostics()
        }
    }

    private func beginReadinessDeadline(epoch:UInt32) {
        // Measure from begin(), including display settlement and capture startup,
        // even if this task first runs after synchronous display inspection.
        let deadline = ContinuousClock.now.advanced(by:
            .nanoseconds(Int64(StartupRecovery.readinessTimeoutNanoseconds)))
        readinessDeadlineTask=Task { @MainActor [weak self] in
            do { try await Task.sleep(until:deadline,clock:.continuous) }
            catch { return }
            guard let self, self.machine.epoch == epoch, self.machine.phase == .starting,
                  self.startupRecovery.epoch != epoch else { return }
            self.record("startupDecoderReadyTimeout")
            self.fail("태블릿의 화면 준비가 완료되지 않았습니다. 연결을 다시 시작해주세요")
        }
    }

    private func beginStartupRecovery(epoch:UInt32) {
        guard startupRecovery.begin(epoch:epoch) else { return }
        readinessDeadlineTask?.cancel()
        readinessDeadlineTask=nil
        startupRecoveryTask?.cancel()
        record("startupDecoderReady")
        video.requestKeyFrame(expectedEpoch:epoch)
        startupRecoveryTask=Task { @MainActor [weak self] in
            var elapsed: UInt64 = 0
            for offset in StartupRecovery.retryOffsetsNanoseconds {
                do { try await Task.sleep(nanoseconds:offset-elapsed) }
                catch { return }
                elapsed=offset
                guard let self, self.startupRecovery.isPending(epoch:epoch),
                      self.machine.epoch == epoch, self.machine.phase == .starting else { return }
                self.record("startupKeyframeRetry")
                // Re-encode the latest real captured image; no generated padding
                // frames and no periodic stream after startup has completed.
                self.video.requestKeyFrame(expectedEpoch:epoch)
            }
            do { try await Task.sleep(nanoseconds:StartupRecovery.timeoutNanoseconds-elapsed) }
            catch { return }
            guard let self, self.startupRecovery.isPending(epoch:epoch),
                  self.machine.epoch == epoch, self.machine.phase == .starting else { return }
            self.record("startupPresentationTimeout")
            self.fail("태블릿이 첫 화면을 표시하지 못했습니다. 연결을 다시 시작해주세요")
        }
    }

    private func cancelStartupRecovery() {
        startupRecovery.cancel()
        readinessDeadlineTask?.cancel()
        readinessDeadlineTask=nil
        startupRecoveryTask?.cancel()
        startupRecoveryTask=nil
    }

    private func hostChanged(_ reason:HostInterruption, blocked:Bool) {
        let changed = blocked ? wakeRecovery.interrupt(reason) : wakeRecovery.awaken(reason)
        guard changed else { return }
        record("host:" + reason.rawValue + (blocked ? ":blocked" : ":available"))
        wakeTask?.cancel()
        if blocked {
            listenerRetryTask?.cancel()
            quiesceForHost()
        } else if !wakeRecovery.blocked {
            prepareWakeRecovery()
        }
        publish(); sendStatus()
    }

    private func quiesceForHost() {
        cancelStartupRecovery()
        scrollInput.reset(); pointer.release(reason:"hostUnavailable")
        if machine.displayID != nil || machine.phase == .starting { _ = machine.pause() }
        enqueueMedia { [weak self] in await self?.video.stop() }
    }

    private func hostWakeHint() {
        guard !wakeRecovery.blocked, wakeRecovery.intent != .none,
              ProcessInfo.processInfo.systemUptime-lastWakeRecovery > 5 else { return }
        // Some power transitions produce a wake hint without a matching sleep.
        wakeRecovery.recover(); quiesceForHost(); prepareWakeRecovery()
    }

    private func prepareWakeRecovery() {
        guard !terminating, !wakeRecovery.blocked, wakeRecovery.intent != .none else { return }
        lastWakeRecovery = ProcessInfo.processInfo.systemUptime
        record("hostWakeRecovery")
        listenerAttempts = 0
        restartWakeTransport()
        publish(); sendStatus()
        scheduleWakeAttempt(delay:0.8)
    }

    private func restartWakeTransport() {
        listenerRetryTask?.cancel()
        listenerAttempts += 1
        // A connection can look ready indefinitely after USB/network sleep.
        // Drop the old peer slot and both listeners; Android reauthenticates.
        peerConnected = false; peerVisible = false
        server?.stop()
        do { try server?.start(allowLAN:allowLAN) }
        catch { lastError = error.localizedDescription }
        if let pairing=server?.pairing { usb.ensurePairing(pairing) }
        listenerRetryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds:2_000_000_000) }
            catch { return }
            guard let self, !self.terminating, !self.wakeRecovery.blocked,
                  self.wakeRecovery.intent != .none else { return }
            let states = self.server?.diagnostics["listenerStates"] as? [String:String] ?? [:]
            let target = self.route == "무선" ? "LAN" : "USB"
            guard states[target] != "ready" else { return }
            if self.listenerAttempts < 3 { self.restartWakeTransport() }
            else {
                self.wakeRecovery.exhaust()
                self.lastError = "Mac의 연결 포트를 다시 열지 못했습니다. 연결 설정을 확인해주세요"
                self.publish(); self.sendStatus()
            }
        }
    }

    private func scheduleWakeAttempt(delay:Double) {
        guard wakeRecovery.mayAttempt else { return }
        wakeTask?.cancel()
        let generation = wakeRecovery.generation
        wakeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds:UInt64(delay*1_000_000_000)) }
            catch { return }
            guard let self, self.wakeRecovery.generation == generation,
                  self.wakeRecovery.mayAttempt, self.peerConnected, self.peerVisible else { return }
            if self.isStopping { self.scheduleWakeAttempt(delay:0.5); return }
            guard self.machine.phase != .starting, self.machine.phase != .streaming else { return }
            self.wakeRecovery.attempted()
            self.record("hostWakeAttempt")
            self.connect(resuming:true,automaticWake:true)
        }
    }

    private func physicalScreenSignature() -> [String] {
        NSScreen.screens.compactMap { screen in
            guard let id=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  id.uint32Value != display.displayID else { return nil }
            return "\(id.uint32Value):\(screen.frame):\(screen.backingScaleFactor)"
        }.sorted()
    }

    private func topologyChanged() {
        let current=physicalScreenSignature()
        guard current != physicalScreens else { return }
        physicalScreens=current
        record("physicalScreensChanged")
        guard !wakeRecovery.blocked, wakeRecovery.intent == .streaming,
              ProcessInfo.processInfo.systemUptime-lastWakeRecovery > 5 else { return }
        wakeRecovery.recover(); quiesceForHost(); prepareWakeRecovery()
    }

    private func peerLost() {
        record("peerLost")
        guard !terminating else { return }
        scrollInput.reset()
        pointer.release(reason:"peerLost")
        peerConnected = false
        peerVisible = false
        cancelStartupRecovery()
        if wakeRecovery.blocked || wakeRecovery.pending {
            _ = machine.pause()
            enqueueMedia { [weak self] in await self?.video.stop() }
            publish(); return
        }
        let recovery = machine.losePeer()
        enqueueMedia { [weak self] in await self?.video.stop() }
        publish()
        guard let recovery else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds:3_000_000_000)
            guard let self, self.machine.expireRecovery(epoch:recovery) != nil else { return }
            self.wakeRecovery.requestStop(); self.wakeTask?.cancel()
            self.isStopping = true
            self.enqueueMedia { [weak self] in
                guard let self else { return }
                await self.video.stop()
                let removed = await self.removeDisplay()
                if !removed { self.machine.end(failed:true) }
                self.isStopping=false; self.publish()
            }
        }
    }

    private func fail(_ text:String) {
        record("failed")
        cancelStartupRecovery()
        scrollInput.reset()
        pointer.release(reason:"failed")
        if wakeRecovery.pending || wakeRecovery.blocked {
            lastError = text; isStopping = true
            _ = machine.pause()
            let retry = wakeRecovery.mayAttempt
            if !retry, !wakeRecovery.blocked { wakeRecovery.exhaust() }
            publish(); sendStatus()
            enqueueMedia { [weak self] in
                guard let self else { return }
                await self.video.stop()
                self.isStopping = false
                if retry { self.scheduleWakeAttempt(delay:2) }
                self.publish(); self.sendStatus()
            }
            return
        }
        wakeRecovery.requestStop(); wakeTask?.cancel()
        lastError = text; isStopping=true; machine.end(failed:true)
        publish()
        server?.sendJSON(["type":"status","state":"error","message":text])
        enqueueMedia { [weak self] in
            guard let self else { return }
            await self.video.stop()
            if self.machine.displayID == nil { _ = await self.removeDisplay() }
            self.isStopping=false
            self.writeDiagnostics()
        }
    }

    private func enqueueMedia(_ action:@escaping @MainActor () async -> Void) {
        let previous=mediaTask
        mediaTask=Task { @MainActor in
            await previous?.value
            guard !self.terminating else { return }
            await action()
        }
    }

    private func publish() {
        phase=machine.phase
        switch phase {
        case .idle: message=peerConnected ? "연결 가능" : "태블릿에서 Mr. Tab-D를 열어주세요"
        case .ready: message="연결 가능"
        case .starting: message="화면 연결 중…"
        case .streaming: message="확장 중"
        case .paused: message="화면 유지 중"
        case .recovering: message="연결 복구 중…"
        case .failed: message="연결을 확인해주세요"
        }
        if wakeRecovery.blocked, wakeRecovery.intent != .none { message="Mac이 잠겨 있거나 절전 중입니다 · 화면 유지 중" }
        else if wakeRecovery.pending { message="Mac 화면 복귀 · 연결 복구 중…" }
        writeDiagnostics()
    }
    private func sendStatus() {
        let state: String
        switch machine.phase {
        case .idle: state="stopped"
        case .ready: state="ready"
        case .starting: state="starting"
        case .streaming: state="streaming"
        case .paused: state=lastError != nil && !wakeRecovery.pending && !wakeRecovery.blocked ? "error" : "paused"
        case .recovering: state="starting"
        case .failed: state="error"
        }
        server?.sendJSON(["type":"status","state":state,"displayID":machine.displayID ?? 0,
            "epoch":machine.epoch,"message":lastError ?? message,
            "hostSuspended":wakeRecovery.blocked,"hostRecovering":wakeRecovery.pending && !wakeRecovery.blocked])
    }
    private func record(_ name:String) {
        events.append(["event":name,"phase":machine.phase.rawValue,"epoch":machine.epoch,
            "displayID":machine.displayID ?? 0,"time":ISO8601DateFormatter().string(from:Date())])
        if events.count > 64 { events.removeFirst(events.count-64) }
    }
    private func writeDiagnostics() {
        let data:[String:Any]=["state":machine.phase.rawValue,"displayID":machine.displayID ?? 0,
            "epoch":machine.epoch,"peerConnected":peerConnected,"route":route,
            "allowLAN":allowLAN,"selectedMode":selectedMode,
            "wake":["intent":wakeRecovery.intent.rawValue,"blockers":wakeRecovery.blockers.map(\.rawValue).sorted(),
                "pending":wakeRecovery.pending,"attempts":wakeRecovery.attempts,"generation":wakeRecovery.generation,"peerVisible":peerVisible],
            "displayObservation":lastDisplayObservation,"pendingRemovalID":pendingRemovalID ?? 0,"framesSent":framesSent,"framesPresented":framesPresented,"mode":modeInfo,"video":stats,"events":events,"transport":server?.diagnostics ?? [:],
            "capturePermission":hasCapturePermission,"capturePreflight":CGPreflightScreenCaptureAccess(),"lastError":lastError ?? "",
            "scroll":lastScroll,"pointer":pointer.diagnostics,"inputPermission":CGPreflightPostEventAccess(),"inputAccepted":inputAccepted,"inputRejected":inputRejected,"inputMessage":inputMessage ?? "",
            "updatedAt":ISO8601DateFormatter().string(from:Date())]
        if let encoded=try? JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]) {
            try? encoded.write(to:stateDirectory.appendingPathComponent("diagnostics.json"),options:.atomic)
        }
    }
    func requestPermission() {
        hasCapturePermission=CGPreflightScreenCaptureAccess()
        if !hasCapturePermission { _=CGRequestScreenCaptureAccess() }
        hasCapturePermission=CGPreflightScreenCaptureAccess()
        writeDiagnostics()
    }
    func openCaptureSettings() {
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    func requestInputPermission() {
        requestedInputPermission=true
        hasInputPermission=CGPreflightPostEventAccess()
        if !hasInputPermission { _=CGRequestPostEventAccess() }
        hasInputPermission=CGPreflightPostEventAccess()
        inputMessage=hasInputPermission ? nil : "Mac의 손쉬운 사용 설정에서 Mr. Tab-D를 허용해주세요"
        writeDiagnostics()
    }
    func openInputSettings() {
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func openDisplaySettings() {
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }
    func setWireless(_ enabled:Bool) {
        guard !hasDisplay else { lastError="연결 종료 후 연결 방법을 변경해주세요"; return }
        do { try server?.start(allowLAN:enabled); allowLAN=enabled }
        catch { lastError=error.localizedDescription }
    }
    func shutdown() {
        environment.stop(); wakeTask?.cancel(); listenerRetryTask?.cancel(); wakeRecovery.requestStop()
        scrollInput.reset()
        pointer.release(reason:"shutdown")
        terminating=true; diagnosticTimer?.invalidate(); pointerTimer?.invalidate(); cancelStartupRecovery(); machine.end()
        server?.stop(); display.remove(); writeDiagnostics()
        Task { await video.stop() }
    }
}
