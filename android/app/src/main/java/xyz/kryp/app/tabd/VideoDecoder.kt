package xyz.kryp.app.tabd

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.util.Base64
import android.view.Surface
import org.json.JSONObject
import org.json.JSONArray
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class VideoDecoder(private val listener: Listener) {
    interface Listener {
        fun decoderReady(epoch: Long, width: Int, height: Int, hardware: Boolean)
        fun decoderDiagnostics(epoch: Long, details: JSONObject)
        fun decoderOutput(epoch: Long)
        fun rendered(epoch: Long, sequence: Long)
        fun requestKeyframe(epoch: Long)
        fun decoderError(message: String)
    }
    private sealed class Work {
        data class Configure(val config: JSONObject, val surface: Surface) : Work()
        data class Frame(val value: Wire.Frame) : Work()
        data object Stop : Work()
    }
    private val queue = ArrayBlockingQueue<Work>(6)
    @Volatile private var recovering = true
    @Volatile private var needsReset = false
    @Volatile private var epoch = -1L
    @Volatile private var running = true
    @Volatile private var codec: MediaCodec? = null
    private val renderedHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var details = JSONObject()
    private var submittedFrames = 0L
    private var inputQueued = 0L
    private var lastInput: FrameMetadata? = null
    private val receivedFrames = AtomicLong()
    private val epochDrops = AtomicLong()
    private val keyframeWaitDrops = AtomicLong()
    private val overflowDrops = AtomicLong()
    private var inputUnavailable = 0L
    private data class FrameMetadata(val epoch: Long, val sequence: Long, val pts: Long, val keyframe: Boolean)
    @Volatile private var lastReceived: FrameMetadata? = null
    private val telemetryDirty = AtomicBoolean()
    private var lastTelemetryAt = 0L
    private var config: JSONObject? = null
    private var surface: Surface? = null
    private data class ConfigurationKey(val epoch: Long, val width: Int, val height: Int, val sps: String, val pps: String)
    @Volatile private var requestedConfiguration: ConfigurationKey? = null
    @Volatile private var requestedSurface: Surface? = null
    private val sequences = ConcurrentHashMap<Long, Long>()
    private val pendingOutput = HashSet<Long>()
    private val thread = Thread({ loop() }, "tabd-decoder").apply { isDaemon = true; start() }

    @Synchronized fun configure(value: JSONObject, target: Surface) {
        val key = ConfigurationKey(value.getLong("epoch"), value.getInt("width"), value.getInt("height"), value.getString("csd0"), value.getString("csd1"))
        if (requestedConfiguration == key && requestedSurface === target) return
        requestedConfiguration = key
        requestedSurface = target
        queue.clear()
        recovering = true
        needsReset = false
        queue.offer(Work.Configure(value, target))
    }

    fun frame(value: Wire.Frame) {
        receivedFrames.incrementAndGet()
        lastReceived = FrameMetadata(value.epoch, value.sequence, value.pts, value.keyframe)
        telemetryDirty.set(true)
        if (value.epoch != epoch) { epochDrops.incrementAndGet(); telemetryDirty.set(true); return }
        if (recovering && !value.keyframe) { keyframeWaitDrops.incrementAndGet(); telemetryDirty.set(true); return }
        if (!queue.offer(Work.Frame(value))) {
            overflowDrops.incrementAndGet()
            recovering = true
            needsReset = true
            queue.removeIf { if (it is Work.Frame) { overflowDrops.incrementAndGet(); true } else false }
            telemetryDirty.set(true)
            listener.requestKeyframe(value.epoch)
        }
    }

    @Synchronized fun stop() {
        requestedConfiguration = null; requestedSurface = null
        queue.clear(); queue.offer(Work.Stop)
    }
    fun close() { running = false; thread.interrupt() }

    private fun release() {
        runCatching { codec?.stop() }
        runCatching { codec?.release() }
        codec = null
        sequences.clear()
        pendingOutput.clear()
        epoch = -1
    }

    private fun create(value: JSONObject, target: Surface, notify: Boolean = true) {
        release()
        require(target.isValid) { "화면 표시 영역을 준비하고 있습니다" }
        val width = value.getInt("width"); val height = value.getInt("height")
        require(width in 16..8192 && height in 16..8192)
        val format = MediaFormat.createVideoFormat("video/avc", width, height)
        format.setByteBuffer("csd-0", ByteBuffer.wrap(Base64.decode(value.getString("csd0"), Base64.DEFAULT)))
        format.setByteBuffer("csd-1", ByteBuffer.wrap(Base64.decode(value.getString("csd1"), Base64.DEFAULT)))
        // This is a realtime display stream. Without these hints the decoder can assume a 1 fps input.
        format.setInteger(MediaFormat.KEY_FRAME_RATE, 60)
        format.setInteger(MediaFormat.KEY_PRIORITY, 0)
        // Standard optional API 30 hint. Acceptance and advertised support are reported separately.
        format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        // ALL_CODECS includes dedicated low-latency components omitted by the regular factory.
        val candidates = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.mapNotNull { info ->
            if (info.isEncoder || !info.supportedTypes.any { it.equals("video/avc", ignoreCase = true) }) return@mapNotNull null
            runCatching {
                val capabilities = info.getCapabilitiesForType("video/avc")
                DecoderCandidate(info.name, info.isHardwareAccelerated,
                    capabilities.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency),
                    capabilities.videoCapabilities?.areSizeAndRateSupported(width, height, 60.0) == true,
                    capabilities.isFeatureRequired(MediaCodecInfo.CodecCapabilities.FEATURE_SecurePlayback),
                    capabilities.isFeatureRequired(MediaCodecInfo.CodecCapabilities.FEATURE_TunneledPlayback))
            }.getOrNull()
        }
        val selectedName = selectLowLatencyDecoder(candidates)
        var decoder = if (selectedName != null) MediaCodec.createByCodecName(selectedName) else MediaCodec.createDecoderByType("video/avc")
        codec = decoder
        val caps = decoder.codecInfo.getCapabilitiesForType("video/avc")
        val advertised = caps.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
        val name = decoder.name
        var accepted = true
        try {
            decoder.configure(format, target, null, 0)
        } catch (error: Exception) {
            if (error !is IllegalArgumentException && error !is MediaCodec.CodecException) throw error
            if (selectedName != null) throw error
            // Some drivers reject an unsupported optional hint. Retry a fresh instance once without it.
            runCatching { decoder.release() }
            decoder = MediaCodec.createByCodecName(name)
            codec = decoder
            format.removeKey(MediaFormat.KEY_LOW_LATENCY)
            decoder.configure(format, target, null, 0)
            accepted = false
        }
        val configuredEpoch = value.getLong("epoch")
        decoder.setOnFrameRenderedListener({ instance, pts, _ ->
            if (codec === instance && epoch == configuredEpoch) {
                sequences.remove(pts)?.let { sequence -> listener.rendered(configuredEpoch, sequence) }
            }
        }, renderedHandler)
        decoder.start()
        config = value; surface = target; epoch = configuredEpoch
        submittedFrames = 0
        inputQueued = 0; lastInput = null; inputUnavailable = 0
        receivedFrames.set(0); epochDrops.set(0); keyframeWaitDrops.set(0); overflowDrops.set(0); lastReceived = null
        details = JSONObject().put("name", decoder.name).put("hardware", decoder.codecInfo.isHardwareAccelerated)
            .put("selection", if (selectedName != null) "allCodecsLowLatencyHardware" else "defaultFactoryFallback")
            .put("avcCandidates", JSONArray(candidates.map { candidate ->
                JSONObject().put("name", candidate.name).put("hardware", candidate.hardware)
                    .put("lowLatency", candidate.lowLatency).put("sizeAndRateSupported", candidate.sizeAndRateSupported)
                    .put("secureRequired", candidate.secureRequired).put("tunneledRequired", candidate.tunneledRequired)
            }))
            .put("lowLatencyAdvertised", advertised).put("lowLatencyRequested", true)
            .put("lowLatencyConfigureAccepted", accepted).put("configuredFrameRate", 60).put("configuredPriority", 0)
            .put("frameCounterSource", "MediaCodec.OnFrameRenderedListener")
        recordFormat(decoder.inputFormat, "input")
        publishDetails()
        recovering = true
        if (notify) listener.decoderReady(epoch, width, height, decoder.codecInfo.isHardwareAccelerated)
    }

    private fun recordFormat(format: MediaFormat, prefix: String) {
        for ((name, key) in listOf("FrameRate" to MediaFormat.KEY_FRAME_RATE, "Priority" to MediaFormat.KEY_PRIORITY,
            "LowLatency" to MediaFormat.KEY_LOW_LATENCY, "OutputReorderDepth" to MediaFormat.KEY_OUTPUT_REORDER_DEPTH,
            "Width" to MediaFormat.KEY_WIDTH, "Height" to MediaFormat.KEY_HEIGHT)) {
            if (format.containsKey(key)) runCatching { details.put(prefix + name, format.getNumber(key)) }
        }
    }
    private fun publishDetails() {
        telemetryDirty.set(false)
        lastTelemetryAt = android.os.SystemClock.uptimeMillis()
        details.put("currentEpoch", epoch).put("submittedToSurface", submittedFrames).put("inputQueued", inputQueued)
            .put("receivedFrames", receivedFrames.get()).put("droppedWrongEpoch", epochDrops.get())
            .put("droppedAwaitingKeyframe", keyframeWaitDrops.get()).put("droppedQueueOverflow", overflowDrops.get())
            .put("inputUnavailable", inputUnavailable).put("pendingOutput", pendingOutput.size)
            .put("pendingOutputPts", JSONArray(pendingOutput.sorted().take(33)))
            .put("queueDepth", queue.size).put("recovering", recovering).put("needsReset", needsReset)
        lastInput?.let { details.put("lastInputSequence", it.sequence).put("lastInputKeyframe", it.keyframe).put("lastInputPts", it.pts) }
        lastReceived?.let { details.put("lastReceivedEpoch", it.epoch).put("lastReceivedSequence", it.sequence)
            .put("lastReceivedKeyframe", it.keyframe).put("lastReceivedPts", it.pts) }
        listener.decoderDiagnostics(epoch, JSONObject(details.toString()))
    }

    private fun loop() {
        try {
            while (running) {
                val work = queue.poll(10, java.util.concurrent.TimeUnit.MILLISECONDS)
                try {
                    when (work) {
                        is Work.Configure -> create(work.config, work.surface)
                        is Work.Frame -> {
                            val frame = work.value
                            if (frame.epoch == epoch) {
                                if (recovering) {
                                    if (!frame.keyframe) { keyframeWaitDrops.incrementAndGet(); telemetryDirty.set(true); continue }
                                    // Recreate rather than flush: codec configuration is submitted again before the IDR.
                                    if (needsReset) create(config!!, surface!!, false)
                                    needsReset = false
                                    recovering = false
                                }
                                val decoder = codec ?: continue
                                val input = decoder.dequeueInputBuffer(10000)
                                if (input < 0) {
                                    inputUnavailable++; telemetryDirty.set(true)
                                    recovering = true; needsReset = true; listener.requestKeyframe(frame.epoch); continue
                                }
                                val bytes = decoder.getInputBuffer(input) ?: throw IllegalStateException("No codec input")
                                if (bytes.capacity() < frame.bytes.size) throw IllegalStateException("Video frame exceeds decoder capacity")
                                bytes.clear(); bytes.put(frame.bytes)
                                sequences[frame.pts] = frame.sequence
                                pendingOutput.add(frame.pts)
                                decoder.queueInputBuffer(input, 0, frame.bytes.size, frame.pts, 0)
                                inputQueued++
                                lastInput = FrameMetadata(frame.epoch, frame.sequence, frame.pts, frame.keyframe)
                                telemetryDirty.set(true)
                            } else { epochDrops.incrementAndGet(); telemetryDirty.set(true) }
                        }
                        Work.Stop -> { release(); config = null; surface = null; recovering = true }
                        null -> Unit
                    }
                    val decoder = codec ?: continue
                    val info = MediaCodec.BufferInfo()
                    repeat(8) {
                        val output = decoder.dequeueOutputBuffer(info, 0)
                        if (output >= 0) {
                            pendingOutput.remove(info.presentationTimeUs)
                            telemetryDirty.set(true)
                            decoder.releaseOutputBuffer(output, true)
                            submittedFrames++
                            if (submittedFrames == 1L) listener.decoderOutput(epoch)
                            if (submittedFrames == 1L || submittedFrames % 30L == 0L) publishDetails()
                        } else if (output == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                            recordFormat(decoder.outputFormat, "output")
                            publishDetails()
                        }
                    }
                    // Render callbacks may be batched: delayed notifications must not reset a healthy codec.
                    while (sequences.size > 128) sequences.keys.minOrNull()?.let { sequences.remove(it) }
                    if (pendingOutput.size > 32) { pendingOutput.clear(); recovering = true; needsReset = true; listener.requestKeyframe(epoch) }
                    if (telemetryDirty.get() && android.os.SystemClock.uptimeMillis() - lastTelemetryAt >= 500) publishDetails()
                } catch (_: Exception) {
                    requestedConfiguration = null; requestedSurface = null
                    release(); recovering = true
                    listener.decoderError("화면을 표시하지 못했습니다. 다시 연결해주세요")
                }
            }
        } catch (_: InterruptedException) {
        } finally { release() }
    }
}
