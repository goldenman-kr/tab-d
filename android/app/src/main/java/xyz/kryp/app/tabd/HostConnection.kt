package xyz.kryp.app.tabd

import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

class HostConnection(private val pairingFile: File, private val listener: Listener, private val deviceName: () -> String) {
    interface Listener {
        fun control(value: JSONObject, generation: Long)
        fun frame(value: Wire.Frame, generation: Long)
        fun connectionError(message: String, generation: Long)
    }
    @Volatile private var socket: SSLSocket? = null
    @Volatile private var output: DataOutputStream? = null
    private val stateLock = Any()
    private var connecting = false // Guarded by stateLock, together with generation and transport publication.
    @Volatile private var generation = 0L
    private val writer = java.util.concurrent.ThreadPoolExecutor(1, 1, 0L, java.util.concurrent.TimeUnit.MILLISECONDS,
        java.util.concurrent.ArrayBlockingQueue<Runnable>(32), { task -> Thread(task, "tabd-control").apply { isDaemon = true } })
    @Volatile var connected = false; private set
    @Volatile var route = "USB"; private set
    @Volatile var lastFailure: String? = null; private set

    fun connect(manualHost: String?, visible: Boolean): Boolean {
        val current = synchronized(stateLock) {
            if (connected || connecting) return false
            connecting = true
            ++generation
        }
        Thread({
            var transport: Socket? = null
            var session: SSLSocket? = null
            var pairingToken: String? = null
            try {
                val config = JSONObject(pairingFile.readText())
                val pin = config.getString("pin").replace(":", "").lowercase()
                require(pin.matches(Regex("[a-f0-9]{64}"))) { "페어링 정보가 올바르지 않습니다" }
                val token = config.getString("token")
                pairingToken = token
                require(token.length >= 16) { "페어링 정보가 올바르지 않습니다" }
                val configured = manualHost?.trim()?.takeIf { it.isNotEmpty() }
                    ?: config.optString("host", "127.0.0.1").ifBlank { "127.0.0.1" }
                val local = configured == "127.0.0.1" || configured == "localhost"
                val targetRoute = if (local) "USB" else "무선"
                synchronized(stateLock) { if (current == generation) route = targetRoute }
                val port = config.optInt(if (local) "usbPort" else "lanPort", if (local) 49832 else 49833)
                require(port in 1024..65535) { "연결 포트가 올바르지 않습니다" }
                // The private ADB-provisioned leaf certificate is the trust anchor, including for changing LAN IPs.
                // Rejects absent/expired certificates and compares all 32 pin bytes in constant time.
                @android.annotation.SuppressLint("CustomX509TrustManager")
                val trust = object : X509TrustManager {
                    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
                    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = throw java.security.cert.CertificateException("Client certificate is not supported")
                    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
                        val leaf = chain?.firstOrNull() ?: throw java.security.cert.CertificateException("No server certificate")
                        leaf.checkValidity()
                        val actual = MessageDigest.getInstance("SHA-256").digest(leaf.encoded)
                        val expected = ByteArray(32) { pin.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
                        if (!MessageDigest.isEqual(actual, expected)) throw java.security.cert.CertificateException("Paired certificate differs")
                    }
                }
                val context = SSLContext.getInstance("TLS")
                context.init(null, arrayOf<TrustManager>(trust), SecureRandom())
                transport = Socket()
                transport.connect(InetSocketAddress(configured, port), 4000)
                val ssl = context.socketFactory.createSocket(transport, configured, port, true) as SSLSocket
                session = ssl
                ssl.enabledProtocols = ssl.supportedProtocols.filter { it == "TLSv1.3" || it == "TLSv1.2" }.toTypedArray()
                ssl.soTimeout = 8000
                ssl.tcpNoDelay = true
                ssl.startHandshake()
                val sink = DataOutputStream(ssl.outputStream)
                // Keep the first packet private until fully written; heartbeat cannot interleave with hello.
                Wire.write(sink, 1, JSONObject().put("type", "hello").put("version", 1).put("token", token).put("visible", visible).put("device", deviceName()).toString().toByteArray(Charsets.UTF_8))
                val published = synchronized(stateLock) {
                    if (current != generation) false else {
                        socket = ssl
                        output = sink
                        lastFailure = null
                        route = targetRoute
                        connected = true
                        true
                    }
                }
                if (!published) return@Thread
                val input = DataInputStream(ssl.inputStream)
                while (current == generation) {
                    val packet = Wire.read(input)
                    when (packet.type) {
                        1, 2 -> listener.control(JSONObject(String(packet.body, Charsets.UTF_8)), current)
                        3 -> listener.frame(Wire.frame(packet.body), current)
                        else -> throw java.io.IOException("Unknown packet type")
                    }
                }
            } catch (error: Exception) {
                val failure = diagnosticFailure(error, pairingToken)
                val report = synchronized(stateLock) {
                    if (current != generation) false else { lastFailure = failure; true }
                }
                if (report) {
                    listener.connectionError(when (error) {
                    is java.io.FileNotFoundException -> "최초 기기 연결 설정이 필요합니다"
                    is javax.net.ssl.SSLException -> "Mac의 기기 인증을 확인해주세요"
                    is java.net.SocketTimeoutException -> "Mac 응답이 없습니다. 연결을 확인해주세요"
                    else -> "Mac에 연결하지 못했습니다. USB 또는 같은 네트워크를 확인해주세요"
                    }, current)
                }
            } finally {
                synchronized(stateLock) {
                    if (current == generation) {
                        connected = false
                        output = null
                        socket = null
                        connecting = false
                    }
                }
                // A stale generation owns only its local resources, never a newer published socket.
                runCatching { session?.close() }
                runCatching { transport?.close() }
            }
        }, "tabd-connection").apply { isDaemon = true }.start()
        return true
    }

    private fun diagnosticFailure(error: Exception, token: String?): String {
        val causes = generateSequence<Throwable>(error) { it.cause }.take(5).toList()
        val names = causes.joinToString(" > ") { it.javaClass.simpleName }
        val root = causes.last()
        val safeMessage = if (root is javax.net.ssl.SSLException || root is java.security.cert.CertificateException ||
            root is java.net.SocketException || root is java.net.SocketTimeoutException || root is java.io.EOFException)
            root.message.orEmpty() else ""
        return (names + if (safeMessage.isBlank()) "" else ": $safeMessage")
            .let { if (token.isNullOrBlank()) it else it.replace(token, "[redacted]") }
            .replace(Regex("[\\r\\n\\t]"), " ").take(512)
    }

    fun send(value: JSONObject): Boolean {
        val (current, sink, targetSocket) = synchronized(stateLock) {
            val sink = output ?: return false
            Triple(generation, sink, socket)
        }
        return try {
            val bytes = value.toString().toByteArray(Charsets.UTF_8)
            writer.execute {
                if (current == generation) try { Wire.write(sink, 1, bytes) }
                catch (_: Exception) { runCatching { targetSocket?.close() } }
            }
            true
        } catch (_: Exception) { runCatching { targetSocket?.close() }; false }
    }

    fun isCurrent(value: Long) = value == generation

    fun close() {
        val detached = synchronized(stateLock) {
            generation++
            connected = false
            connecting = false
            output = null
            socket.also { socket = null }
        }
        runCatching { detached?.close() }
    }
}
