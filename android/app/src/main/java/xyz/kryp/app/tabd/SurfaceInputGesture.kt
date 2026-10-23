package xyz.kryp.app.tabd

/** One contact owns exactly one of: click, stationary right click, or left drag. */
internal class SurfaceInputGesture(private val slop: Float, private val holdMillis: Long = 500) {
    data class Point(val epoch: Long, val x: Float, val y: Float)
    sealed interface Action {
        data class Click(val point: Point, val button: String) : Action
        data class Begin(val point: Point) : Action
        data class Move(val point: Point) : Action
        data class End(val point: Point) : Action
        data class Cancel(val point: Point) : Action
    }
    private enum class Mode { PENDING, RIGHT_CLICKED, DRAGGING }
    private data class Contact(val x: Float, val y: Float, val time: Long, val epoch: Long, val width: Int, val height: Int)
    private var contact: Contact? = null
    private var mode = Mode.PENDING
    private var last: Point? = null
    val dragging get() = contact != null && mode == Mode.DRAGGING

    fun begin(x: Float, y: Float, time: Long, epoch: Long, width: Int, height: Int) {
        contact = if (width > 0 && height > 0 && epoch >= 0 && x.isFinite() && y.isFinite() &&
            x >= 0 && y >= 0 && x < width && y < height) Contact(x, y, time, epoch, width, height) else null
        mode = Mode.PENDING
        last = contact?.let { point(it, x, y) }
    }
    fun hold(time: Long, epoch: Long, width: Int, height: Int): List<Action> {
        val start = contact ?: return emptyList()
        if (!matches(start, time, epoch, width, height)) return cancel()
        if (mode != Mode.PENDING || time - start.time < holdMillis) return emptyList()
        mode = Mode.RIGHT_CLICKED
        return listOf(Action.Click(last!!, "right"))
    }
    fun move(x: Float, y: Float, time: Long, epoch: Long, width: Int, height: Int): List<Action> {
        val start = contact ?: return emptyList()
        if (!matches(start, time, epoch, width, height) || !x.isFinite() || !y.isFinite()) return cancel()
        // A delayed event after the deadline cannot turn an already completed hold into a drag.
        val held = hold(time, epoch, width, height)
        if (mode == Mode.RIGHT_CLICKED) return held
        last = point(start, x, y)
        if (mode == Mode.DRAGGING) return listOf(Action.Move(last!!))
        val dx = x - start.x; val dy = y - start.y
        if (dx * dx + dy * dy <= slop * slop) return emptyList()
        mode = Mode.DRAGGING
        return listOf(Action.Begin(point(start, start.x, start.y)), Action.Move(last!!))
    }
    fun end(x: Float, y: Float, time: Long, epoch: Long, width: Int, height: Int): List<Action> {
        val actions = move(x, y, time, epoch, width, height).toMutableList()
        if (contact != null) when (mode) {
            Mode.PENDING -> actions.add(Action.Click(last!!, "left"))
            Mode.DRAGGING -> actions.add(Action.End(last!!))
            Mode.RIGHT_CLICKED -> Unit
        }
        clear()
        return actions
    }
    fun cancel(): List<Action> {
        val actions = if (dragging) listOf(Action.Cancel(last!!)) else emptyList()
        clear()
        return actions
    }
    private fun clear() { contact = null; last = null; mode = Mode.PENDING }
    private fun matches(start: Contact, time: Long, epoch: Long, width: Int, height: Int) =
        time >= start.time && epoch == start.epoch && width == start.width && height == start.height
    private fun point(start: Contact, x: Float, y: Float) = Point(start.epoch,
        (x / start.width).coerceIn(0f, 1f), (y / start.height).coerceIn(0f, 1f))
}
