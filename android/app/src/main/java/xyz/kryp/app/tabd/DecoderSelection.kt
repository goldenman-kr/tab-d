package xyz.kryp.app.tabd

internal data class DecoderCandidate(
    val name: String,
    val hardware: Boolean,
    val lowLatency: Boolean,
    val sizeAndRateSupported: Boolean,
    val secureRequired: Boolean = false,
    val tunneledRequired: Boolean = false,
)

internal fun selectLowLatencyDecoder(candidates: List<DecoderCandidate>): String? = candidates.firstOrNull {
    it.hardware && it.lowLatency && it.sizeAndRateSupported && !it.secureRequired && !it.tunneledRequired
}?.name
