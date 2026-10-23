package xyz.kryp.app.tabd

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.view.ViewConfiguration
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.accessibility.AccessibilityManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONObject
import java.io.File

class MainActivity : Activity(), HostConnection.Listener, VideoDecoder.Listener {
    private val main = Handler(Looper.getMainLooper())
    private val backgroundColor = Color.rgb(29, 34, 40)
    private val sage = Color.rgb(175, 208, 175)
    private val muted = Color.rgb(165, 177, 187)
    private lateinit var root: FrameLayout
    private lateinit var surface: SurfaceView
    private lateinit var ready: LinearLayout
    private lateinit var bar: LinearLayout
    private lateinit var hostNameLabel: TextView
    private lateinit var stateLabel: TextView
    private lateinit var barState: TextView
    private lateinit var primary: Button
    private lateinit var client: HostConnection
    private lateinit var decoder: VideoDecoder
    private val preferences by lazy { getSharedPreferences("tabd", MODE_PRIVATE) }
    @Volatile private var foreground = false
    @Volatile private var surfaceReady = false
    @Volatile private var authenticated = false
    private var retained = false
    private var pendingStart = false
    private var pendingRecoveryStart = false
    private var pendingResume = false
    @Volatile private var active = false
    private var startRequested = false
    private var resumeInFlight = false
    private val recovery = HostRecoveryGate()
    private val recoveryTimeout = Runnable {
        if (foreground && recovery.expire(android.os.SystemClock.uptimeMillis())) {
            pendingStart = false; pendingResume = false
            pendingRecoveryStart = false
            startRequested = false; resumeInFlight = false
            active = false
            invalidateVideo(); showReady()
            showError("Mac의 화면 재개 응답을 받지 못했습니다. Mac을 깨우고 화면 연결을 다시 눌러주세요")
            diagnostics()
        }
    }
    private var disconnectPending = false
    private var fullscreen = false
    private var systemBarsVisible: Boolean? = null
    private var leavingForHome = false
    private var homeTaskMoved: Boolean? = null
    @Volatile private var pauseRequested = false
    private var pendingHome = false
    private var latestConfig: JSONObject? = null
    private var state = "ready"
    private var frames = 0L
    private var framesCurrentEpoch = 0L
    private val transportFramesReceived = java.util.concurrent.atomic.AtomicLong()
    private val transportFramesRejected = java.util.concurrent.atomic.AtomicLong()
    private data class FrameIngress(val epoch: Long, val sequence: Long, val pts: Long, val keyframe: Boolean, val accepted: Boolean)
    @Volatile private var lastTransportFrame: FrameIngress? = null
    @Volatile private var epoch = -1L
    private var hostEpoch = -1L
    private var suppressionEpoch = -1L
    private var sequence = 0L
    private var displayID: Long? = null
    private var lastError: String? = null
    private var decodedWidth = 0
    private var decodedHeight = 0
    private var hardwareDecoder = false
    private var decoderDetails = JSONObject()
    private var presentedEpoch = -1L
    private val tapGesture by lazy { SurfaceTapGesture(ViewConfiguration.get(this).scaledTouchSlop.toFloat(), minOf(300L, ViewConfiguration.getLongPressTimeout().toLong())) }
    private val inputGesture by lazy { SurfaceInputGesture(ViewConfiguration.get(this).scaledTouchSlop.toFloat()) }
    private val doubleTaps by lazy { DoubleTapClassifier(ViewConfiguration.getDoubleTapTimeout().toLong(), ViewConfiguration.get(this).scaledDoubleTapSlop.toFloat()) }
    private val scrollGesture by lazy { TwoFingerScrollGesture(ViewConfiguration.get(this).scaledTouchSlop.toFloat()) }
    private var singleInputSuppressed = false
    private data class ScrollRequest(val id: String, val epoch: Long, val x: Float, val y: Float, val deltaY: Float, val sentAt: Long)
    private val pendingScrolls = LinkedHashMap<String, ScrollRequest>()
    private var pendingScroll: TwoFingerScrollGesture.Delta? = null
    private var lastScrollSentAt = 0L
    private var lastScroll: JSONObject? = null
    private var scrollCount = 0L
    private val flushScroll = Runnable { flushScrollDelta() }
    private val scrollTimeout = object : Runnable {
        override fun run() {
            val expired = pendingScrolls.values.filter { android.os.SystemClock.uptimeMillis() - it.sentAt >= 3000 }
            for (request in expired) {
                pendingScrolls.remove(request.id)
                lastScroll = scrollDiagnostic(request, "timeout", "Mac의 스크롤 응답을 확인하지 못했습니다")
            }
            if (expired.any { it.epoch == epoch } && fullscreen && foreground) showClickNotice("Mac의 스크롤 응답을 확인하지 못했습니다")
            if (expired.isNotEmpty()) diagnostics()
            if (pendingScrolls.isNotEmpty()) main.postDelayed(this, 500)
        }
    }
    private var lastSurfaceUp: DoubleTapClassifier.Sample? = null
    private var tapPointer = -1
    private var tapClosesBar = false
    private var pendingSurfaceClick: SurfaceInputGesture.Action.Click? = null
    private data class ClickRequest(val id: String, val epoch: Long, val x: Float, val y: Float, val button: String, val clickCount: Int, val sentAt: Long)
    private val pendingClicks = LinkedHashMap<String, ClickRequest>()
    private var lastClick: JSONObject? = null
    private data class PointerSession(val id: String, val epoch: Long, var point: SurfaceInputGesture.Point,
        var sequence: Long = -1, var lastSentAt: Long = 0, var pendingMove: SurfaceInputGesture.Point? = null,
        val waiting: MutableMap<String, Long> = LinkedHashMap())
    private var drag: PointerSession? = null
    private val pendingPointers = LinkedHashMap<String, PointerSession>()
    private var lastPointer: JSONObject? = null
    private val longPress = Runnable {
        if (tapPointer >= 0 && !tapClosesBar && canSendInput(epoch))
            dispatchInput(inputGesture.hold(android.os.SystemClock.uptimeMillis(), epoch, surface.width, surface.height))
        else cancelSurfaceInput("holdUnavailable")
    }
    private val flushPointerMove = Runnable { drag?.let { flushDragMove(it) } }
    private val pointerKeepAlive = object : Runnable {
        override fun run() {
            val session = drag ?: return
            if (!canSendInput(session.epoch)) { cancelSurfaceInput("unavailable"); return }
            val elapsed = android.os.SystemClock.uptimeMillis() - session.lastSentAt
            if (elapsed >= 500) {
                session.pendingMove = session.point
                if (!flushDragMove(session)) return
                diagnostics()
            }
            main.postDelayed(this, maxOf(1L, 500 - (android.os.SystemClock.uptimeMillis() - session.lastSentAt)))
        }
    }
    private val pointerTimeout = object : Runnable {
        override fun run() {
            val now = android.os.SystemClock.uptimeMillis()
            val expired = pendingPointers.values.filter { session -> session.waiting.values.any { now - it >= 3000 } }
            for (session in expired) {
                if (drag === session) cancelSurfaceInput("timeout")
                pendingPointers.remove(session.id)
                lastPointer = pointerDiagnostic(session, "timeout", "Mac의 드래그 응답을 확인하지 못했습니다")
                if (session.epoch == epoch && fullscreen && foreground) showClickNotice("Mac의 드래그 응답을 확인하지 못했습니다")
            }
            if (expired.isNotEmpty()) diagnostics()
            if (pendingPointers.isNotEmpty()) main.postDelayed(this, 500)
        }
    }
    private val clickTimeout = object : Runnable {
        override fun run() {
            val expired = pendingClicks.values.filter { android.os.SystemClock.uptimeMillis() - it.sentAt >= 3000 }
            for (request in expired) {
                pendingClicks.remove(request.id)
                lastClick = clickDiagnostic(request, "timeout", "Mac의 클릭 응답을 확인하지 못했습니다")
            }
            if (expired.isNotEmpty()) doubleTaps.reset()
            if (expired.any { it.epoch == epoch } && fullscreen) showClickNotice("Mac의 클릭 응답을 확인하지 못했습니다")
            if (expired.isNotEmpty()) diagnostics()
            if (pendingClicks.isNotEmpty()) main.postDelayed(this, 500)
        }
    }
    @Volatile private var suppressResume = false
    private val hideBar = Runnable {
        val manager = getSystemService(ACCESSIBILITY_SERVICE) as AccessibilityManager
        if (bar.visibility == View.VISIBLE && !manager.isTouchExplorationEnabled && !bar.hasFocus()) {
            bar.visibility = View.GONE
            hideSystemBars()
            diagnostics()
        }
    }
    private val homeTimeout = Runnable {
        if (pendingHome) {
            pendingHome = false
            if (foreground && state != "paused") pauseRequested = false
            showError("Mac의 화면 유지 확인을 받지 못했습니다. 연결을 확인하고 다시 시도해주세요")
        }
    }
    private val reconnect = object : Runnable {
        override fun run() {
            if (foreground && !client.connected) connect()
            if (foreground) main.postDelayed(this, 2500)
        }
    }
    private val heartbeat = object : Runnable {
        override fun run() {
            if (client.connected) send("ping")
            main.postDelayed(this, 2500)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        retained = preferences.getBoolean("retained", false)
        suppressResume = preferences.getBoolean("explicitlyDisconnected", false)
        if (suppressResume) retained = false
        client = HostConnection(File(filesDir, "pairing.json"), this) {
            val configured = runCatching { android.provider.Settings.Global.getString(contentResolver, "device_name") }.getOrNull()
            (configured?.takeIf { it.isNotBlank() } ?: android.os.Build.MODEL ?: "Android 태블릿")
                .filterNot { it.isISOControl() }.trim().take(128).ifBlank { "Android 태블릿" }
        }
        decoder = VideoDecoder(this)
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        surface = SurfaceView(this).apply {
            contentDescription = "Mac 확장 화면. 짧은 탭은 왼쪽 클릭, 빠른 두 번 탭은 더블클릭, 0.5초 길게 누르기는 오른쪽 클릭, 한 손가락 움직임은 드래그, 두 손가락 세로 움직임은 스크롤, 뒤로가기는 제어 메뉴. 접근성 클릭은 제어 메뉴를 엽니다"
            isClickable = true
            isFocusable = true
            setOnClickListener {
                val click = pendingSurfaceClick
                pendingSurfaceClick = null
                if (click != null) sendSurfaceClick(click) else if (fullscreen) toggleBar()
            }
        }
        installSurfaceTouch()
        root.addView(surface, FrameLayout.LayoutParams(-1, -1, Gravity.CENTER))
        surface.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                surfaceReady = true
                if (foreground) {
                    if (active && !pauseRequested) latestConfig?.let { decoder.configure(it, holder.surface) }
                    else if (retained) pendingResume = true
                    maybeStart()
                }
            }
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                cancelSurfaceInput("surfaceChanged")
            }
            override fun surfaceDestroyed(holder: SurfaceHolder) {
                surfaceReady = false
                invalidateVideo()
                if (active || retained || startRequested) requestPause(false)
            }
        })
        ready = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(40), dp(32), dp(40), dp(32))
            setBackgroundColor(backgroundColor)
            addView(label("Tab-D", 18, sage), wrap().apply { bottomMargin = dp(42) })
            addView(label("▱", 64, sage), wrap().apply { bottomMargin = dp(22) })
            hostNameLabel = label("Mac", 30, Color.WHITE, true)
            addView(hostNameLabel, wrap())
        }
        stateLabel = label("Mac에 연결하는 중…", 16, muted)
        ready.addView(stateLabel, wrap().apply { topMargin = dp(12); bottomMargin = dp(26) })
        primary = button("화면 연결", true) {
            lastError = null
            recovery.userRetry()
            pendingRecoveryStart = false
            suppressResume = false
            preferences.edit().putBoolean("explicitlyDisconnected", false).apply()
            pauseRequested = false
            if (retained && state != "error" && !(recovery.recovering && (state == "ready" || state == "stopped"))) pendingResume = true else pendingStart = true
            updateState(if (recovery.suspended) "Mac이 잠자기 또는 잠금 상태입니다 · Mac을 깨우면 연결됩니다" else "연결을 준비하고 있습니다…")
            if (authenticated && recovery.awaitingStatus) { client.close(); authenticated = false }
            if (!client.connected) connect() else maybeStart()
        }
        ready.addView(primary, LinearLayout.LayoutParams(dp(240), dp(56)))
        ready.addView(button("설정", false) { settings() }, wrap().apply { topMargin = dp(16) })
        root.addView(ready, FrameLayout.LayoutParams(-1, -1))
        bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(18), dp(8), dp(12), dp(8))
            background = shape(Color.argb(238, 33, 39, 45), 20)
            visibility = View.GONE
            elevation = dp(12).toFloat()
        }
        barState = label("● 확장 중", 15, sage)
        bar.addView(barState, wrap().apply { marginEnd = dp(22) })
        bar.addView(button("화면 설정", false) { settings(); scheduleHide() })
        bar.addView(button("태블릿으로 돌아가기", true) { requestPause(true) })
        bar.addView(button("연결 종료", false) { disconnect() }, wrap().apply { marginStart = dp(12) })
        root.addView(bar, FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply { bottomMargin = dp(36) })
        root.setOnApplyWindowInsetsListener { _, insets ->
            val safe = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            ready.setPadding(dp(40) + safe.left, dp(32) + safe.top, dp(40) + safe.right, dp(32) + safe.bottom)
            (bar.layoutParams as FrameLayout.LayoutParams).apply { bottomMargin = dp(24) + safe.bottom; leftMargin = dp(20) + safe.left; rightMargin = dp(20) + safe.right; bar.layoutParams = this }
            val barsVisible = insets.isVisible(WindowInsets.Type.statusBars()) || insets.isVisible(WindowInsets.Type.navigationBars())
            if (systemBarsVisible != barsVisible) {
                systemBarsVisible = barsVisible
                diagnostics()
            }
            insets
        }
        setContentView(root)
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT) { handleBack() }
        }
        root.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> fitSurface() }
        diagnostics()
        main.post(heartbeat)
    }

    override fun onStart() {
        super.onStart()
        foreground = true
        leavingForHome = false
        if (retained) pendingResume = true
        main.post(reconnect)
        if (client.connected) {
            if (authenticated && recovery.awaitingStatus) awaitHostStatus() else maybeStart()
        }
    }
    override fun onPause() {
        cancelSurfaceInput("background")
        super.onPause()
    }
    override fun onStop() {
        if (active || retained || startRequested) requestPause(false)
        foreground = false
        cancelRecoveryCommand()
        pendingResume = false
        invalidateVideo()
        main.removeCallbacks(reconnect)
        diagnostics()
        super.onStop()
    }
    override fun onUserLeaveHint() {
        if ((active || retained || startRequested) && !leavingForHome) requestPause(false)
        super.onUserLeaveHint()
    }
    @Deprecated("Platform Activity back dispatch")
    // API 33+ uses the registered platform OnBackInvokedCallback; this override serves API 30–32 only.
    @android.annotation.SuppressLint("GestureBackNavigation")
    override fun onBackPressed() = handleBack()
    @Suppress("DEPRECATION")
    private fun handleBack() {
        if (fullscreen) toggleBar()
        else if (bar.visibility == View.VISIBLE) bar.visibility = View.GONE
        else if (active || retained || startRequested) requestPause(true)
        else finish()
    }
    override fun onDestroy() {
        cancelRecoveryCommand()
        cancelSurfaceInput("destroyed")
        main.removeCallbacksAndMessages(null)
        client.close()
        decoder.close()
        super.onDestroy()
    }

    private fun connect() {
        if (client.connect(preferences.getString("host", null), foreground)) {
            authenticated = false
            recovery.connectionReset()
            cancelRecoveryCommand()
        }
    }
    private fun send(type: String): Boolean = client.send(JSONObject().put("type", type))
    private fun maybeStart() {
        if (!authenticated || !surfaceReady || !foreground || !recovery.canRequest()) return
        if (pendingResume && retained && recovery.recovering && (state == "ready" || state == "stopped")) {
            pendingResume = false
            pendingStart = true; pendingRecoveryStart = true
        }
        when {
            pendingStart -> {
                if (send("start")) {
                    startRequested = true; pendingStart = false; pauseRequested = false
                    pendingRecoveryStart = false
                    awaitRecoveryCommand("start")
                    updateState("화면 연결 중…")
                }
            }
            pendingResume && retained -> {
                if (send("resume")) {
                    pendingResume = false; pauseRequested = false; resumeInFlight = true
                    awaitRecoveryCommand("resume")
                    updateState("유지한 화면으로 돌아가는 중…")
                }
            }
        }
    }
    private fun awaitRecoveryCommand(command: String) {
        recovery.commandSent(command, android.os.SystemClock.uptimeMillis())
        main.removeCallbacks(recoveryTimeout)
        main.postDelayed(recoveryTimeout, 5000)
    }
    private fun awaitHostStatus() {
        recovery.helloAcknowledged(android.os.SystemClock.uptimeMillis())
        main.removeCallbacks(recoveryTimeout)
        main.postDelayed(recoveryTimeout, 5000)
    }
    private fun cancelRecoveryCommand() {
        recovery.cancelCommand()
        main.removeCallbacks(recoveryTimeout)
        resumeInFlight = false
    }
    private fun retain(value: Boolean) {
        retained = value
        preferences.edit().putBoolean("retained", value).apply()
    }
    private fun requestPause(goHome: Boolean, force: Boolean = false) {
        cancelRecoveryCommand()
        if (goHome && state == "paused" && retained) { goHome(); return }
        if (goHome) {
            pendingHome = true
            main.removeCallbacks(homeTimeout)
            main.postDelayed(homeTimeout, 3000)
        }
        if (!pauseRequested || goHome || force) {
            pauseRequested = true
            resumeInFlight = false
            invalidateVideo()
            if (!send("pause") && goHome) {
                pendingHome = false
                pauseRequested = false
                main.removeCallbacks(homeTimeout)
                showError("Mac과 연결되어 있지 않아 화면 유지를 확인할 수 없습니다")
            }
        }
        // Persist intent early so a process killed just after Home can request resume; Mac remains authoritative.
        if (active || retained || startRequested) retain(true)
        diagnostics()
    }
    private fun goHome() {
        pendingHome = false
        leavingForHome = true
        main.removeCallbacks(homeTimeout)
        homeTaskMoved = moveTaskToBack(true)
        diagnostics()
        if (homeTaskMoved == false) finish()
    }
    private fun disconnect() {
        cancelRecoveryCommand()
        pendingRecoveryStart = false
        pendingStart = false; pendingResume = false; pendingHome = false; pauseRequested = false
        retain(false)
        suppressResume = true
        disconnectPending = true
        suppressionEpoch = hostEpoch
        preferences.edit().putBoolean("explicitlyDisconnected", true).apply()
        active = false
        startRequested = false; resumeInFlight = false
        invalidateVideo()
        showReady()
        updateState("연결 종료 중…")
        if (!send("disconnect")) showError("Mac의 연결 종료를 확인하지 못했습니다. Mac 메뉴에서 확인해주세요")
    }

    override fun control(value: JSONObject, generation: Long) {
        main.post {
            if (!client.isCurrent(generation)) return@post
            when (value.optString("type")) {
                "helloAck" -> {
                    hostNameLabel.text = value.optString("device", "").filterNot { it.isISOControl() }
                        .trim().take(128).ifBlank { "Mac" }
                    authenticated = true
                    lastError = null
                    if (foreground) awaitHostStatus() else cancelRecoveryCommand()
                    if (!retained && !pendingStart) updateState("● ${client.route} · 연결 가능")
                    // The following authoritative status decides whether the retained display still exists.
                }
                "status" -> {
                    val incomingState = value.optString("state", "ready")
                    val hadIntent = retained || active || startRequested || resumeInFlight || pendingResume || pendingStart
                    val action = recovery.status(incomingState, value.optBoolean("hostSuspended", false), value.optBoolean("hostRecovering", false), hadIntent && !suppressResume && !disconnectPending)
                    if (recovery.awaitingCommand == null) main.removeCallbacks(recoveryTimeout)
                    val announcedEpoch = value.optLong("epoch", hostEpoch)
                    hostEpoch = announcedEpoch
                    if (value.has("displayID")) displayID = value.optLong("displayID")
                    if (action == HostRecoveryGate.Action.HOLD) {
                        cancelRecoveryCommand()
                        active = false; startRequested = false
                        if (hadIntent && !suppressResume && !disconnectPending) retain(true)
                        pendingResume = retained && foreground
                        if (pendingRecoveryStart) pendingStart = false
                        pendingRecoveryStart = false
                        pauseRequested = true
                        state = "paused"
                        invalidateVideo(); showReady()
                        lastError = null
                        updateState("Mac이 잠자기 또는 잠금 상태입니다 · 화면을 유지하고 있습니다")
                        diagnostics()
                        return@post
                    }
                    when (incomingState) {
                        "starting" -> {
                            if (disconnectPending || (suppressResume && announcedEpoch <= suppressionEpoch)) return@post
                            lastError = null
                            cancelRecoveryCommand()
                            state = "starting"
                            suppressResume = false
                            preferences.edit().putBoolean("explicitlyDisconnected", false).apply()
                            pendingStart = false; pendingResume = false; pendingRecoveryStart = false
                            startRequested = false; resumeInFlight = false
                            if (foreground && !pendingHome) pauseRequested = false
                            active = true; retain(true); updateState("화면 연결 중…")
                            if (!foreground) requestPause(false, force = true)
                        }
                        "streaming" -> {
                            if (disconnectPending || suppressResume) return@post
                            lastError = null
                            cancelRecoveryCommand()
                            state = "streaming"
                            pendingStart = false; pendingResume = false; pendingRecoveryStart = false
                            if (foreground && !pendingHome) pauseRequested = false
                            active = true; startRequested = false; retain(true)
                            if (!foreground) requestPause(false, force = true)
                            else if (!fullscreen) updateState("화면을 표시하는 중…")
                        }
                        "paused" -> {
                            if (suppressResume) return@post
                            if (foreground && recovery.awaitingCommand != null) return@post
                            state = "paused"
                            active = false; retain(true)
                            startRequested = false; pauseRequested = true
                            if (pendingStart) {
                                pendingStart = false; pendingRecoveryStart = false; pendingResume = true
                            }
                            invalidateVideo(); showReady(); updateState("화면 유지 중 · 돌아오면 계속 표시됩니다")
                            if (action == HostRecoveryGate.Action.RESUME && foreground && !pendingHome && !leavingForHome) pendingResume = true
                            if (foreground && pendingResume && !pendingHome && !leavingForHome) maybeStart()
                        }
                        "ready", "stopped" -> {
                            lastError = null
                            state = incomingState
                            val recoverDisplay = recovery.recovering && hadIntent && !suppressResume && !disconnectPending
                            active = false; retain(recoverDisplay); pendingResume = false; pauseRequested = false
                            if (!recovery.recovering && pendingRecoveryStart) { pendingStart = false; pendingRecoveryStart = false }
                            if (action == HostRecoveryGate.Action.START && foreground && !pendingHome && !leavingForHome) {
                                pendingStart = true; pendingRecoveryStart = true
                            }
                            startRequested = false; resumeInFlight = false; disconnectPending = false
                            if (suppressResume) suppressionEpoch = hostEpoch
                            invalidateVideo(); showReady()
                            updateState("● ${client.route} · 연결 가능")
                            maybeStart()
                        }
                        "error" -> hostError(value.optString("message", "Mac에서 연결 상태를 확인해주세요"), value.optLong("displayID", 0) > 0)
                    }
                }
                "videoConfig" -> {
                    if (!foreground || !surfaceReady || !authenticated || !active || suppressResume || pauseRequested || disconnectPending) return@post
                    val configuredEpoch = value.optLong("epoch", -1)
                    if (configuredEpoch < 0 || (hostEpoch >= 0 && configuredEpoch != hostEpoch)) return@post
                    if (epoch != configuredEpoch || latestConfig == null) {
                        cancelSurfaceInput("epochChanged")
                        framesCurrentEpoch = 0
                    }
                    epoch = configuredEpoch
                    latestConfig = value
                    decoder.configure(value, surface.holder.surface)
                }
                "pauseAck" -> {
                    if (suppressResume || !pauseRequested || (foreground && resumeInFlight)) return@post
                    state = "paused"; active = false; retain(true)
                    if (value.has("displayID")) displayID = value.optLong("displayID")
                    startRequested = false
                    invalidateVideo(); showReady(); updateState("화면 유지 중 · Mac 창 배치는 유지됩니다")
                    if (pendingHome) goHome()
                }
                "disconnectAck" -> {
                    state = "stopped"; active = false; retain(false); latestConfig = null
                    disconnectPending = false; startRequested = false; resumeInFlight = false
                    invalidateVideo(); showReady(); updateState("● ${client.route} · 연결 가능")
                }
                "clickResult" -> {
                    val id = value.optString("id")
                    val request = pendingClicks[id] ?: return@post
                    if (value.optLong("epoch", -1) != request.epoch || request.epoch != epoch) return@post
                    pendingClicks.remove(id)
                    if (pendingClicks.isEmpty()) main.removeCallbacks(clickTimeout)
                    val accepted = value.optBoolean("accepted", false)
                    if (!accepted) doubleTaps.reset()
                    val message = value.optString("message", if (accepted) "" else "Mac에서 클릭 권한을 확인해주세요").take(240)
                    lastClick = clickDiagnostic(request, if (accepted) "accepted" else "rejected", message).put("accepted", accepted)
                    if (!accepted && fullscreen && foreground) showClickNotice(message.ifBlank { "Mac에서 클릭 권한을 확인해주세요" })
                    else if (accepted) barState.text = getString(R.string.bar_state, client.route)
                }
                "pointerResult" -> handlePointerResult(value)
                "scrollResult" -> {
                    val request = pendingScrolls[value.optString("id")] ?: return@post
                    if (value.optLong("epoch", -1) != request.epoch || request.epoch != epoch) return@post
                    pendingScrolls.remove(request.id)
                    if (pendingScrolls.isEmpty()) main.removeCallbacks(scrollTimeout)
                    val accepted = value.optBoolean("accepted", false)
                    val message = value.optString("message", if (accepted) "" else "Mac에서 스크롤 권한을 확인해주세요").take(240)
                    lastScroll = scrollDiagnostic(request, if (accepted) "accepted" else "rejected", message).put("accepted", accepted)
                    if (!accepted && fullscreen && foreground) showClickNotice(message.ifBlank { "Mac에서 스크롤 권한을 확인해주세요" })
                    else if (accepted) barState.text = getString(R.string.bar_state, client.route)
                }
                "ping" -> send("pong")
                "error" -> hostError(value.optString("message", "Mac에서 연결 상태를 확인해주세요"))
            }
            diagnostics()
        }
    }
    private fun canDecode(valueEpoch: Long) = foreground && surfaceReady && authenticated && active && !suppressResume && !pauseRequested && valueEpoch >= 0 && valueEpoch == epoch
    override fun frame(value: Wire.Frame, generation: Long) {
        if (!client.isCurrent(generation)) return
        transportFramesReceived.incrementAndGet()
        val accepted = canDecode(value.epoch)
        lastTransportFrame = FrameIngress(value.epoch, value.sequence, value.pts, value.keyframe, accepted)
        if (accepted) decoder.frame(value) else transportFramesRejected.incrementAndGet()
    }
    override fun connectionError(message: String, generation: Long) {
        main.post {
            if (!client.isCurrent(generation)) return@post
            authenticated = false
            cancelRecoveryCommand()
            recovery.connectionReset()
            invalidateVideo(); showReady()
            if (retained && foreground && !pendingStart) pendingResume = true
            showError(message)
            diagnostics()
        }
    }
    override fun decoderReady(epoch: Long, width: Int, height: Int, hardware: Boolean) {
        main.post {
            if (!canDecode(epoch)) return@post
            decodedWidth = width; decodedHeight = height; hardwareDecoder = hardware
            fitSurface()
            client.send(JSONObject().put("type", "decoderReady").put("epoch", epoch))
            diagnostics()
        }
    }
    override fun decoderDiagnostics(epoch: Long, details: JSONObject) {
        main.post {
            if (!canDecode(epoch)) return@post
            decoderDetails = details
            diagnostics()
        }
    }
    override fun decoderOutput(epoch: Long) {
        main.post { if (canDecode(epoch)) revealVideo() }
    }
    override fun rendered(epoch: Long, sequence: Long) {
        main.post {
            if (!canDecode(epoch)) return@post
            this.sequence = sequence; frames++; framesCurrentEpoch++
            revealVideo()
            if (presentedEpoch != epoch) {
                presentedEpoch = epoch
                client.send(JSONObject().put("type", "presented").put("epoch", epoch).put("sequence", sequence))
                if (!preferences.getBoolean("scrollHintSeen", false)) {
                    android.widget.Toast.makeText(this, "두 손가락을 위아래로 움직이면 스크롤합니다\n탭·두 번 탭·길게 누르기·드래그를 지원하며, 뒤로가기는 제어 메뉴입니다", android.widget.Toast.LENGTH_LONG).show()
                    preferences.edit().putBoolean("scrollHintSeen", true).apply()
                }
            }
            if (frames % 30L == 0L) diagnostics()
        }
    }
    override fun requestKeyframe(epoch: Long) {
        if (canDecode(epoch)) client.send(JSONObject().put("type", "keyframe").put("epoch", epoch))
    }
    override fun decoderError(message: String) { main.post { showError(message); diagnostics() } }

    private fun showReady() {
        fullscreen = false; ready.visibility = View.VISIBLE; bar.visibility = View.GONE
        window.insetsController?.show(WindowInsets.Type.systemBars())
    }
    private fun revealVideo() {
        if (fullscreen) return
        fullscreen = true; ready.visibility = View.GONE; bar.visibility = View.GONE
        hideSystemBars()
    }
    @Suppress("DEPRECATION")
    @android.annotation.SuppressLint("WrongConstant") // API 30's legacy name has the same value (1) as BEHAVIOR_DEFAULT.
    private fun hideSystemBars() {
        if (!fullscreen || !foreground) return
        window.insetsController?.apply {
            // Keep system Back available on the first edge gesture, even with bars hidden.
            systemBarsBehavior = if (android.os.Build.VERSION.SDK_INT >= 31) WindowInsetsController.BEHAVIOR_DEFAULT
                else WindowInsetsController.BEHAVIOR_SHOW_BARS_BY_SWIPE
            hide(WindowInsets.Type.systemBars())
        }
    }
    private fun updateState(message: String) {
        stateLabel.text = message
        primary.text = if (retained) "유지한 화면으로 돌아가기" else "화면 연결"
        barState.text = getString(R.string.bar_state, client.route)
    }
    private fun showError(message: String) { lastError = message; updateState(message) }
    private fun hostError(message: String, retainedDisplay: Boolean = false) {
        cancelRecoveryCommand()
        pendingRecoveryStart = false
        state = "error"; active = false; retain(retainedDisplay && !suppressResume)
        pendingStart = false; pendingResume = false; pauseRequested = false; pendingHome = false
        main.removeCallbacks(homeTimeout)
        startRequested = false; resumeInFlight = false; disconnectPending = false
        if (!retainedDisplay) displayID = null
        invalidateVideo(); showReady(); showError(message)
    }
    private fun invalidateVideo() {
        cancelSurfaceInput("videoInvalidated")
        if (pendingClicks.containsKey(lastClick?.optString("id"))) lastClick?.put("status", "cancelled")
        pendingClicks.clear(); main.removeCallbacks(clickTimeout)
        if (pendingScrolls.containsKey(lastScroll?.optString("id"))) lastScroll?.put("status", "cancelled")
        pendingScrolls.clear(); main.removeCallbacks(scrollTimeout)
        epoch = -1L
        presentedEpoch = -1L
        latestConfig = null
        decoder.stop()
    }
    private fun toggleBar() {
        cancelSurfaceInput("menuToggled")
        bar.visibility = if (bar.visibility == View.VISIBLE) View.GONE else View.VISIBLE
        if (bar.visibility == View.VISIBLE) scheduleHide()
        else {
            main.removeCallbacks(hideBar)
            hideSystemBars()
        }
        diagnostics()
    }
    // handleSurfaceTouch dispatches valid taps through performClick; accessibility uses the click listener.
    @android.annotation.SuppressLint("ClickableViewAccessibility")
    private fun installSurfaceTouch() {
        surface.setOnTouchListener { view, event -> handleSurfaceTouch(view, event) }
    }
    private fun handleSurfaceTouch(view: View, event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                singleInputSuppressed = false
                // A normally completed first tap must survive preparation for the next contact.
                cancelSurfaceInput("newContact", resetDoubleTap = tapPointer >= 0 || drag != null)
                tapClosesBar = bar.visibility == View.VISIBLE
                tapPointer = if (event.pointerCount == 1 && fullscreen && (tapClosesBar || canSendInput(epoch))) event.getPointerId(0) else -1
                if (tapPointer >= 0) {
                    if (tapClosesBar) {
                        doubleTaps.reset()
                        tapGesture.begin(event.x, event.y, event.eventTime, epoch, view.width, view.height)
                    }
                    else {
                        doubleTaps.down(DoubleTapClassifier.Sample(event.x, event.y, event.eventTime, epoch, view.width, view.height))
                        inputGesture.begin(event.x, event.y, event.eventTime, epoch, view.width, view.height)
                        main.postDelayed(longPress, maxOf(0L, event.eventTime + 500 - android.os.SystemClock.uptimeMillis()))
                    }
                } else doubleTaps.reset()
            }
            MotionEvent.ACTION_MOVE -> {
                if (singleInputSuppressed) updateScrollFromEvent(view, event)
                else if (event.pointerCount != 1 || event.getPointerId(0) != tapPointer) cancelSurfaceInput("pointerChanged")
                else if (tapClosesBar) {
                    for (index in 0 until event.historySize) tapGesture.move(event.getHistoricalX(index), event.getHistoricalY(index))
                    tapGesture.move(event.x, event.y)
                } else if (!canSendInput(epoch)) cancelSurfaceInput("unavailable")
                else {
                    for (index in 0 until event.historySize) {
                        if (tapPointer < 0) break
                        dispatchInput(inputGesture.move(event.getHistoricalX(index), event.getHistoricalY(index), event.getHistoricalEventTime(index), epoch, view.width, view.height))
                    }
                    if (tapPointer >= 0) dispatchInput(inputGesture.move(event.x, event.y, event.eventTime, epoch, view.width, view.height))
                }
            }
            MotionEvent.ACTION_UP -> {
                main.removeCallbacks(longPress)
                if (singleInputSuppressed) {
                    cancelScroll(flush = true)
                    cancelSurfaceInput("allPointersUp")
                    singleInputSuppressed = false
                    diagnostics()
                    return true
                }
                lastSurfaceUp = DoubleTapClassifier.Sample(event.x, event.y, event.eventTime, epoch, view.width, view.height)
                if (event.pointerCount == 1 && event.getPointerId(0) == tapPointer) {
                    if (tapClosesBar) {
                        val tap = tapGesture.end(event.x, event.y, event.eventTime, epoch, view.width, view.height)
                        if (tap != null && fullscreen && bar.visibility == View.VISIBLE) toggleBar()
                    } else if (canSendInput(epoch)) dispatchInput(inputGesture.end(event.x, event.y, event.eventTime, epoch, view.width, view.height))
                    else cancelSurfaceInput("unavailable")
                } else cancelSurfaceInput("pointerChanged")
                tapPointer = -1
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                val canBegin = !singleInputSuppressed && event.pointerCount == 2 && canSendInput(epoch)
                // A held left button must be released before any scroll enters the TLS writer FIFO.
                cancelSurfaceInput("multiplePointers")
                singleInputSuppressed = true
                if (canBegin && canSendInput(epoch)) scrollGesture.begin(scrollPointers(event), epoch, view.width, view.height)
                diagnostics()
            }
            MotionEvent.ACTION_POINTER_UP -> {
                if (scrollGesture.tracking && event.pointerCount == 2) {
                    updateScrollFromEvent(view, event)
                    flushScrollDelta()
                }
                cancelScroll()
                singleInputSuppressed = true
                tapPointer = -1
                diagnostics()
            }
            MotionEvent.ACTION_CANCEL -> {
                cancelSurfaceInput("systemCancelled")
                singleInputSuppressed = true
                diagnostics()
            }
        }
        return true
    }
    private fun dispatchInput(actions: List<SurfaceInputGesture.Action>) {
        for (action in actions) when (action) {
            is SurfaceInputGesture.Action.Click -> {
                main.removeCallbacks(longPress)
                if (action.button != "left") doubleTaps.reset()
                if (canSendInput(action.point.epoch)) {
                    pendingSurfaceClick = action
                    surface.performClick()
                }
            }
            is SurfaceInputGesture.Action.Begin -> {
                main.removeCallbacks(longPress)
                doubleTaps.reset()
                beginDrag(action.point)
            }
            is SurfaceInputGesture.Action.Move -> queueDragMove(action.point)
            is SurfaceInputGesture.Action.End -> finishDrag("end")
            is SurfaceInputGesture.Action.Cancel -> {
                doubleTaps.reset()
                finishDrag("cancel", "gestureInvalidated")
            }
        }
    }
    private fun canSendInput(requestEpoch: Long) = fullscreen && state == "streaming" && canDecode(requestEpoch) &&
        !disconnectPending && bar.visibility != View.VISIBLE
    private fun scrollPointers(event: MotionEvent, history: Int? = null) = (0 until event.pointerCount).map { index ->
        TwoFingerScrollGesture.Pointer(event.getPointerId(index),
            if (history == null) event.getX(index) else event.getHistoricalX(index, history),
            if (history == null) event.getY(index) else event.getHistoricalY(index, history))
    }
    private fun updateScrollFromEvent(view: View, event: MotionEvent) {
        if (!scrollGesture.tracking) return
        if (event.pointerCount != 2 || !canSendInput(epoch)) { cancelScroll(); return }
        for (index in 0 until event.historySize) {
            if (!scrollGesture.tracking) break
            scrollGesture.move(scrollPointers(event, index), epoch, view.width, view.height)?.let(::queueScrollDelta)
        }
        if (scrollGesture.tracking) scrollGesture.move(scrollPointers(event), epoch, view.width, view.height)?.let(::queueScrollDelta)
        if (!scrollGesture.tracking) cancelScroll()
    }
    private fun queueScrollDelta(delta: TwoFingerScrollGesture.Delta) {
        if (!canSendInput(delta.epoch)) { cancelScroll(); return }
        pendingScroll = combineScrollDelta(pendingScroll, delta)
        main.removeCallbacks(flushScroll)
        val delay = 17 - (android.os.SystemClock.uptimeMillis() - lastScrollSentAt)
        if (delay <= 0) flushScrollDelta() else main.postDelayed(flushScroll, delay)
    }
    private fun flushScrollDelta() {
        main.removeCallbacks(flushScroll)
        val delta = pendingScroll ?: return
        pendingScroll = null
        if (delta.deltaY == 0f || !canSendInput(delta.epoch)) return
        val request = ScrollRequest(java.util.UUID.randomUUID().toString(), delta.epoch, delta.x, delta.y, delta.deltaY, android.os.SystemClock.uptimeMillis())
        if (pendingScrolls.size >= 32) {
            lastScroll = scrollDiagnostic(request, "queueFull", "스크롤 응답을 기다리고 있습니다")
            showClickNotice("Mac의 스크롤 응답을 기다리고 있습니다")
            diagnostics()
            return
        }
        val sent = client.send(JSONObject().put("type", "scroll").put("id", request.id).put("epoch", request.epoch)
            .put("x", request.x).put("y", request.y).put("deltaY", request.deltaY))
        lastScrollSentAt = request.sentAt
        lastScroll = scrollDiagnostic(request, if (sent) "pending" else "sendFailed", if (sent) "" else "Mac으로 스크롤을 전달하지 못했습니다")
        if (sent) {
            scrollCount++
            pendingScrolls[request.id] = request
            if (pendingScrolls.size == 1) main.postDelayed(scrollTimeout, 500)
        } else showClickNotice("Mac으로 스크롤을 전달하지 못했습니다")
        diagnostics()
    }
    private fun cancelScroll(flush: Boolean = false) {
        if (flush) flushScrollDelta()
        main.removeCallbacks(flushScroll)
        pendingScroll = null
        scrollGesture.cancel()
    }
    private fun scrollDiagnostic(request: ScrollRequest, status: String, message: String) = JSONObject()
        .put("id", request.id).put("epoch", request.epoch).put("x", request.x).put("y", request.y).put("deltaY", request.deltaY)
        .put("status", status).put("message", message).put("updatedAtMillis", System.currentTimeMillis())
    private fun sendSurfaceClick(click: SurfaceInputGesture.Action.Click) {
        val point = click.point
        if (!canSendInput(point.epoch)) { doubleTaps.reset(); return }
        if (pendingClicks.size >= 16) { showClickNotice("클릭 응답을 기다리고 있습니다"); return }
        val clickCount = if (click.button == "left") doubleTaps.up(lastSurfaceUp) else 1
        val request = ClickRequest(java.util.UUID.randomUUID().toString(), point.epoch, point.x, point.y, click.button, clickCount, android.os.SystemClock.uptimeMillis())
        val sent = client.send(JSONObject().put("type", "click").put("epoch", request.epoch).put("id", request.id)
            .put("x", request.x).put("y", request.y).put("button", request.button).put("clickCount", request.clickCount))
        lastClick = clickDiagnostic(request, if (sent) "pending" else "sendFailed", if (sent) "" else "Mac으로 클릭을 전달하지 못했습니다")
        if (sent) {
            pendingClicks[request.id] = request
            if (pendingClicks.size == 1) main.postDelayed(clickTimeout, 500)
        } else {
            doubleTaps.reset()
            showClickNotice("Mac으로 클릭을 전달하지 못했습니다")
        }
        diagnostics()
    }
    private fun clickDiagnostic(request: ClickRequest, status: String, message: String) = JSONObject()
        .put("id", request.id).put("epoch", request.epoch).put("x", request.x).put("y", request.y)
        .put("button", request.button)
        .put("clickCount", request.clickCount)
        .put("status", status).put("message", message).put("updatedAtMillis", System.currentTimeMillis())
    private fun beginDrag(point: SurfaceInputGesture.Point) {
        if (!canSendInput(point.epoch) || pendingPointers.size >= 16) {
            cancelSurfaceInput("beginUnavailable")
            return
        }
        val session = PointerSession(java.util.UUID.randomUUID().toString(), point.epoch, point)
        drag = session
        if (!sendPointer(session, "begin")) {
            cancelSurfaceInput("beginSendFailed")
            showClickNotice("Mac으로 드래그를 전달하지 못했습니다")
            return
        }
        main.postDelayed(pointerKeepAlive, 500)
        diagnostics()
    }
    private fun queueDragMove(point: SurfaceInputGesture.Point) {
        val session = drag ?: return
        if (session.epoch != point.epoch || !canSendInput(session.epoch)) { cancelSurfaceInput("moveUnavailable"); return }
        session.point = point
        session.pendingMove = point
        main.removeCallbacks(flushPointerMove)
        val delay = 17 - (android.os.SystemClock.uptimeMillis() - session.lastSentAt)
        if (delay <= 0) flushDragMove(session) else main.postDelayed(flushPointerMove, delay)
    }
    private fun flushDragMove(session: PointerSession): Boolean {
        val point = session.pendingMove ?: return true
        session.pendingMove = null
        if (drag !== session) return false
        session.point = point
        if (sendPointer(session, "move")) return true
        cancelSurfaceInput("moveSendFailed")
        showClickNotice("Mac으로 드래그를 전달하지 못했습니다")
        return false
    }
    private fun finishDrag(phase: String, reason: String = "") {
        main.removeCallbacks(flushPointerMove)
        main.removeCallbacks(pointerKeepAlive)
        val session = drag ?: return
        if (!flushDragMove(session) || drag !== session) return
        val sent = sendPointer(session, phase)
        drag = null
        lastPointer = pointerDiagnostic(session, if (sent) "${phase}Pending" else "${phase}SendFailed", reason).put("phase", phase)
        diagnostics()
    }
    private fun sendPointer(session: PointerSession, phase: String): Boolean {
        session.sequence++
        val sent = client.send(JSONObject().put("type", "pointer").put("phase", phase).put("epoch", session.epoch)
            .put("id", session.id).put("sequence", session.sequence).put("x", session.point.x).put("y", session.point.y))
        session.lastSentAt = android.os.SystemClock.uptimeMillis()
        if (sent && phase != "move") {
            val wasEmpty = pendingPointers.isEmpty()
            session.waiting[phase] = session.lastSentAt
            pendingPointers[session.id] = session
            if (wasEmpty) main.postDelayed(pointerTimeout, 500)
        }
        lastPointer = pointerDiagnostic(session, if (sent) "${phase}Pending" else "${phase}SendFailed", "")
            .put("phase", phase)
        return sent
    }
    private fun handlePointerResult(value: JSONObject) {
        val session = pendingPointers[value.optString("id")] ?: return
        if (value.optLong("epoch", -1) != session.epoch) return
        val phase = value.optString("phase")
        if (session.waiting.remove(phase) == null) return
        val accepted = value.optBoolean("accepted", false)
        val message = value.optString("message", if (accepted) "" else "Mac에서 입력 권한을 확인해주세요").take(240)
        if (!accepted && phase == "begin" && drag === session) cancelSurfaceInput("beginRejected")
        lastPointer = pointerDiagnostic(session, if (accepted) "accepted" else "rejected", message)
            .put("phase", phase).put("accepted", accepted)
        if (session.waiting.isEmpty()) pendingPointers.remove(session.id)
        if (pendingPointers.isEmpty()) main.removeCallbacks(pointerTimeout)
        if (!accepted && phase != "cancel" && session.epoch == epoch && fullscreen && foreground)
            showClickNotice(message.ifBlank { "Mac에서 입력 권한을 확인해주세요" })
    }
    private fun pointerDiagnostic(session: PointerSession, status: String, message: String) = JSONObject()
        .put("id", session.id).put("epoch", session.epoch).put("sequence", session.sequence)
        .put("x", session.point.x).put("y", session.point.y).put("status", status).put("message", message)
        .put("updatedAtMillis", System.currentTimeMillis())
    private fun cancelSurfaceInput(reason: String, resetDoubleTap: Boolean = true) {
        if (resetDoubleTap) doubleTaps.reset()
        lastSurfaceUp = null
        inputGesture.cancel(); tapGesture.cancel(); tapPointer = -1; pendingSurfaceClick = null
        main.removeCallbacks(longPress)
        finishDrag("cancel", reason)
        cancelScroll()
    }
    private fun showClickNotice(message: String) {
        android.widget.Toast.makeText(this, message, android.widget.Toast.LENGTH_LONG).show()
        if (fullscreen) {
            barState.text = "● 입력 확인 필요"
            bar.visibility = View.VISIBLE
            cancelSurfaceInput("noticeShown")
            scheduleHide()
        }
    }
    private fun scheduleHide() {
        main.removeCallbacks(hideBar)
        val manager = getSystemService(ACCESSIBILITY_SERVICE) as AccessibilityManager
        main.postDelayed(hideBar, manager.getRecommendedTimeoutMillis(5000, AccessibilityManager.FLAG_CONTENT_CONTROLS).toLong())
    }
    private fun settings() {
        main.removeCallbacks(hideBar)
        val width = latestConfig?.optInt("width", 0) ?: 0
        val height = latestConfig?.optInt("height", 0) ?: 0
        val quality = if (width > 0 && height > 0) "현재 화질 $width × $height\n" else ""
        val input = EditText(this).apply {
            setSingleLine(true)
            hint = "USB: 비워두기 / 무선: Mac IP 주소"
            setText(preferences.getString("host", ""))
            setPadding(dp(20), dp(18), dp(20), dp(18))
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_URI
        }
        AlertDialog.Builder(this).setTitle("화면 설정")
            .setMessage("${quality}화질은 Mac의 Tab-D 메뉴에서 변경합니다.\n연결 주소는 화면 연결을 종료한 뒤 바꿀 수 있습니다.")
            .setView(input).setNegativeButton("닫기", null)
            .setPositiveButton("주소 적용") { _, _ ->
                val host = input.text.toString().trim()
                if (active || retained) {
                    showError("연결 종료 후 주소를 바꿔주세요")
                } else if (host.contains(Regex("[\\s/:]")) && host != "127.0.0.1") {
                    showError("호스트 이름 또는 IPv4 주소만 입력해주세요")
                } else {
                    preferences.edit().putString("host", host).apply()
                    client.close(); authenticated = false; connect()
                }
            }.setOnDismissListener { if (fullscreen) scheduleHide() }.show()
    }
    private fun fitSurface() {
        if (decodedWidth <= 0 || decodedHeight <= 0 || root.width <= 0) return
        val scale = minOf(root.width.toFloat() / decodedWidth, root.height.toFloat() / decodedHeight)
        val width = (decodedWidth * scale).toInt(); val height = (decodedHeight * scale).toInt()
        if (surface.width != width || surface.height != height) surface.layoutParams = FrameLayout.LayoutParams(width, height, Gravity.CENTER)
    }
    private fun diagnostics() {
        runCatching {
            val value = JSONObject().put("state", state).put("authenticated", authenticated).put("foreground", foreground)
                .put("connected", client.connected).put("awaitingHostStatus", recovery.awaitingStatus)
                .put("hostSuspended", recovery.suspended).put("hostRecovering", recovery.recovering)
                .put("pendingStart", pendingStart).put("pendingResume", pendingResume).put("resumeInFlight", resumeInFlight)
                .put("awaitingCommand", recovery.awaitingCommand).put("commandDeadlineMillis", recovery.deadlineMillis)
                .put("recoveryRetryBlocked", recovery.retryBlocked)
                .put("retained", retained).put("pauseRequested", pauseRequested).put("pendingHome", pendingHome)
                .put("homeTaskMoved", homeTaskMoved)
                .put("fullscreen", fullscreen).put("surfaceReady", surfaceReady).put("frames", frames)
                .put("barVisible", bar.visibility == View.VISIBLE).put("pendingClickCount", pendingClicks.size).put("lastClick", lastClick)
                .put("systemBarsVisible", systemBarsVisible)
                .put("dragging", drag != null).put("pointerID", drag?.id)
                .put("pendingPointerCount", pendingPointers.size).put("lastPointer", lastPointer)
                .put("scrolling", scrollGesture.scrolling).put("singleInputSuppressed", singleInputSuppressed)
                .put("scrollCount", scrollCount).put("pendingScrollCount", pendingScrolls.size).put("lastScroll", lastScroll)
                .put("framesCurrentEpoch", framesCurrentEpoch).put("transportFramesReceived", transportFramesReceived.get())
                .put("transportFramesRejected", transportFramesRejected.get())
                .put("epoch", epoch).put("sequence", sequence).put("displayID", displayID)
                .put("width", decodedWidth).put("height", decodedHeight).put("hardwareDecoder", hardwareDecoder)
                .put("decoder", decoderDetails)
                .put("connectionFailure", client.lastFailure)
                .put("route", client.route).put("lastError", lastError).put("updatedAtMillis", System.currentTimeMillis())
            lastTransportFrame?.let { frame -> value.put("lastTransportFrame", JSONObject().put("epoch", frame.epoch)
                .put("sequence", frame.sequence).put("pts", frame.pts).put("keyframe", frame.keyframe).put("accepted", frame.accepted)) }
            val temporary = File(filesDir, "diagnostics.tmp")
            temporary.writeText(value.toString(2))
            temporary.renameTo(File(filesDir, "diagnostics.json"))
        }
    }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun wrap() = LinearLayout.LayoutParams(-2, -2)
    private fun label(text: String, size: Int, color: Int, bold: Boolean = false) = TextView(this).apply {
        this.text = text; textSize = size.toFloat(); setTextColor(color); gravity = Gravity.CENTER
        if (bold) setTypeface(typeface, Typeface.BOLD)
    }
    private fun shape(color: Int, radius: Int) = GradientDrawable().apply { setColor(color); cornerRadius = dp(radius).toFloat() }
    // This observer returns false; Button itself performs the accessible click action.
    @android.annotation.SuppressLint("ClickableViewAccessibility")
    private fun button(text: String, emphasized: Boolean, action: (View) -> Unit) = Button(this).apply {
        this.text = text; isAllCaps = false; textSize = 15f
        minHeight = dp(48); minimumHeight = dp(48); minWidth = dp(48)
        setTextColor(if (emphasized) backgroundColor else Color.WHITE)
        background = shape(if (emphasized) sage else Color.TRANSPARENT, 12)
        setPadding(dp(22), dp(8), dp(22), dp(8))
        setOnTouchListener { _, event ->
            when (event.actionMasked) {
                android.view.MotionEvent.ACTION_DOWN -> main.removeCallbacks(hideBar)
                android.view.MotionEvent.ACTION_UP, android.view.MotionEvent.ACTION_CANCEL -> if (::bar.isInitialized && fullscreen) scheduleHide()
            }
            false
        }
        setOnClickListener(action)
    }
}
