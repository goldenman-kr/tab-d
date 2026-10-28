package xyz.kryp.app.tabd

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.widget.Toast
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

internal object AndroidUpdatePolicy {
    fun version(value: String): List<Long>? =
        if (value.matches(Regex("[0-9]+\\.[0-9]+\\.[0-9]+"))) value.split('.').map { it.toLongOrNull() ?: return null } else null
    fun newer(candidate: String, installed: String): Boolean {
        val a = version(candidate) ?: return false
        val b = version(installed) ?: return false
        for (index in a.indices) if (a[index] != b[index]) return a[index] > b[index]
        return false
    }
    fun assetVersion(name: String): String? = Regex("Mr-Tab-D-([0-9]+\\.[0-9]+\\.[0-9]+)-Android\\.apk")
        .matchEntire(name)?.groupValues?.get(1)?.takeIf { version(it) != null }
    fun releaseAsset(url: String): Boolean = runCatching {
        val uri = URI(url)
        uri.scheme == "https" && uri.host == "github.com" && uri.port == -1 && uri.userInfo == null &&
            uri.rawQuery == null && uri.rawFragment == null &&
            uri.path.startsWith("/goldenman-kr/tab-d/releases/download/") && !uri.path.contains("/../")
    }.getOrDefault(false)
    fun sameSigners(current: Set<String>, incoming: Set<String>) = current.isNotEmpty() && current == incoming
    fun checksum(text: String, name: String): String? {
        val matches = text.lineSequence().mapNotNull {
            Regex("^([a-fA-F0-9]{64})  (.+)$").matchEntire(it.trimEnd())
        }.filter { it.groupValues[2] == name }.toList()
        return matches.singleOrNull()?.groupValues?.get(1)?.lowercase()
    }
}

/** Downloads only after consent; Android always owns the final installation approval. */
class UpdateManager(private val activity: Activity, private val canPrompt: () -> Boolean) {
    companion object { private val startupChecked = AtomicBoolean(false) }
    private data class Update(val version: String, val name: String, val url: String, val checksumURL: String, val size: Long)
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor { task -> Thread(task, "tabd-updates").apply { isDaemon = true } }
    @Volatile private var closed = false
    @Volatile private var connection: HttpURLConnection? = null
    private var busy = false
    private var pending: Update? = null
    private var dialog: AlertDialog? = null
    private var pendingAPK: File? = null
    private var awaitingPermission = false
    private var installationOffered = false

    fun check(manual: Boolean = false) {
        if (closed || busy) return
        if (!manual && !startupChecked.compareAndSet(false, true)) return
        if (manual && pendingAPK != null) { offerInstall(); return }
        busy = true
        executor.execute {
            try {
                val installed = activity.packageManager.getPackageInfo(activity.packageName, 0).versionName ?: "0.0.0"
                val release = JSONObject(String(fetch("https://api.github.com/repos/goldenman-kr/tab-d/releases/latest", 2_000_000), Charsets.UTF_8))
                require(!release.optBoolean("draft") && !release.optBoolean("prerelease"))
                val assets = release.getJSONArray("assets")
                var candidate: Update? = null
                val sums = (0 until assets.length()).map { assets.getJSONObject(it) }.singleOrNull { it.optString("name") == "SHA256SUMS.txt" }
                require(sums != null) { "Missing release checksums" }
                run {
                    val sumsURL = sums.getString("browser_download_url")
                    require(AndroidUpdatePolicy.releaseAsset(sumsURL))
                    for (index in 0 until assets.length()) {
                        val asset = assets.getJSONObject(index)
                        val name = asset.optString("name")
                        val version = AndroidUpdatePolicy.assetVersion(name) ?: continue
                        if (!AndroidUpdatePolicy.newer(version, installed)) continue
                        val url = asset.getString("browser_download_url")
                        val size = asset.getLong("size")
                        require(AndroidUpdatePolicy.releaseAsset(url) && size in 1..268_435_456L)
                        if (candidate == null || AndroidUpdatePolicy.newer(version, candidate.version))
                            candidate = Update(version, name, url, sumsURL, size)
                    }
                }
                main.post {
                    if (closed) return@post
                    busy = false
                    pending = candidate
                    if (candidate != null) onResume()
                    else if (manual) message("현재 사용할 수 있는 최신 버전입니다")
                }
            } catch (_: Exception) {
                main.post { if (!closed) { busy = false; if (manual) message("업데이트를 확인하지 못했습니다. 인터넷 연결을 확인하고 다시 시도해주세요") } }
            }
        }
    }

    fun onResume() {
        if (closed || activity.isFinishing || activity.isDestroyed || !canPrompt()) return
        if (awaitingPermission) {
            awaitingPermission = false
            if (activity.packageManager.canRequestPackageInstalls()) launchInstaller()
            else offerInstall()
            return
        }
        if (pendingAPK != null && !installationOffered) { offerInstall(); return }
        val update = pending ?: return
        if (dialog?.isShowing == true) return
        pending = null // Later means no automatic re-prompt during this process.
        dialog = AlertDialog.Builder(activity).setTitle("Mr. Tab-D 업데이트")
            .setMessage("새 Android 버전 ${update.version}이 있습니다. 지금 다운로드하고 설치할까요? 설치 승인은 Android에서 진행합니다.")
            .setNegativeButton("나중에", null)
            .setPositiveButton("지금 업데이트") { _, _ -> download(update) }
            .create().also { it.show() }
    }

    private fun download(update: Update) {
        if (busy || closed) return
        busy = true
        dialog = AlertDialog.Builder(activity).setTitle("업데이트 다운로드 중")
            .setMessage("설치 파일을 다운로드하고 확인하고 있습니다…")
            .setCancelable(false).create().also { it.show() }
        executor.execute {
            val directory = File(activity.cacheDir, "updates").apply { mkdirs() }
            val part = File(directory, "candidate.apk")
            try {
                val expected = AndroidUpdatePolicy.checksum(String(fetch(update.checksumURL, 1_000_000), Charsets.UTF_8), update.name)
                    ?: error("No checksum")
                val digest = MessageDigest.getInstance("SHA-256")
                part.outputStream().use { output ->
                    transfer(update.url, update.size, output) { bytes, count -> digest.update(bytes, 0, count) }
                }
                require(part.length() == update.size)
                val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
                require(actual == expected) { "Checksum mismatch" }
                validateAPK(part, update.version)
                val destination = File(directory, "update.apk")
                require(part.renameTo(destination))
                main.post {
                    if (closed) return@post
                    busy = false; dialog?.dismiss(); pendingAPK = destination; installationOffered = false
                    if (canPrompt()) offerInstall()
                }
            } catch (_: Exception) {
                part.delete()
                main.post { if (!closed) { busy = false; dialog?.dismiss(); message("업데이트 다운로드 또는 파일 검증에 실패했습니다. 설정에서 다시 확인해주세요") } }
            }
        }
    }

    private fun offerInstall() {
        if (closed || pendingAPK == null || !canPrompt()) return
        installationOffered = true
        val allowed = activity.packageManager.canRequestPackageInstalls()
        dialog = AlertDialog.Builder(activity).setTitle("업데이트 설치")
            .setMessage(if (allowed) "다운로드와 검증이 완료되었습니다. Android 설치 화면에서 업데이트를 승인해주세요."
                else "다운로드와 검증이 완료되었습니다. 다음 화면에서 Mr. Tab-D의 ‘이 출처 허용’을 켜고 돌아오면 설치를 진행합니다.")
            .setNegativeButton("나중에", null)
            .setPositiveButton(if (allowed) "설치하기" else "설치 허용 설정") { _, _ ->
                if (allowed) launchInstaller() else try {
                    awaitingPermission = true
                    activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
                } catch (_: Exception) { awaitingPermission = false; message("Android 설정에서 Mr. Tab-D의 알 수 없는 앱 설치를 허용해주세요") }
            }.create().also { it.show() }
    }

    private fun launchInstaller() {
        if (pendingAPK?.isFile != true || closed) return
        try {
            val uri = Uri.parse("content://${activity.packageName}.updates/update.apk")
            activity.startActivity(Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                clipData = ClipData.newRawUri("Mr. Tab-D update", uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            })
        } catch (_: Exception) { message("설치 화면을 열지 못했습니다. 설정의 업데이트 확인에서 다시 설치해주세요") }
    }

    @Suppress("DEPRECATION")
    private fun validateAPK(file: File, version: String) {
        val pm = activity.packageManager
        val current = pm.getPackageInfo(activity.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        val archive = pm.getPackageArchiveInfo(file.path, PackageManager.GET_SIGNING_CERTIFICATES) ?: error("Invalid APK")
        require(archive.packageName == activity.packageName && archive.versionName == version && archive.longVersionCode > current.longVersionCode)
        val installed = current.signingInfo?.apkContentsSigners?.map { it.toCharsString() }?.toSet() ?: error("Missing installed signer")
        val incoming = archive.signingInfo?.apkContentsSigners?.map { it.toCharsString() }?.toSet() ?: error("Missing APK signer")
        require(AndroidUpdatePolicy.sameSigners(installed, incoming)) { "Signer differs" }
    }

    private fun fetch(url: String, limit: Long): ByteArray = transfer(url, limit) { _, _ -> }
    private fun transfer(url: String, limit: Long, destination: java.io.OutputStream? = null, consume: (ByteArray, Int) -> Unit): ByteArray {
        var address = url
        val started = android.os.SystemClock.elapsedRealtime()
        repeat(6) {
            check(!closed && !Thread.currentThread().isInterrupted)
            val uri = URI(address)
            require(uri.scheme == "https" && uri.userInfo == null && (uri.port == -1 || uri.port == 443) &&
                uri.host in setOf("api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"))
            val request = uri.toURL().openConnection() as HttpURLConnection
            connection = request
            try {
                request.instanceFollowRedirects = false
                request.connectTimeout = 15000; request.readTimeout = 20000
                request.setRequestProperty("User-Agent", "Mr-Tab-D-Android-Updater")
                request.setRequestProperty("Accept", if (uri.host == "api.github.com") "application/vnd.github+json" else "application/octet-stream")
                val status = request.responseCode
                if (status in listOf(301, 302, 303, 307, 308)) {
                    address = uri.resolve(request.getHeaderField("Location") ?: error("Missing redirect")).toString()
                    return@repeat
                }
                require(status == 200 && request.contentLengthLong <= limit)
                val memory = if (destination == null) java.io.ByteArrayOutputStream() else null
                val output = destination ?: memory!!
                var length = 0L
                request.inputStream.use { input ->
                    val buffer = ByteArray(32768)
                    while (true) {
                        check(!closed && !Thread.currentThread().isInterrupted)
                        val count = input.read(buffer)
                        if (count < 0) break
                        require(length + count <= limit && android.os.SystemClock.elapsedRealtime() - started <= 120_000)
                        length += count
                        consume(buffer, count); output.write(buffer, 0, count)
                    }
                }
                return memory?.toByteArray() ?: ByteArray(0)
            } finally { request.disconnect(); connection = null }
        }
        error("Too many redirects")
    }
    private fun message(text: String) { if (!closed) Toast.makeText(activity, text, Toast.LENGTH_LONG).show() }
    fun close() {
        closed = true
        connection?.disconnect()
        executor.shutdownNow()
        main.removeCallbacksAndMessages(null)
        dialog?.dismiss(); dialog = null
    }
}
