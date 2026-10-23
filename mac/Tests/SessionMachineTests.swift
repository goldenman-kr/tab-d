import Foundation

@main struct SessionMachineTests {
    static func main() {
        var state = SessionMachine()
        state.peerReady()
        let first = state.begin()
        assert(state.attach(42, epoch:first))
        assert(state.presented(epoch:first))
        _ = state.pause()
        assert(state.phase == .paused && state.displayID == 42)
        assert(state.losePeer() == nil && state.displayID == 42)
        assert(!state.presented(epoch:first), "A late frame cannot undo pause")
        let resumed = state.begin()
        assert(state.attach(42, epoch:resumed))
        assert(!state.presented(epoch:first))
        assert(state.presented(epoch:resumed) && state.displayID == 42)
        let recovery = state.losePeer()!
        _ = state.pause()
        assert(state.expireRecovery(epoch:recovery) == nil, "Old timeout cannot remove a paused display")
        let second = state.begin()
        assert(state.attach(42, epoch:second))
        let oldRecovery = state.losePeer()!
        state.peerReady()
        let quickReturn = state.begin()
        assert(state.attach(42, epoch:quickReturn))
        assert(state.expireRecovery(epoch:oldRecovery) == nil, "Old timeout cannot remove a quickly resumed display")
        assert(state.presented(epoch:quickReturn))
        let expired = state.losePeer()!
        assert(state.expireRecovery(epoch:expired) == 42 && state.displayID == nil)
        state.peerReady()
        let third = state.begin()
        assert(state.attach(43, epoch:third))
        assert(state.end() == 43)
        assert(!state.presented(epoch:third) && state.displayID == nil)
        assert(!state.attach(43, epoch:third), "Explicit stop cannot resurrect old async setup")
        print("PASS: pause ownership, resume epoch, stale frame, timeout race, explicit stop")
    }
}
