package xyz.kryp.app.tabd

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Dependency-free tests for untrusted stream boundaries and video metadata. */
object ProtocolCheck {
    @JvmStatic fun main(arguments: Array<String>) {
        println("AndroidUpdatePolicy: ${checkAndroidUpdatePolicy()} version / origin / checksum / signer checks passed")
        val stream = ByteArrayOutputStream()
        Wire.write(DataOutputStream(stream), 1, "hello".toByteArray())
        val data = stream.toByteArray()
        check(data.take(4) == listOf<Byte>(0, 0, 0, 6))
        val result = Wire.read(DataInputStream(ByteArrayInputStream(data)))
        check(result.type == 1 && String(result.body) == "hello")
        for (size in listOf(0, -1, Wire.MAX_PACKET + 1)) {
            val invalid = ByteBuffer.allocate(4).putInt(size).array()
            fails { Wire.read(DataInputStream(ByteArrayInputStream(invalid))) }
        }
        fails { Wire.read(DataInputStream(ByteArrayInputStream(data.copyOf(data.size - 1)))) }
        val video = ByteBuffer.allocate(26).order(ByteOrder.BIG_ENDIAN)
            .putInt(-1).putLong(123L).putLong(456L).put(1).put(byteArrayOf(0, 0, 0, 1, 0x65)).array()
        val frame = Wire.frame(video)
        check(frame.epoch == 0xffffffffL && frame.sequence == 123L && frame.pts == 456L && frame.keyframe)
        check(frame.bytes.contentEquals(byteArrayOf(0, 0, 0, 1, 0x65)))
        fails { Wire.frame(ByteArray(21)) }
        fails { Wire.frame(video.copyOf().apply { this[20] = 2 }) }
        fails { Wire.frame(video.copyOf().apply { this[4] = 0xff.toByte() }) }
        checkDecoderSelection()
        checkSurfaceTap()
        checkSurfaceInput()
        checkDoubleTap()
        checkTwoFingerScroll()
        val recoveryChecks = checkHostRecovery()
        println("ProtocolCheck: 9 framing / metadata checks passed")
        println("DecoderSelection: 5 low-latency component selection checks passed")
        println("SurfaceTapGesture: 9 contact / coordinate rejection checks passed")
        println("SurfaceInputGesture: 16 click / hold / drag transition checks passed")
        println("DoubleTapClassifier: 20 timing / distance / interruption checks passed")
        println("TwoFingerScrollGesture: 21 centroid / ID / cancellation / coalescing checks passed")
        println("HostRecoveryGate: $recoveryChecks handshake / sleep / stop / deadline checks passed")
    }
    private fun checkHostRecovery(): Int {
        val gate = HostRecoveryGate()
        var checks = 0
        fun expect(value: Boolean) { check(value); checks++ }
        val none = HostRecoveryGate.Action.NONE
        val resume = HostRecoveryGate.Action.RESUME
        val start = HostRecoveryGate.Action.START
        val hold = HostRecoveryGate.Action.HOLD
        expect(!gate.canRequest()) // helloAck alone cannot resurrect an old display.
        gate.helloAcknowledged(100)
        expect(gate.awaitingCommand == "status" && gate.deadlineMillis == 5100L && !gate.canRequest())
        expect(gate.status("ready", false, false, true) == none && gate.canRequest())
        gate.connectionReset()
        expect(gate.status("paused", false, false, true) == resume && gate.canRequest())
        gate.commandSent("resume", 1000)
        expect(gate.status("paused", false, false, true) == none && !gate.canRequest())
        expect(!gate.expire(5999) && gate.awaitingCommand == "resume")
        expect(gate.expire(6000) && gate.retryBlocked && gate.awaitingCommand == null)
        expect(gate.status("paused", false, true, true) == none && !gate.canRequest())
        gate.userRetry()
        expect(gate.status("paused", false, true, true) == resume)
        gate.commandSent("resume", 7000)
        expect(gate.status("starting", false, true, true) == none && gate.deadlineMillis == null && !gate.expire(12000))
        gate.commandSent("start", 13000)
        expect(gate.status("streaming", false, false, true) == none && gate.awaitingCommand == null)
        gate.commandSent("resume", 14000)
        expect(gate.status("paused", true, false, true) == hold && gate.suspended && !gate.canRequest() && gate.deadlineMillis == null)
        expect(gate.status("paused", true, false, true) == hold && !gate.expire(20000))
        expect(gate.status("paused", false, false, true) == resume && !gate.suspended)
        expect(gate.status("ready", false, true, true) == start)
        expect(gate.status("stopped", false, true, true) == start)
        expect(gate.status("ready", false, false, true) == none) // Explicit stop never auto-starts.
        gate.commandSent("resume", 21000)
        expect(gate.status("stopped", false, false, true) == none && gate.deadlineMillis == null)
        expect(gate.status("ready", false, true, false) == none) // No previous/user intent.
        expect(gate.status("paused", false, false, true) == none) // Home pause is not a wake event.
        gate.commandSent("start", 22000)
        gate.cancelCommand() // Background / disconnect / destroy / connection loss.
        expect(!gate.expire(30000) && gate.awaitingCommand == null)
        gate.status("paused", true, true, true)
        gate.connectionReset()
        expect(gate.awaitingStatus && !gate.suspended && !gate.recovering && !gate.canRequest())
        gate.helloAcknowledged(31000)
        expect(gate.expire(36000) && gate.awaitingStatus && gate.retryBlocked)
        gate.connectionReset()
        expect(gate.status("paused", false, true, true) == resume && gate.canRequest())
        return checks
    }
    private fun checkDecoderSelection() {
        val normal = DecoderCandidate("c2.qti.avc.decoder", true, false, true)
        val lowLatency = DecoderCandidate("c2.qti.avc.decoder.low_latency", true, true, true)
        check(selectLowLatencyDecoder(listOf(normal, lowLatency)) == lowLatency.name)
        check(selectLowLatencyDecoder(listOf(lowLatency.copy(name = "software", hardware = false), lowLatency)) == lowLatency.name)
        check(selectLowLatencyDecoder(listOf(lowLatency.copy(name = "small", sizeAndRateSupported = false), lowLatency)) == lowLatency.name)
        check(selectLowLatencyDecoder(listOf(lowLatency.copy(secureRequired = true), lowLatency.copy(tunneledRequired = true), lowLatency)) == lowLatency.name)
        check(selectLowLatencyDecoder(listOf(normal)) == null)
    }
    private fun checkSurfaceTap() {
        val tap = SurfaceTapGesture(8f, 300)
        fun begin() = tap.begin(100f, 50f, 1000, 7, 200, 100)
        begin(); check(tap.end(100f, 50f, 1100, 7, 200, 100) == SurfaceTapGesture.Tap(7, .5f, .5f))
        begin(); tap.move(120f, 50f); tap.move(100f, 50f); check(tap.end(100f, 50f, 1100, 7, 200, 100) == null)
        begin(); check(tap.end(100f, 50f, 1301, 7, 200, 100) == null)
        begin(); tap.cancel(); check(tap.end(100f, 50f, 1100, 7, 200, 100) == null)
        begin(); check(tap.end(100f, 50f, 1100, 8, 200, 100) == null)
        begin(); check(tap.end(100f, 50f, 1100, 7, 400, 100) == null)
        begin(); check(tap.end(200f, 50f, 1100, 7, 200, 100) == null)
        tap.begin(Float.NaN, 0f, 1000, 7, 200, 100); check(tap.end(0f, 0f, 1100, 7, 200, 100) == null)
        begin(); check(tap.end(100f, 50f, 999, 7, 200, 100) == null)
    }
    private fun checkSurfaceInput() {
        val gesture = SurfaceInputGesture(8f)
        val origin = SurfaceInputGesture.Point(7, .5f, .5f)
        fun begin() = gesture.begin(100f, 50f, 1000, 7, 200, 100)
        fun move(x: Float = 120f, y: Float = 50f, time: Long = 1100) = gesture.move(x, y, time, 7, 200, 100)
        fun end(x: Float = 100f, y: Float = 50f, time: Long = 1200) = gesture.end(x, y, time, 7, 200, 100)
        fun hold(time: Long = 1500) = gesture.hold(time, 7, 200, 100)

        begin(); check(end() == listOf(SurfaceInputGesture.Action.Click(origin, "left")))
        begin(); check(hold(1499).isEmpty() && hold() == listOf(SurfaceInputGesture.Action.Click(origin, "right")))
        check(hold(1600).isEmpty() && end(time = 1700).isEmpty()) // A hold never adds a left click on release.
        begin(); check(end(time = 1500) == listOf(SurfaceInputGesture.Action.Click(origin, "right"))) // Delayed timer.
        begin(); check(move() == listOf(SurfaceInputGesture.Action.Begin(origin), SurfaceInputGesture.Action.Move(origin.copy(x = .6f))))
        check(gesture.dragging && hold().isEmpty() && move(140f, time = 1600) == listOf(SurfaceInputGesture.Action.Move(origin.copy(x = .7f))))
        check(end(140f, time = 1700) == listOf(SurfaceInputGesture.Action.Move(origin.copy(x = .7f)), SurfaceInputGesture.Action.End(origin.copy(x = .7f))) && !gesture.dragging)
        begin(); move(); check(gesture.cancel() == listOf(SurfaceInputGesture.Action.Cancel(origin.copy(x = .6f))) && end().isEmpty())
        begin(); check(gesture.cancel().isEmpty() && end().isEmpty()) // Extra pointer / system cancellation before drag.
        begin(); move(); check(gesture.move(130f, 50f, 1200, 8, 200, 100) == listOf(SurfaceInputGesture.Action.Cancel(origin.copy(x = .6f))))
        begin(); move(); check(gesture.move(130f, 50f, 1200, 7, 400, 100) == listOf(SurfaceInputGesture.Action.Cancel(origin.copy(x = .6f))))
        begin(); check(move(240f, -10f).last() == SurfaceInputGesture.Action.Move(origin.copy(x = 1f, y = 0f))); gesture.cancel()
        begin(); check(move(105f).isEmpty() && end(105f) == listOf(SurfaceInputGesture.Action.Click(origin.copy(x = .525f), "left")))
        begin(); hold(); check(move(time = 1600).isEmpty() && end(time = 1700).isEmpty()) // Right click cannot become a drag.
        gesture.begin(Float.NaN, 0f, 1000, 7, 200, 100); check(end().isEmpty())
        begin(); check(end(time = 999).isEmpty())
    }
    private fun checkDoubleTap() {
        val taps = DoubleTapClassifier(300, 20f)
        fun sample(time: Long, x: Float = 100f, y: Float = 50f, epoch: Long = 7, width: Int = 200, height: Int = 100) =
            DoubleTapClassifier.Sample(x, y, time, epoch, width, height)
        fun tap(down: Long, up: Long, x: Float = 100f, y: Float = 50f, epoch: Long = 7, width: Int = 200, height: Int = 100): Int {
            taps.down(sample(down, x, y, epoch, width, height))
            return taps.up(sample(up, x, y, epoch, width, height))
        }
        fun first() { taps.reset(); check(tap(1000, 1100) == 1) }

        first(); check(tap(1200, 1250) == 2)
        check(tap(1300, 1350) == 1 && tap(1400, 1450) == 2) // Pairs consume themselves; no count 3.
        first(); check(tap(1400, 1450) == 2) // Inclusive timeout boundary measured from first UP.
        first(); check(tap(1401, 1450) == 1)
        first(); check(tap(1200, 1250, x = 120f) == 2) // Inclusive pixel distance boundary.
        first(); check(tap(1200, 1250, x = 120.1f) == 1)
        first(); check(tap(1200, 1250, x = 115f, y = 65f) == 1) // Euclidean distance, not a box.
        taps.reset(); taps.down(sample(1000)); check(taps.up(sample(1100, x = 105f)) == 1 && tap(1200, 1250, x = 125f) == 2)
        taps.reset(); check(tap(1000, 1450) == 1 && tap(1750, 1800) == 2) // UP-to-DOWN, not DOWN-to-DOWN.
        first(); check(tap(1200, 1699) == 2) // Second contact must remain under the 500 ms hold threshold.
        first(); check(tap(1200, 1700) == 1 && tap(1750, 1800) == 1)
        first(); taps.reset(); check(tap(1200, 1250) == 1) // Drag/right/Back/Home/multitouch/ACK failure reset.
        first(); check(tap(1200, 1250, epoch = 8) == 1)
        first(); check(tap(1200, 1250, width = 400) == 1)
        first(); check(tap(1200, 1250, height = 200) == 1)
        first(); taps.down(sample(1200)); check(taps.up(sample(1250, epoch = 8)) == 1 && tap(1300, 1350) == 1)
        first(); check(tap(1099, 1150) == 1) // Negative gap cannot match the prior tap.
        first(); taps.down(sample(1200)); check(taps.up(sample(1199)) == 1 && tap(1300, 1350) == 1)
        first(); taps.down(sample(1200, x = Float.NaN)); check(taps.up(sample(1250)) == 1 && tap(1300, 1350) == 1)
        first(); taps.down(sample(1200)); taps.down(sample(1210)); check(taps.up(sample(1250)) == 1)
    }
    private fun checkTwoFingerScroll() {
        val scroll = TwoFingerScrollGesture(8f)
        fun pair(y: Float = 50f, x: Float = 100f) = listOf(TwoFingerScrollGesture.Pointer(3, x - 20, y), TwoFingerScrollGesture.Pointer(9, x + 20, y))
        fun begin() { check(scroll.begin(pair(), 7, 200, 100)) }
        fun move(pointers: List<TwoFingerScrollGesture.Pointer>) = scroll.move(pointers, 7, 200, 100)
        fun close(actual: Float, expected: Float) = kotlin.math.abs(actual - expected) < .00001f

        begin(); check(move(pair()) == null && scroll.tracking && !scroll.scrolling)
        check(move(pair(x = 150f)) == null && !scroll.scrolling) // Horizontal-only travel never scrolls.
        check(move(pair(y = 58f)) == null && !scroll.scrolling) // Inclusive vertical slop.
        check(move(pair(y = 59f))?.let { close(it.deltaY, .09f) && close(it.y, .59f) && it.x == .5f } == true)
        check(move(pair(y = 79f))?.let { close(it.deltaY, .2f) } == true && scroll.scrolling)
        check(move(pair(y = 79f, x = 130f)) == null) // No dy after activation still means no packet.
        begin(); check(move(pair(y = 30f))?.let { close(it.deltaY, -.2f) } == true)
        begin(); check(move(pair(y = 70f).reversed())?.let { close(it.deltaY, .2f) && it.x == .5f } == true)
        begin(); check(move(listOf(TwoFingerScrollGesture.Pointer(9, 120f, 50f), TwoFingerScrollGesture.Pointer(3, 80f, 70f)))?.let { close(it.deltaY, .1f) } == true)
        begin(); check(move(listOf(TwoFingerScrollGesture.Pointer(3, 80f, 70f), TwoFingerScrollGesture.Pointer(9, 120f, 30f))) == null)
        begin(); check(move(pair(y = 1000f, x = 1000f))?.let { it.x == 1f && it.y == 1f && it.deltaY == .5f } == true &&
            move(pair(y = -100f, x = -100f))?.let { it.x == 0f && it.y == 0f && it.deltaY == -1f } == true)
        check(!scroll.begin(pair().map { it.copy(y = Float.NaN) }, 7, 200, 100))
        begin(); check(move(pair() + TwoFingerScrollGesture.Pointer(11, 0f, 0f)) == null && !scroll.tracking)
        begin(); check(move(pair(y = 70f).map { if (it.id == 9) it.copy(id = 10) else it }) == null && !scroll.tracking)
        begin(); check(scroll.move(pair(y = 70f), 8, 200, 100) == null && !scroll.tracking)
        begin(); check(scroll.move(pair(y = 70f), 7, 400, 100) == null && !scroll.tracking)
        begin(); scroll.cancel(); check(move(pair(y = 70f)) == null && !scroll.tracking && !scroll.scrolling)
        check(!scroll.begin(listOf(TwoFingerScrollGesture.Pointer(3, 0f, 0f), TwoFingerScrollGesture.Pointer(3, 10f, 10f)), 7, 200, 100))
        begin()
        val a = move(pair(y = 60f))!!; val b = move(pair(y = 70f))!!; val c = move(pair(y = 80f))!!
        check(combineScrollDelta(combineScrollDelta(a, b), c).let { close(it.deltaY, .3f) && close(it.y, .8f) })
        check(combineScrollDelta(a, a.copy(deltaY = -.1f)).deltaY == 0f)
        check(combineScrollDelta(a, b.copy(epoch = 8)).let { it.epoch == 8L && close(it.deltaY, .1f) })
    }
    private fun fails(action: () -> Unit) {
        try { action() } catch (_: IOException) { return }
        error("Expected malformed stream rejection")
    }
}
