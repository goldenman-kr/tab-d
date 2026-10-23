import AppKit
import CoreGraphics

/// Workspace notifications cover power and user switching. Lock notifications and
/// the CG session lock flag are undocumented macOS interfaces used by this personal app.
@MainActor final class HostEnvironment {
    var onChange: ((HostInterruption, Bool) -> Void)?
    var onWakeHint: (() -> Void)?
    var onTopologyChange: (() -> Void)?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var lockTokens: [NSObjectProtocol] = []
    private var topologyToken: NSObjectProtocol?
    private var observed: Set<HostInterruption> = []
    private var lastLockNotification: TimeInterval = 0

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for (sleep, wake, reason) in [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, HostInterruption.systemSleep),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, .displaySleep),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive)
        ] {
            workspaceTokens.append(center.addObserver(forName:sleep,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor in self?.set(reason, true) }
            })
            workspaceTokens.append(center.addObserver(forName:wake,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor in
                    self?.set(reason, false)
                    self?.refresh()
                    self?.onWakeHint?()
                }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            lockTokens.append(distributed.addObserver(forName:Notification.Name(name),object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.lastLockNotification=ProcessInfo.processInfo.systemUptime
                    self.set(.screenLocked,locked)
                    if !locked { self.onWakeHint?() }
                }
            })
        }
        topologyToken=NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,
            object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.onTopologyChange?() }
        }
        refresh()
    }
    func refresh() {
        if let session = CGSessionCopyCurrentDictionary() as? [String:Any], !session.isEmpty {
            if ProcessInfo.processInfo.systemUptime-lastLockNotification > 1,
               let locked=session["CGSSessionScreenIsLocked"] as? Bool {
                // Polling may discover a missed lock, but only an explicit
                // unlock notification may clear it. WindowServer can briefly
                // report stale false values during the lock transition.
                if locked { set(.screenLocked,true) }
            }
            if let onConsole=session[kCGSessionOnConsoleKey as String] as? Bool, !onConsole {
                set(.sessionInactive,true)
            }
        }
        // CGDisplayIsAsleep polling can race asynchronous workspace notifications.
        // Do not let polling clear a real screen-sleep interruption.
    }
    private func set(_ reason:HostInterruption,_ blocked:Bool) {
        let changed = blocked ? observed.insert(reason).inserted : observed.remove(reason) != nil
        if changed { onChange?(reason,blocked) }
    }
    func stop() {
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        lockTokens.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        if let topologyToken { NotificationCenter.default.removeObserver(topologyToken) }
        workspaceTokens=[]; lockTokens=[]; topologyToken=nil
    }
}
