import AppKit
import Foundation
import Security
import CryptoKit

enum DirectUpdateInstaller {
    struct Prepared {
        let staged: URL
        let target: URL
        func discard() { try? FileManager.default.removeItem(at: staged) }
        @MainActor func launchAndQuit() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tabd-installer-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let script = directory.appendingPathComponent("install.sh")
            // Only fixed local code is executed. All paths are passed as separate argv values.
            let source = """
            #!/bin/sh
            set -u
            oldpid="$1"
            staged="$2"
            target="$3"
            backup="$4"
            installer_dir="$5"
            count=0
            while /bin/kill -0 "$oldpid" 2>/dev/null; do
              count=$((count + 1))
              if [ "$count" -gt 45 ]; then
                /bin/rm -rf "$staged" "$installer_dir"
                exit 1
              fi
              /bin/sleep 1
            done
            if ! /bin/mv "$target" "$backup"; then
              /bin/rm -rf "$staged" "$installer_dir"
              exit 1
            fi
            if ! /bin/mv "$staged" "$target"; then
              /bin/mv "$backup" "$target"
              /usr/bin/open "$target"
              /bin/rm -rf "$installer_dir"
              exit 1
            fi
            if ! /usr/bin/open -n "$target"; then
              /bin/rm -rf "$target"
              /bin/mv "$backup" "$target"
              /usr/bin/open "$target"
              /bin/rm -rf "$installer_dir"
              exit 1
            fi
            /bin/rm -rf "$backup" "$installer_dir"
            """
            try source.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let backup = target.deletingLastPathComponent().appendingPathComponent(".Mr-Tab-D-previous-\(UUID().uuidString).app")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), staged.path, target.path, backup.path, directory.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            NSApp.terminate(nil)
        }
    }
    enum Failure: LocalizedError {
        case invalidApp, signer, command
        var errorDescription: String? {
            switch self {
            case .invalidApp: return "다운로드한 Mac 앱의 버전 또는 구성이 올바르지 않습니다."
            case .signer: return "다운로드한 앱의 코드 서명이 현재 앱과 다릅니다. 설치를 중단했습니다."
            case .command: return "업데이트 설치 파일을 준비하지 못했습니다."
            }
        }
    }
    static var canReplaceCurrentApp: Bool {
        let target = Bundle.main.bundleURL.resolvingSymlinksInPath()
        return target.pathExtension == "app" &&
            Bundle.main.object(forInfoDictionaryKey: "TabDDevelopmentStateDirectory") == nil &&
            FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path)
    }
    static func prepare(dmg: URL, expectedVersion: String, currentApp: URL = Bundle.main.bundleURL) throws -> Prepared {
        let fm = FileManager.default
        let target = currentApp.resolvingSymlinksInPath()
        guard let currentInfo = NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist")),
              let currentIdentifier = currentInfo["CFBundleIdentifier"] as? String else { throw Failure.invalidApp }
        let mount = fm.temporaryDirectory.appendingPathComponent("tabd-image-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer {
            try? run("/usr/bin/hdiutil", ["detach", mount.path])
            try? fm.removeItem(at: mount)
        }
        try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        let source = mount.appendingPathComponent("Mr. Tab-D.app", isDirectory: true)
        guard let info = NSDictionary(contentsOf: source.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == currentIdentifier,
              info["CFBundleShortVersionString"] as? String == expectedVersion else { throw Failure.invalidApp }
        let signer = try signerHash(target)
        guard try signerHash(source) == signer else { throw Failure.signer }
        let staged = target.deletingLastPathComponent().appendingPathComponent(".Mr-Tab-D-update-\(UUID().uuidString).app")
        do {
            try run("/usr/bin/ditto", [source.path, staged.path])
            guard try signerHash(staged) == signer else { throw Failure.signer }
            return Prepared(staged: staged, target: target)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }
    private static func signerHash(_ url: URL) throws -> Data {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess else { throw Failure.signer }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any], let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let certificate = certificates.first else { throw Failure.signer }
        return Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data))
    }
    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 30) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            throw Failure.command
        }
        guard process.terminationStatus == 0 else { throw Failure.command }
    }
}
