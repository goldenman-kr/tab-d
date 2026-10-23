import AppKit

/// Posts process-local notifications only; never sleeps, locks or unlocks macOS.
@main enum HostEnvironmentTests {
    @MainActor static func main() async throws {
        let environment=HostEnvironment()
        var policy=WakeRecovery()
        var changes=0
        var hints=0
        var topology=0
        environment.onChange={ reason, blocked in
            changes += 1
            if blocked { policy.interrupt(reason) } else { policy.awaken(reason) }
        }
        environment.onWakeHint={ hints += 1 }
        environment.onTopologyChange={ topology += 1 }
        environment.start()
        // Normal tests run in the signed-in user's active unlocked session.
        policy.requestStart()
        let center=NSWorkspace.shared.notificationCenter
        center.post(name:NSWorkspace.willSleepNotification,object:nil)
        center.post(name:NSWorkspace.screensDidSleepNotification,object:nil)
        center.post(name:NSWorkspace.sessionDidResignActiveNotification,object:nil)
        try await Task.sleep(nanoseconds:30_000_000)
        assert(policy.blockers.isSuperset(of:[.systemSleep,.displaySleep,.sessionInactive]))
        assert(!policy.mayAttempt)
        let count=changes
        center.post(name:NSWorkspace.willSleepNotification,object:nil)
        try await Task.sleep(nanoseconds:30_000_000)
        assert(changes == count,"Duplicate sleep must not reset recovery")
        environment.refresh()
        assert(policy.blockers.contains(.displaySleep),"Screen polling must not clear a workspace sleep")
        assert(policy.blockers.contains(.sessionInactive),"Session polling must not clear a workspace resignation")
        center.post(name:NSWorkspace.didWakeNotification,object:nil)
        center.post(name:NSWorkspace.screensDidWakeNotification,object:nil)
        try await Task.sleep(nanoseconds:30_000_000)
        assert(!policy.mayAttempt && policy.blockers.contains(.sessionInactive))
        center.post(name:NSWorkspace.sessionDidBecomeActiveNotification,object:nil)
        NotificationCenter.default.post(name:NSApplication.didChangeScreenParametersNotification,object:nil)
        try await Task.sleep(nanoseconds:30_000_000)
        assert(policy.mayAttempt && hints == 3 && topology == 1)
        policy.requestStop()
        center.post(name:NSWorkspace.screensDidSleepNotification,object:nil)
        center.post(name:NSWorkspace.screensDidWakeNotification,object:nil)
        try await Task.sleep(nanoseconds:30_000_000)
        assert(!policy.pending && policy.intent == .none)
        environment.stop()
        let stopped=changes
        center.post(name:NSWorkspace.willSleepNotification,object:nil)
        try await Task.sleep(nanoseconds:30_000_000)
        assert(changes == stopped,"Observer stop must remove workspace subscriptions")
        print("PASS: process-local system/display/user-switch notifications, overlap/deduplication, no polling unlock, explicit Stop and observer teardown")
    }
}
