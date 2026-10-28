package xyz.kryp.app.tabd

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper

/** Finds addresses only; HostConnection must authenticate every discovered endpoint. */
@Suppress("DEPRECATION") // Serialized legacy resolution also supports Android 11–13.
class LanDiscovery(context: Context) {
    data class Endpoint(val name: String, val host: String, val port: Int)
    private val manager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val main = Handler(Looper.getMainLooper())
    private var generation = 0L
    private var listener: NsdManager.DiscoveryListener? = null
    private var timeout: Runnable? = null

    fun stop() {
        generation++
        timeout?.let(main::removeCallbacks)
        timeout = null
        val previous = listener
        listener = null
        if (previous != null) runCatching { manager.stopServiceDiscovery(previous) }
    }

    fun search(onComplete: (List<Endpoint>, String?) -> Unit) {
        stop()
        val current = generation
        val results = linkedMapOf<String, Endpoint>()
        val pending = java.util.ArrayDeque<NsdServiceInfo>()
        val seen = mutableSetOf<String>()
        var resolving = false
        fun finish(error: String?) {
            if (generation != current) return
            val found = results.values.toList()
            stop()
            onComplete(found, error)
        }
        fun resolveNext() {
            if (generation != current || resolving || pending.isEmpty()) return
            val service = pending.removeFirst()
            resolving = true
            val callback = object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, code: Int) {
                    main.post {
                        if (generation == current) { resolving = false; resolveNext() }
                    }
                }
                override fun onServiceResolved(info: NsdServiceInfo) {
                    main.post {
                        if (generation != current) return@post
                        val host = info.host
                        if (host != null && !host.isLoopbackAddress && !host.isAnyLocalAddress &&
                            !host.isMulticastAddress && info.port in 1024..65535) {
                            host.hostAddress?.let { address ->
                                results["$address:${info.port}"] = Endpoint(info.serviceName, address, info.port)
                            }
                        }
                        resolving = false
                        resolveNext()
                    }
                }
            }
            try { manager.resolveService(service, callback) }
            catch (_: RuntimeException) { resolving = false; resolveNext() }
        }
        val discovery = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) = Unit
            override fun onDiscoveryStopped(type: String) = Unit
            override fun onStopDiscoveryFailed(type: String, code: Int) = Unit
            override fun onStartDiscoveryFailed(type: String, code: Int) {
                main.post { finish("무선 검색을 시작하지 못했습니다. Wi-Fi와 네트워크 권한을 확인해주세요") }
            }
            override fun onServiceFound(info: NsdServiceInfo) {
                main.post {
                    if (generation != current || info.serviceType.trimEnd('.') != "_tabd._tcp" || seen.size >= 16) return@post
                    if (seen.add(info.serviceName)) { pending.addLast(info); resolveNext() }
                }
            }
            override fun onServiceLost(info: NsdServiceInfo) {
                main.post {
                    if (generation != current) return@post
                    results.entries.removeAll { it.value.name == info.serviceName }
                }
            }
        }
        listener = discovery
        timeout = Runnable { finish(null) }.also { main.postDelayed(it, 4000) }
        try { manager.discoverServices("_tabd._tcp.", NsdManager.PROTOCOL_DNS_SD, discovery) }
        catch (_: RuntimeException) { finish("무선 검색을 시작하지 못했습니다. Wi-Fi와 네트워크 권한을 확인해주세요") }
    }
}
