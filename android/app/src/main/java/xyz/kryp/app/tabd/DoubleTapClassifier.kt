package xyz.kryp.app.tabd

/** Marks only the second completed short tap; the first click is never delayed or replayed. */
internal class DoubleTapClassifier(private val timeoutMillis: Long, private val slop: Float) {
    data class Sample(val x: Float, val y: Float, val time: Long, val epoch: Long, val width: Int, val height: Int)
    private var previousUp: Sample? = null
    private var currentDown: Sample? = null
    private var second = false

    fun down(sample: Sample) {
        if (currentDown != null || !valid(sample)) reset()
        currentDown = sample.takeIf(::valid)
        val previous = previousUp
        second = previous != null && currentDown != null && sameSurface(previous, sample) &&
            sample.time - previous.time in 0..timeoutMillis &&
            (sample.x - previous.x) * (sample.x - previous.x) + (sample.y - previous.y) * (sample.y - previous.y) <= slop * slop
    }
    fun up(sample: Sample?): Int {
        val down = currentDown
        if (sample == null || down == null || !valid(sample) || !sameSurface(down, sample) ||
            sample.time - down.time !in 0 until 500L) {
            reset()
            return 1
        }
        val count = if (second) 2 else 1
        // A completed pair is consumed. A third tap starts a new pair with count 1.
        previousUp = sample.takeIf { count == 1 }
        currentDown = null
        second = false
        return count
    }
    fun reset() { previousUp = null; currentDown = null; second = false }
    private fun sameSurface(a: Sample, b: Sample) = a.epoch == b.epoch && a.width == b.width && a.height == b.height
    private fun valid(sample: Sample) = sample.width > 0 && sample.height > 0 && sample.epoch >= 0 && sample.time >= 0 &&
        sample.x.isFinite() && sample.y.isFinite() && sample.x >= 0 && sample.y >= 0 && sample.x < sample.width && sample.y < sample.height
}
