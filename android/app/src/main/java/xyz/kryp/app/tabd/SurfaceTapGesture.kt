package xyz.kryp.app.tabd

/** Tracks one short, stationary contact; coordinates refer only to the fitted video surface. */
internal class SurfaceTapGesture(private val slop: Float, private val timeoutMillis: Long) {
    data class Tap(val epoch: Long, val x: Float, val y: Float)
    private data class Down(val x: Float, val y: Float, val time: Long, val epoch: Long, val width: Int, val height: Int)
    private var down: Down? = null

    fun begin(x: Float, y: Float, time: Long, epoch: Long, width: Int, height: Int) {
        down = if (inside(x, y, width, height)) Down(x, y, time, epoch, width, height) else null
    }
    fun move(x: Float, y: Float) {
        val start = down ?: return
        val dx = x - start.x; val dy = y - start.y
        if (!inside(x, y, start.width, start.height) || dx * dx + dy * dy > slop * slop) cancel()
    }
    fun end(x: Float, y: Float, time: Long, epoch: Long, width: Int, height: Int): Tap? {
        val start = down ?: return null
        move(x, y)
        val valid = down != null && time - start.time in 0..timeoutMillis && epoch == start.epoch &&
            width == start.width && height == start.height
        cancel()
        return if (valid) Tap(epoch, x / width, y / height) else null
    }
    fun cancel() { down = null }
    private fun inside(x: Float, y: Float, width: Int, height: Int) = width > 0 && height > 0 &&
        x.isFinite() && y.isFinite() && x >= 0 && y >= 0 && x < width && y < height
}
