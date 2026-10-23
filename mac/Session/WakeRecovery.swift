import Foundation

enum HostInterruption: String, Hashable, CaseIterable {
    case systemSleep, displaySleep, sessionInactive, screenLocked
}

/// Desired session state outlives temporary host unavailability, never explicit Stop.
struct WakeRecovery {
    enum Intent: String { case none, paused, streaming }
    private(set) var intent: Intent = .none
    private(set) var blockers: Set<HostInterruption> = []
    private(set) var pending = false
    private(set) var attempts = 0
    private(set) var generation: UInt64 = 0
    var blocked: Bool { !blockers.isEmpty }
    var mayAttempt: Bool { pending && !blocked && intent == .streaming && attempts < 3 }

    mutating func requestStart() {
        intent = .streaming; pending = blocked; attempts = 0; generation &+= 1
    }
    mutating func requestPause() {
        intent = .paused; pending = false; attempts = 0; generation &+= 1
    }
    mutating func requestStop() {
        intent = .none; pending = false; attempts = 0; generation &+= 1
    }
    @discardableResult mutating func interrupt(_ reason: HostInterruption) -> Bool {
        guard blockers.insert(reason).inserted else { return false }
        pending = intent == .streaming; attempts = 0; generation &+= 1
        return true
    }
    @discardableResult mutating func awaken(_ reason: HostInterruption) -> Bool {
        guard blockers.remove(reason) != nil else { return false }
        generation &+= 1
        return true
    }
    mutating func recover() {
        guard intent == .streaming else { return }
        pending = true; attempts = 0; generation &+= 1
    }
    mutating func attempted() { attempts += 1 }
    mutating func complete() { pending = false; attempts = 0; generation &+= 1 }
    mutating func exhaust() { pending = false; generation &+= 1 }
}
