package xyz.kryp.app.tabd

import kotlin.math.abs

/** Tracks IDs rather than MotionEvent indices; reports normalized vertical centroid displacement. */
internal class TwoFingerScrollGesture(private val slop: Float) {
    data class Pointer(val id: Int, val x: Float, val y: Float)
    data class Delta(val epoch: Long, val x: Float, val y: Float, val deltaY: Float)
    private data class PairState(val firstID: Int, val secondID: Int, val epoch: Long, val width: Int, val height: Int,
        val initialY: Float, var lastY: Float, var started: Boolean = false)
    private var pair: PairState? = null
    val tracking get() = pair != null
    val scrolling get() = pair?.started == true

    fun begin(pointers: List<Pointer>, epoch: Long, width: Int, height: Int): Boolean {
        cancel()
        if (epoch < 0 || width <= 0 || height <= 0 || pointers.size != 2 || pointers[0].id == pointers[1].id ||
            pointers.any { it.id < 0 || !it.x.isFinite() || !it.y.isFinite() }) return false
        val initialY = (pointers[0].y.coerceIn(0f, height.toFloat()) + pointers[1].y.coerceIn(0f, height.toFloat())) / 2
        pair = PairState(pointers[0].id, pointers[1].id, epoch, width, height, initialY, initialY)
        return true
    }
    fun move(pointers: List<Pointer>, epoch: Long, width: Int, height: Int): Delta? {
        val state = pair ?: return null
        if (epoch != state.epoch || width != state.width || height != state.height || pointers.size != 2 ||
            pointers.map { it.id }.toSet().size != 2 || pointers.any { !it.x.isFinite() || !it.y.isFinite() }) {
            cancel(); return null
        }
        val first = pointers.find { it.id == state.firstID }
        val second = pointers.find { it.id == state.secondID }
        if (first == null || second == null) { cancel(); return null }
        val x = (first.x.coerceIn(0f, width.toFloat()) + second.x.coerceIn(0f, width.toFloat())) / 2
        val y = (first.y.coerceIn(0f, height.toFloat()) + second.y.coerceIn(0f, height.toFloat())) / 2
        if (!state.started && abs(y - state.initialY) <= slop) return null
        state.started = true
        val dy = (y - state.lastY) / height
        state.lastY = y
        return if (dy == 0f) null else Delta(epoch, x / width, y / height, dy.coerceIn(-1f, 1f))
    }
    fun cancel() { pair = null }
}

/** Coalescing retains displacement while using the newest centroid as the wheel anchor. */
internal fun combineScrollDelta(previous: TwoFingerScrollGesture.Delta?, latest: TwoFingerScrollGesture.Delta): TwoFingerScrollGesture.Delta {
    val sum = latest.deltaY.toDouble() + if (previous?.epoch == latest.epoch) previous.deltaY.toDouble() else 0.0
    return latest.copy(deltaY = sum.coerceIn(-1.0, 1.0).toFloat())
}
