import Foundation

@main enum WakeRecoveryTests {
    static func main() {
        var wake=WakeRecovery()
        wake.interrupt(.displaySleep);wake.awaken(.displaySleep)
        assert(!wake.pending,"Idle must not create a monitor on wake")
        wake.requestStart();wake.interrupt(.systemSleep);wake.interrupt(.displaySleep);wake.interrupt(.screenLocked)
        assert(wake.pending && !wake.mayAttempt)
        let old=wake.generation
        assert(!wake.interrupt(.screenLocked) && wake.generation == old,"Duplicate sleep cannot reset a retry budget")
        wake.awaken(.systemSleep);wake.awaken(.displaySleep)
        assert(!wake.mayAttempt,"A lit but locked Mac must not capture")
        wake.awaken(.screenLocked)
        assert(wake.mayAttempt && wake.generation != old)
        for _ in 0..<3 { assert(wake.mayAttempt);wake.attempted() }
        assert(!wake.mayAttempt,"Transient failures have finite attempts")
        wake.exhaust();assert(!wake.pending && wake.intent == .streaming)
        wake.requestStart();wake.interrupt(.displaySleep);wake.requestStop();wake.awaken(.displaySleep)
        assert(wake.intent == .none && !wake.pending && !wake.mayAttempt,"Stop while asleep cannot resurrect")
        wake.requestStart();wake.requestPause();wake.interrupt(.systemSleep);wake.awaken(.systemSleep)
        assert(wake.intent == .paused && !wake.pending,"Android background pause must stay paused")
        wake.requestStart();wake.interrupt(.displaySleep);wake.awaken(.displaySleep);wake.attempted();wake.complete()
        assert(!wake.pending && wake.attempts == 0 && wake.intent == .streaming)
        wake.recover();wake.interrupt(.sessionInactive);assert(!wake.mayAttempt)
        wake.awaken(.sessionInactive);assert(wake.mayAttempt)
        wake.requestStop();wake.recover();assert(!wake.pending)
        print("PASS: overlapping sleep/lock blockers, finite wake retries, stale generation, idle/paused preservation and explicit-stop suppression")
    }
}
