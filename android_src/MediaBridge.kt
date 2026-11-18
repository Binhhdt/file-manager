package com.fmdemo.file_manager

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Rational
import android.view.TextureView
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.View
import android.view.WindowManager
import androidx.media3.common.util.UnstableApi
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

@UnstableApi
internal class MediaBridge(private val activity: Activity, engine: FlutterEngine) {
    private val commands = MethodChannel(engine.dartExecutor.binaryMessenger, "fm/media")
    private val events = EventChannel(engine.dartExecutor.binaryMessenger, "fm/media-events")
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var playback: MediaPlaybackService? = null
    private var bound = false
    private var resumed = false
    private var inPip = false
    private var fullscreen = false
    private var keepAwake = false
    private var page: Int? = null
    private var texture: TextureView? = null
    private var pendingLaunch = activity.intent?.action == MediaPlaybackService.OPEN_PLAYER
    private val requestQueue = ArrayDeque<Pair<MethodChannel.Result, (MediaPlaybackService) -> Any?>>()
    private val observer: () -> Unit = { broadcast() }

    private val ticker = object : Runnable {
        override fun run() {
            if (resumed && page != null && sink != null) {
                broadcast()
                main.postDelayed(this, 400)
            }
        }
    }

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            val service = (binder as MediaPlaybackService.LocalBinder).playback
            playback = service
            service.observe(observer)
            updatePresentation()
            service.attachTexture(texture)
            while (requestQueue.isNotEmpty()) {
                val (reply, action) = requestQueue.removeFirst()
                invoke(service, reply, action)
            }
            broadcast()
            publishLaunch()
        }

        override fun onServiceDisconnected(name: ComponentName) {
            playback = null
            broadcast()
        }
    }

    init {
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
                sink = eventSink
                bind()
                broadcast()
                publishLaunch()
            }

            override fun onCancel(arguments: Any?) {
                sink = null
                main.removeCallbacks(ticker)
            }
        })
        commands.setMethodCallHandler { call, reply ->
            when (call.method) {
                "show" -> {
                    page = call.argument<Int>("view")
                    updatePresentation()
                    reply.success(null)
                }
                "hide" -> {
                    if (page == call.argument<Int>("view")) {
                        page = null
                        setFullscreen(false)
                        val service = playback
                        if (service?.closesVideoWithView() == true) stop(service)
                        updatePresentation()
                    }
                    reply.success(null)
                }
                "pip" -> reply.success(enterPip())
                "fullscreen" -> {
                    setFullscreen(page != null && call.argument<Boolean>("enabled") == true)
                    reply.success(null)
                }
                "open" -> withService(reply) { service ->
                    val paths = call.argument<List<String>>("paths").orEmpty()
                    val index = call.argument<Int>("index") ?: 0
                    val isVideo = call.argument<Boolean>("video") == true
                    val requestPage = call.argument<Int>("view")
                    if (isVideo && requestPage != null && page != requestPage) return@withService null
                    val positions = call.argument<Map<String, Number>>("legacy").orEmpty().mapValues { it.value.toLong() }
                    service.open(paths, index, isVideo, positions)
                    null
                }
                "restore" -> withService(reply) { it.restoreMusic() }
                "toggle" -> withService(reply) { it.toggle() }
                "stop" -> withService(reply) { stop(it); null }
                "seek" -> withService(reply) { it.seek(call.argument<Number>("position")?.toLong() ?: 0L) }
                "select" -> withService(reply) { it.select(call.argument<Int>("index") ?: -1) }
                "previous" -> withService(reply) { it.previous() }
                "next" -> withService(reply) { it.next() }
                "speed" -> withService(reply) { it.setSpeed(call.argument<Number>("speed")?.toFloat() ?: 1f) }
                "shuffle" -> withService(reply) { it.toggleShuffle() }
                "repeat" -> withService(reply) { it.cycleRepeat() }
                "background" -> withService(reply) { it.toggleBackground() }
                "resume" -> withService(reply) { it.resumeVideo(call.argument<Boolean>("keep") == true) }
                "queue" -> withService(reply) { it.queue() }
                else -> reply.notImplemented()
            }
        }

        engine.platformViewsController.registry.registerViewFactory(
            "fm/media-video",
            object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
                    val video = TextureView(context)
                    texture = video
                    playback?.attachTexture(video)
                    return object : PlatformView {
                        override fun getView(): View = video
                        override fun dispose() {
                            if (texture === video) {
                                texture = null
                                playback?.attachTexture(null)
                            }
                        }
                    }
                }
            }
        )
    }

    private fun bind() {
        if (bound) return
        val intent = Intent(activity, MediaPlaybackService::class.java).setAction(MediaPlaybackService.LOCAL_BIND)
        bound = activity.bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)
    }

    private fun withService(reply: MethodChannel.Result, action: (MediaPlaybackService) -> Any?) {
        val service = playback
        if (service != null) {
            invoke(service, reply, action)
            return
        }
        bind()
        if (bound) requestQueue.add(reply to action)
        else reply.error("PLAYER", "Không kết nối được trình phát Android.", null)
    }

    private fun invoke(service: MediaPlaybackService, reply: MethodChannel.Result, action: (MediaPlaybackService) -> Any?) {
        try {
            val value = action(service)
            reply.success(if (value == Unit) null else value)
        } catch (error: Exception) {
            reply.error("PLAYER", error.message ?: "Không thực hiện được thao tác phát.", null)
        }
    }

    private fun stop(service: MediaPlaybackService) {
        service.stopPlayback()
        service.removeObserver(observer)
        service.attachTexture(null)
        playback = null
        if (bound) {
            activity.unbindService(serviceConnection)
            bound = false
        }
    }

    fun activityVisible(value: Boolean) {
        resumed = value
        updatePresentation()
    }

    fun pipChanged(value: Boolean) {
        inPip = value
        updatePresentation()
    }

    fun newIntent(intent: Intent) {
        if (intent.action != MediaPlaybackService.OPEN_PLAYER) return
        pendingLaunch = true
        publishLaunch()
    }

    private fun publishLaunch() {
        if (pendingLaunch && playback != null && sink != null) {
            pendingLaunch = false
            sink?.success(mapOf("openPlayer" to true))
        }
    }

    private fun updatePresentation() {
        playback?.setPresentation(resumed, page != null, inPip)
        main.removeCallbacks(ticker)
        if (resumed && page != null && sink != null) main.postDelayed(ticker, 400L)
        broadcast()
    }

    private fun broadcast() {
        val snapshot = playback?.snapshot().orEmpty()
        val bright = snapshot["video"] == true && snapshot["playing"] == true && resumed && page != null && !inPip
        if (bright != keepAwake) {
            keepAwake = bright
            if (bright) activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            else activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        sink?.success(snapshot + mapOf("supportsPip" to supportsPip()))
    }

    private fun setFullscreen(value: Boolean) {
        if (fullscreen == value) return
        fullscreen = value
        val window = activity.window
        if (Build.VERSION.SDK_INT >= 30) {
            val controller = window.insetsController ?: return
            if (value) {
                controller.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                controller.hide(WindowInsets.Type.systemBars())
            } else controller.show(WindowInsets.Type.systemBars())
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = if (value)
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                else 0
        }
    }

    private fun supportsPip() =
        Build.VERSION.SDK_INT >= 26 && activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun enterPip(): Boolean {
        if (Build.VERSION.SDK_INT < 26 || !supportsPip() || page == null) return false
        val state = playback?.snapshot() ?: return false
        if (state["video"] != true || state["ready"] != true) return false
        val width = state["width"] as? Int ?: 0
        val height = state["height"] as? Int ?: 0
        val params = PictureInPictureParams.Builder()
        if (width > 0 && height > 0) {
            val aspect = (width.toDouble() / height).coerceIn(0.42, 2.38)
            params.setAspectRatio(Rational((aspect * 1000).toInt(), 1000))
        }
        return runCatching { activity.enterPictureInPictureMode(params.build()) }.getOrDefault(false)
    }

    fun close() {
        main.removeCallbacksAndMessages(null)
        commands.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
        val service = playback
        service?.removeObserver(observer)
        service?.attachTexture(null)
        service?.setPresentation(false, false, false)
        playback = null
        if (bound) activity.unbindService(serviceConnection)
        requestQueue.forEach { (reply, _) -> reply.error("PLAYER", "Trình phát đã đóng.", null) }
        requestQueue.clear()
        setFullscreen(false)
        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
}
