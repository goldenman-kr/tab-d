import Foundation

enum SessionPhase: String {
    case idle, ready, starting, streaming, paused, recovering, failed
}

/// Pure host-owned state. Epochs invalidate work from older async operations.
struct SessionMachine {
    private(set) var phase: SessionPhase = .idle
    private(set) var displayID: UInt32?
    private(set) var epoch: UInt32 = 0

    mutating func peerReady() {
        if displayID == nil && phase != .starting { phase = .ready }
    }
    mutating func begin() -> UInt32 {
        epoch &+= 1
        phase = .starting
        return epoch
    }
    mutating func attach(_ id: UInt32, epoch expected: UInt32) -> Bool {
        guard epoch == expected, phase == .starting, id != 0 else { return false }
        displayID = id
        return true
    }
    mutating func presented(epoch expected: UInt32) -> Bool {
        guard epoch == expected, displayID != nil, phase == .starting || phase == .streaming else { return false }
        phase = .streaming
        return true
    }
    mutating func pause() -> UInt32 {
        epoch &+= 1
        phase = displayID == nil ? .ready : .paused
        return epoch
    }
    mutating func losePeer() -> UInt32? {
        // A confirmed pause deliberately outlives Android sockets/processes.
        if phase == .paused { return nil }
        epoch &+= 1
        phase = displayID == nil ? .idle : .recovering
        return displayID == nil ? nil : epoch
    }
    mutating func expireRecovery(epoch expected: UInt32) -> UInt32? {
        guard epoch == expected, phase == .recovering else { return nil }
        return end()
    }
    @discardableResult mutating func end(failed: Bool = false) -> UInt32? {
        let removed = displayID
        epoch &+= 1
        displayID = nil
        phase = failed ? .failed : .idle
        return removed
    }
}
