package xyz.kryp.app.tabd

/** Reconcile host lifetime before sending commands; video presentation has a separate host deadline. */
class HostRecoveryGate(private val timeoutMillis: Long = 5000) {
    enum class Action { NONE, HOLD, START, RESUME }
    var awaitingStatus = true; private set
    var suspended = false; private set
    var recovering = false; private set
    var awaitingCommand: String? = null; private set
    var deadlineMillis: Long? = null; private set
    var retryBlocked = false; private set

    fun connectionReset() {
        awaitingStatus = true
        suspended = false
        recovering = false
        cancelCommand()
        retryBlocked = false
    }
    fun userRetry() { retryBlocked = false }
    fun helloAcknowledged(now: Long) {
        if (awaitingStatus) commandSent("status", now)
    }
    fun cancelCommand() { awaitingCommand = null; deadlineMillis = null }
    fun commandSent(command: String, now: Long) {
        awaitingCommand = command
        deadlineMillis = now + timeoutMillis
    }
    fun canRequest() = !awaitingStatus && !suspended && !retryBlocked && awaitingCommand == null

    fun status(state: String, hostSuspended: Boolean, hostRecovering: Boolean, intent: Boolean): Action {
        val reconcile = awaitingStatus || suspended || hostRecovering
        if (awaitingStatus) cancelCommand()
        awaitingStatus = false
        suspended = hostSuspended
        recovering = hostRecovering
        if (suspended) { cancelCommand(); return Action.HOLD }
        if (state == "starting" || state == "streaming") {
            cancelCommand()
            retryBlocked = false
            return Action.NONE
        }
        if ((state == "ready" || state == "stopped") && !recovering) cancelCommand()
        if (!canRequest() || !intent) return Action.NONE
        return when {
            state == "paused" && reconcile -> Action.RESUME
            recovering && (state == "ready" || state == "stopped") -> Action.START
            else -> Action.NONE
        }
    }
    fun expire(now: Long): Boolean {
        val deadline = deadlineMillis ?: return false
        if (now < deadline) return false
        cancelCommand()
        retryBlocked = true
        return true
    }
}
