import Foundation

/// Uses the user's existing Android platform-tools; no kernel/USB driver is installed.
final class USBConnector {
    var onStatus: ((String?) -> Void)?
    private let queue = DispatchQueue(label:"xyz.kryp.app.tabd.usb-setup")
    private var busy=false
    private var provisioned=false
    private let adb:URL
    init() {
        adb=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TABD_ADB"] ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path)
    }
    func ensurePairing(_ pairing:[String:Any]) {
        queue.async {
            guard !self.busy else { return }
            self.busy=true; defer { self.busy=false }
            guard FileManager.default.isExecutableFile(atPath:self.adb.path) else {
                self.report("USB 연결에는 Android platform-tools의 adb가 필요합니다"); return
            }
            do {
                let state=try self.run(["get-state"])
                guard state.0 == 0, String(data:state.1,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) == "device" else {
                    self.provisioned=false
                    self.report("USB 디버깅 연결과 태블릿의 이 컴퓨터 허용을 확인해주세요"); return
                }
                let existing=try self.run(["reverse","--list"])
                let lines=(String(data:existing.1,encoding:.utf8) ?? "").split(separator:"\n").map { $0.split(separator:" ").map(String.init) }
                if lines.contains(where:{ $0.count >= 3 && $0[$0.count-2] == "tcp:49832" && $0.last != "tcp:49832" }) {
                    self.report("태블릿의 USB 연결 포트가 다른 서비스에서 사용 중입니다"); return
                }
                let mapped=lines.contains { $0.count >= 3 && $0[$0.count-2] == "tcp:49832" && $0.last == "tcp:49832" }
                if self.provisioned && mapped {
                    // Reinstalling/clearing Android data can leave adb reverse intact.
                    // Compare private bytes internally; never publish pairing material.
                    let saved = try self.run(["shell","run-as","xyz.kryp.app.tabd","cat","files/pairing.json"])
                    if saved.0 == 0,
                       let object = try? JSONSerialization.jsonObject(with:saved.1) as? [String:Any],
                       NSDictionary(dictionary:object).isEqual(to:pairing) { return }
                }
                let bytes=try JSONSerialization.data(withJSONObject:pairing,options:.sortedKeys)
                for (arguments,input) in [
                    (["reverse","tcp:49832","tcp:49832"],nil),
                    (["shell","run-as","xyz.kryp.app.tabd","mkdir","-p","files"],nil),
                    (["shell","run-as","xyz.kryp.app.tabd","sh","-c","'cat > files/pairing.json'"],bytes),
                    (["shell","run-as","xyz.kryp.app.tabd","chmod","600","files/pairing.json"],nil)
                ] as [([String],Data?)] {
                    guard try self.run(arguments,input:input).0 == 0 else {
                        self.report("태블릿의 Tab-D 앱 설치와 USB 디버깅 허용을 확인해주세요"); return
                    }
                }
                self.provisioned=true; self.report(nil)
            } catch {
                self.provisioned=false; self.report("USB 연결 준비에 실패했습니다. 케이블과 태블릿의 USB 디버깅을 확인해주세요")
            }
        }
    }
    private func report(_ value:String?) { DispatchQueue.main.async { self.onStatus?(value) } }
    private func run(_ arguments:[String],input:Data?=nil) throws -> (Int32,Data) {
        let process=Process(); let output=Pipe(); let errors=Pipe(); let source=Pipe()
        process.executableURL=adb; process.arguments=["-d"]+arguments
        process.standardOutput=output; process.standardError=errors; process.standardInput=source
        try process.run()
        let timeout=DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline:.now()+5,execute:timeout)
        if let input { source.fileHandleForWriting.write(input) }
        try? source.fileHandleForWriting.close()
        let bytes=output.fileHandleForReading.readDataToEndOfFile()
        _=errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel()
        return (process.terminationStatus,bytes)
    }
}
