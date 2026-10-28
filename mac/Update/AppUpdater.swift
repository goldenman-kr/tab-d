import AppKit
import Combine
import Foundation

@MainActor final class AppUpdater: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    private let canPrompt: () -> Bool
    private var checkedAutomatically = false
    private var pending: (ReleaseAsset, ReleaseAsset, UpdateVersion)?
    private var promptTimer: Timer?
    private var task: Task<Void, Never>?

    init(canPrompt: @escaping () -> Bool = { true }) { self.canPrompt = canPrompt }

    func check(manual: Bool = false) {
        guard !busy else { return }
        if !manual && checkedAutomatically { return }
        if !manual { checkedAutomatically = true }
        guard let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let version = UpdateVersion(current) else { return }
        busy = true; status = "업데이트 확인 중…"
        task = Task { [weak self] in
            do {
                let data = try await UpdateHTTP.fetch(URL(string: "https://api.github.com/repos/goldenman-kr/tab-d/releases/latest")!, limit: 1024 * 1024)
                let release = try JSONDecoder().decode(UpdateRelease.self, from: data)
                guard let self, !Task.isCancelled else { return }
                self.busy = false; self.status = nil
                if let update = release.macUpdate(after: version) {
                    self.pending = update
                    self.showPending(manual: manual)
                } else if manual {
                    self.notice("최신 Mac 버전입니다", "현재 Mac 앱 \(current)을 사용 중입니다.")
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.busy = false; self.status = nil
                if manual { self.notice("업데이트 확인 실패", "네트워크 연결을 확인하고 다시 시도해주세요.\n\(error.localizedDescription)") }
            }
        }
    }

    private func showPending(manual: Bool = false) {
        guard let update = pending else { return }
        guard manual || canPrompt() else {
            if promptTimer == nil {
                promptTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.showPending() }
                }
            }
            return
        }
        promptTimer?.invalidate(); promptTimer = nil
        pending = nil
        let alert = NSAlert()
        alert.messageText = "Mr. Tab-D \(update.2.description) 업데이트"
        alert.informativeText = "새 Mac 버전을 사용할 수 있습니다. 설치 파일과 코드 서명을 확인한 뒤 앱을 업데이트하고 다시 시작합니다. 업데이트 설치 시 사용 중인 화면 연결은 종료됩니다."
        alert.addButton(withTitle: "지금 업데이트")
        alert.addButton(withTitle: "나중에")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { download(update) }
    }

    private func download(_ update: (ReleaseAsset, ReleaseAsset, UpdateVersion)) {
        guard let assetURL = update.0.trustedURL, let sumsURL = update.1.trustedURL else { return }
        busy = true; status = "업데이트 다운로드 중…"
        task = Task { [weak self] in
            do {
                let sums = try await UpdateHTTP.fetch(sumsURL, limit: 65536)
                let data = try await UpdateHTTP.fetch(assetURL, limit: 64 * 1024 * 1024)
                guard data.count == update.0.size else { throw UpdateCheckError.downloadSize }
                try verifyUpdateChecksum(data, manifest: sums, name: update.0.name)
                guard let self, !Task.isCancelled else { return }
                let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Mr. Tab-D Updates", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(update.0.name)
                try data.write(to: destination, options: .atomic)
                if DirectUpdateInstaller.canReplaceCurrentApp {
                    self.status = "업데이트 설치 준비 중…"
                    let prepared = try await Task.detached {
                        try DirectUpdateInstaller.prepare(dmg: destination, expectedVersion: update.2.description)
                    }.value
                    guard !Task.isCancelled else { prepared.discard(); return }
                    self.busy = false; self.status = nil
                    let alert = NSAlert()
                    alert.messageText = "업데이트를 설치할 준비가 되었습니다"
                    alert.informativeText = "다운로드와 코드 서명 확인을 완료했습니다. 설치하면 Mr. Tab-D가 종료되고 새 버전으로 다시 시작합니다. 사용 중인 모니터 연결도 종료됩니다."
                    alert.addButton(withTitle: "설치 후 다시 시작")
                    alert.addButton(withTitle: "나중에")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn {
                        do { try prepared.launchAndQuit() }
                        catch { prepared.discard(); throw error }
                    } else { prepared.discard() }
                } else {
                    self.busy = false; self.status = nil
                    if !NSWorkspace.shared.open(destination) { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
                    let alert = NSAlert()
                    alert.messageText = "다운로드가 완료되었습니다"
                    alert.informativeText = "현재 설치 방식에서는 직접 설치가 필요합니다. 개발 빌드에서 전환하면 USB 페어링이 다시 필요할 수 있습니다.\n\n1. Mr. Tab-D를 종료합니다.\n2. 열린 디스크 이미지의 Mr. Tab-D.app을 Applications 폴더로 드래그하고 기존 앱을 대치합니다.\n3. Applications에서 Mr. Tab-D를 다시 실행합니다.\n\n설치 파일: \(destination.path)"
                    alert.addButton(withTitle: "앱 종료 후 설치")
                    alert.addButton(withTitle: "나중에 설치")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.busy = false; self.status = nil
                self.notice("업데이트 다운로드 실패", "\(error.localizedDescription)\n잠시 후 메뉴의 업데이트 확인에서 다시 시도해주세요.")
            }
        }
    }
    private func notice(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "확인")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    func close() {
        task?.cancel(); promptTimer?.invalidate(); promptTimer = nil
    }
}
