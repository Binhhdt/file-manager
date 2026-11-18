package com.fmdemo.file_manager

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.net.Uri
import android.os.Binder
import android.os.Build
import android.os.FileObserver
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.DocumentsContract
import android.view.TextureView
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionResult
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import org.json.JSONArray
import java.io.File
import java.io.FileNotFoundException
import java.security.MessageDigest
import java.util.concurrent.Executors

@UnstableApi
class MediaPlaybackService : MediaSessionService(), Player.Listener {
    internal companion object {
        const val LOCAL_BIND = "com.fmdemo.file_manager.PLAYBACK_LOCAL"
        const val OPEN_PLAYER = "com.fmdemo.file_manager.OPEN_PLAYER"
        const val TREE_PREFIX = "/@saf/"
    }

    internal class LocalBinder(val playback: MediaPlaybackService) : Binder()

    private lateinit var session: MediaSession
    private lateinit var player: ExoPlayer
    private lateinit var saved: PlaybackPreferences
    private val binder = LocalBinder(this)
    private val handler = Handler(Looper.getMainLooper())
    private val artworkWorker = Executors.newSingleThreadExecutor()
    private val listeners = linkedSetOf<() -> Unit>()

    private var video = false
    private var backgroundAudio = false
    private var activityVisible = false
    private var viewVisible = false
    private var pip = false
    private var pausedByVisibility = false
    private var changingQueue = false
    private var rememberedQueue = false
    private var pendingResume = 0L
    private var resumeCandidate = 0L
    private var legacyPositions = emptyMap<String, Long>()
    private var error: String? = null
    private var artwork: String? = null
    private var artworkBytes: ByteArray? = null
    private var artworkGeneration = 0
    private var watchedPath: String? = null
    private var fileWatch: FileObserver? = null
    private var texture: TextureView? = null
    private var previousDuration = 0L

    private val currentPath: String? get() = player.currentMediaItem?.mediaId
    private val duration: Long get() = player.duration.coerceAtLeast(0L)

    private val checkpoint = object : Runnable {
        override fun run() {
            savePosition()
            if (player.isPlaying) handler.postDelayed(this, 5000L)
        }
    }

    private val mountedMedia = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val path = currentPath ?: return
            val root = intent.data?.path ?: return
            val affected = if (path.startsWith(TREE_PREFIX)) {
                runCatching {
                    val tree = parseTree(path).first
                    DocumentsContract.getTreeDocumentId(tree).substringBefore(':')
                        .equals(File(root).name, ignoreCase = true)
                }.getOrDefault(false)
            } else path == root || path.startsWith("${root.trimEnd('/')}/")
            if (affected) sourceLost()
        }
    }

    override fun onCreate() {
        super.onCreate()
        saved = PlaybackPreferences(getSharedPreferences("fm_media", MODE_PRIVATE))
        val data = ResolvingDataSource.Factory(DefaultDataSource.Factory(this)) { spec ->
            val path = spec.uri.getQueryParameter("path") ?: throw FileNotFoundException()
            spec.withUri(sourceUri(path))
        }
        player = ExoPlayer.Builder(this)
            .setMediaSourceFactory(DefaultMediaSourceFactory(data))
            .setSeekBackIncrementMs(10_000L)
            .setSeekForwardIncrementMs(10_000L)
            .build()
        player.setWakeMode(C.WAKE_MODE_LOCAL)
        player.setHandleAudioBecomingNoisy(true)
        audioAttributes()
        player.addListener(this)

        val launch = Intent(this, MainActivity::class.java).setAction(OPEN_PLAYER)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val open = PendingIntent.getActivity(this, 703, launch,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val sessionPlayer = object : ForwardingPlayer(player) {
            override fun getMediaMetadata(): MediaMetadata {
                val metadata = super.getMediaMetadata()
                return if (metadata.title.isNullOrBlank() && metadata.displayTitle != null)
                    metadata.buildUpon().setTitle(metadata.displayTitle).build()
                else metadata
            }
        }
        session = MediaSession.Builder(this, sessionPlayer)
            .setSessionActivity(open)
            .setCallback(SessionCallback())
            .build()
        addSession(session)

        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_MEDIA_EJECT)
            addAction(Intent.ACTION_MEDIA_UNMOUNTED)
            addAction(Intent.ACTION_MEDIA_REMOVED)
            addAction(Intent.ACTION_MEDIA_BAD_REMOVAL)
            addDataScheme("file")
        }
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(mountedMedia, filter, RECEIVER_NOT_EXPORTED)
        else @Suppress("DEPRECATION") registerReceiver(mountedMedia, filter)
    }

    override fun onBind(intent: Intent?): IBinder? =
        if (intent?.action == LOCAL_BIND) binder else super.onBind(intent)

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession = session

    private inner class SessionCallback : MediaSession.Callback {
        override fun onConnect(session: MediaSession, controller: MediaSession.ControllerInfo):
            MediaSession.ConnectionResult =
            if (controller.isTrusted || controller.packageName == packageName ||
                session.isMediaNotificationController(controller)) {
                MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                    .setAvailablePlayerCommands(MediaSession.ConnectionResult.DEFAULT_PLAYER_COMMANDS.buildUpon()
                        .remove(Player.COMMAND_SET_MEDIA_ITEM)
                        .remove(Player.COMMAND_CHANGE_MEDIA_ITEMS)
                        .build())
                    .build()
            } else MediaSession.ConnectionResult.reject()

        @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
        override fun onPlayerCommandRequest(session: MediaSession, controller: MediaSession.ControllerInfo, command: Int): Int {
            if (command == Player.COMMAND_STOP) {
                stopPlayback()
                return SessionResult.RESULT_ERROR_NOT_SUPPORTED
            }
            if ((pendingResume > 0L || resumeCandidate > 5000L) && command == Player.COMMAND_PLAY_PAUSE) {
                return SessionResult.RESULT_ERROR_NOT_SUPPORTED
            }
            return SessionResult.RESULT_SUCCESS
        }

        override fun onPlaybackResumption(
            mediaSession: MediaSession, controller: MediaSession.ControllerInfo, isForPlayback: Boolean
        ): ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
            val last = saved.lastMusic() ?: return Futures.immediateFailedFuture(
                IllegalStateException("Không có nhạc đang nghe dở")
            )
            if (isForPlayback) {
                video = false
                backgroundAudio = false
                player.setPauseAtEndOfMediaItems(false)
                audioAttributes()
                player.repeatMode = saved.repeat
                player.shuffleModeEnabled = saved.shuffle
                player.setPlaybackSpeed(saved.speed(false))
                rememberedQueue = true
            }
            return Futures.immediateFuture(
                MediaSession.MediaItemsWithStartPosition(last.paths.map(::mediaItem), last.index, last.position)
            )
        }
    }

    private fun audioAttributes() {
        player.setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA)
            .setContentType(if (video) C.AUDIO_CONTENT_TYPE_MOVIE else C.AUDIO_CONTENT_TYPE_MUSIC)
            .build(), true)
    }

    private fun parseTree(path: String): Pair<Uri, List<String>> {
        val parts = path.removePrefix(TREE_PREFIX).split('/')
        val tree = Uri.parse(Uri.decode(parts.first()))
        val names = parts.drop(1)
        require(tree.authority == "com.android.externalstorage.documents" &&
                DocumentsContract.isTreeUri(tree) && names.isNotEmpty() &&
                names.none { it.isEmpty() || it == "." || it == ".." || it.indexOf('\u0000') >= 0 })
        return tree to names
    }

    private fun sourceUri(path: String): Uri {
        if (!path.startsWith(TREE_PREFIX)) {
            val file = File(path)
            if (!file.isAbsolute || !file.isFile) throw FileNotFoundException(path)
            return Uri.fromFile(file)
        }
        val (tree, names) = parseTree(path)
        if (contentResolver.persistedUriPermissions.none { it.uri == tree && it.isReadPermission }) {
            throw FileNotFoundException("Quyền đọc SD/USB đã bị thu hồi")
        }
        val root = DocumentsContract.getTreeDocumentId(tree)
        val relative = names.joinToString("/")
        val id = if (root.endsWith(':')) root + relative else "${root.trimEnd('/')}/$relative"
        return DocumentsContract.buildDocumentUriUsingTree(tree, id)
    }

    private fun mediaItem(path: String): MediaItem = MediaItem.Builder()
        .setMediaId(path)
        .setUri(Uri.Builder().scheme("fm-local").authority("playback").appendQueryParameter("path", path).build())
        .setMediaMetadata(MediaMetadata.Builder().setDisplayTitle(File(path).name).setIsPlayable(true).build())
        .build()

    internal fun open(paths: List<String>, index: Int, isVideo: Boolean, oldPositions: Map<String, Long>) {
        require(paths.isNotEmpty() && index in paths.indices && paths.all { it.startsWith("/") })
        if (currentPath == paths[index] && video == isVideo && error == null) return
        savePosition()
        changingQueue = true
        try {
            player.stop()
            video = isVideo
            backgroundAudio = false
            pausedByVisibility = false
            pendingResume = 0L
            error = null
            resumeCandidate = 0L
            legacyPositions = oldPositions
            val start = if (isVideo) C.TIME_UNSET else saved.musicPosition(paths[index])
            if (isVideo) resumeCandidate = videoPosition(paths[index])
            player.setPauseAtEndOfMediaItems(isVideo)
            player.repeatMode = if (isVideo) Player.REPEAT_MODE_OFF else saved.repeat
            player.shuffleModeEnabled = !isVideo && saved.shuffle
            player.setPlaybackSpeed(saved.speed(isVideo))
            audioAttributes()
            player.playWhenReady = !isVideo || resumeCandidate <= 5000L
            if (!isVideo) saved.saveQueue(paths)
            rememberedQueue = !isVideo
            player.setMediaItems(paths.map(::mediaItem), index, start)
            player.prepare()
        } finally {
            changingQueue = false
            currentChanged()
            updatePresentation()
            publish()
        }
    }

    private fun videoPosition(path: String) = saved.videoPosition(path) ?: legacyPositions[path] ?: 0L

    internal fun restoreMusic() {
        if (currentPath != null) {
            toggle()
            return
        }
        saved.lastMusic()?.let { open(it.paths, it.index, false, emptyMap()) }
    }

    internal fun resumeVideo(continueFromSaved: Boolean) {
        if (pendingResume == 0L) return
        val position = if (continueFromSaved) pendingResume else 0L
        pendingResume = 0L
        player.seekTo(position)
        player.play()
        publish()
    }

    internal fun select(index: Int) {
        if (index !in 0 until player.mediaItemCount) return
        savePosition()
        pendingResume = 0L
        error = null
        pausedByVisibility = false
        val path = player.getMediaItemAt(index).mediaId
        resumeCandidate = if (video) videoPosition(path) else 0L
        player.playWhenReady = resumeCandidate <= 5000L
        player.seekTo(index, 0L)
        if (player.playbackState == Player.STATE_IDLE) player.prepare()
        publish()
    }

    internal fun previous() {
        val index = player.previousMediaItemIndex
        if (index != C.INDEX_UNSET) select(index)
    }

    internal fun next() {
        val index = player.nextMediaItemIndex
        if (index != C.INDEX_UNSET) select(index)
    }

    internal fun toggle() {
        if (currentPath == null) {
            restoreMusic()
            return
        }
        if (pendingResume > 0L || resumeCandidate > 5000L) return
        if (player.playWhenReady && error == null && player.playbackState != Player.STATE_ENDED) {
            player.pause()
        } else {
            pausedByVisibility = false
            if (error != null || player.playbackState == Player.STATE_IDLE) {
                error = null
                player.prepare()
            } else if (player.playbackState == Player.STATE_ENDED) player.seekTo(0L)
            player.play()
        }
    }

    internal fun seek(position: Long) {
        if (pendingResume == 0L && currentPath != null) {
            player.seekTo(position.coerceIn(0L, duration))
            savePosition()
            publish()
        }
    }

    internal fun setSpeed(speed: Float) {
        if (speed !in 0.5f..2f) return
        player.setPlaybackSpeed(speed)
        saved.setSpeed(video, speed)
    }

    internal fun toggleShuffle() {
        if (video) return
        player.shuffleModeEnabled = !player.shuffleModeEnabled
        saved.shuffle = player.shuffleModeEnabled
    }

    internal fun cycleRepeat() {
        if (video) return
        player.repeatMode = when (player.repeatMode) {
            Player.REPEAT_MODE_OFF -> Player.REPEAT_MODE_ONE
            Player.REPEAT_MODE_ONE -> Player.REPEAT_MODE_ALL
            else -> Player.REPEAT_MODE_OFF
        }
        saved.repeat = player.repeatMode
    }

    internal fun toggleBackground() {
        if (!video) return
        backgroundAudio = !backgroundAudio
        updatePresentation()
        publish()
    }

    internal fun setPresentation(activity: Boolean, view: Boolean, inPip: Boolean) {
        activityVisible = activity
        viewVisible = view
        pip = inPip
        updatePresentation()
        if (!activity) savePosition()
        publish()
    }

    internal fun closesVideoWithView() = video && !backgroundAudio && !pip && currentPath != null

    private fun updatePresentation() {
        val visible = (activityVisible && viewVisible) || pip
        if (video && !visible && !backgroundAudio && player.playWhenReady) {
            pausedByVisibility = true
            player.pause()
        } else if (video && visible && pausedByVisibility) {
            pausedByVisibility = false
            if (error == null && pendingResume == 0L && resumeCandidate <= 5000L) player.play()
        }
        val disableVideo = video && !visible && backgroundAudio
        val tracks = player.trackSelectionParameters
        if (tracks.disabledTrackTypes.contains(C.TRACK_TYPE_VIDEO) != disableVideo) {
            player.trackSelectionParameters = tracks.buildUpon()
                .setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, disableVideo).build()
        }
    }

    internal fun attachTexture(view: TextureView?) {
        if (texture === view) return
        texture?.let(player::clearVideoTextureView)
        texture = view
        view?.let(player::setVideoTextureView)
    }

    internal fun stopPlayback() {
        savePosition()
        saved.dismissMusic()
        changingQueue = true
        try {
            player.pause()
            player.stop()
            player.clearMediaItems()
            pendingResume = 0L
            resumeCandidate = 0L
            pausedByVisibility = false
            backgroundAudio = false
            error = null
            rememberedQueue = false
        } finally {
            changingQueue = false
            currentChanged()
            publish()
        }
        stopSelf()
    }

    override fun onPositionDiscontinuity(old: Player.PositionInfo, new: Player.PositionInfo, reason: Int) {
        if (!changingQueue && video && old.mediaItem?.mediaId != new.mediaItem?.mediaId) {
            old.mediaItem?.mediaId?.let { saved.saveVideo(it, old.positionMs, previousDuration) }
        }
    }

    override fun onEvents(player: Player, events: Player.Events) {
        if (changingQueue) return
        if (events.contains(Player.EVENT_MEDIA_ITEM_TRANSITION)) {
            error = null
            currentChanged()
        }
        if (events.contains(Player.EVENT_PLAYBACK_STATE_CHANGED) && player.playbackState == Player.STATE_READY &&
            resumeCandidate > 0L) {
            val candidate = resumeCandidate
            resumeCandidate = 0L
            if (candidate > 5000L && candidate < duration - 5000L) pendingResume = candidate
            else if (!pausedByVisibility && (activityVisible && viewVisible || backgroundAudio || pip)) player.play()
        }
        if (events.contains(Player.EVENT_IS_PLAYING_CHANGED)) {
            handler.removeCallbacks(checkpoint)
            if (player.isPlaying) handler.postDelayed(checkpoint, 5000L) else savePosition()
        }
        if (events.contains(Player.EVENT_MEDIA_METADATA_CHANGED)) loadArtwork()
        previousDuration = duration
        if (events.containsAny(Player.EVENT_MEDIA_ITEM_TRANSITION, Player.EVENT_PLAYBACK_STATE_CHANGED,
                Player.EVENT_PLAY_WHEN_READY_CHANGED, Player.EVENT_POSITION_DISCONTINUITY)) {
            if (player.playbackState != Player.STATE_BUFFERING) savePosition()
        }
        publish()
    }

    override fun onPlayerError(exception: PlaybackException) {
        error = when {
            exception.errorCodeName.startsWith("ERROR_CODE_IO") ->
                "Không đọc được tệp. Tệp có thể đã bị xoá, đổi tên hoặc thiết bị lưu trữ đã ngắt kết nối."
            else -> "Không phát được tệp. Thiết bị có thể không hỗ trợ định dạng hoặc codec này."
        }
        pendingResume = 0L
        resumeCandidate = 0L
        player.pause()
        publish()
    }

    private fun sourceLost() {
        savePosition()
        error = "Tệp đã bị xoá, đổi tên hoặc thiết bị lưu trữ đã ngắt kết nối."
        pendingResume = 0L
        resumeCandidate = 0L
        player.pause()
        player.stop()
        publish()
    }

    private fun currentChanged() {
        fileWatch?.stopWatching()
        fileWatch = null
        watchedPath = currentPath
        artwork = null
        artworkBytes = null
        artworkGeneration++
        val path = currentPath
        if (path != null && !path.startsWith(TREE_PREFIX)) {
            val file = File(path)
            val parent = file.parentFile
            if (parent != null) {
                @Suppress("DEPRECATION")
                fileWatch = object : FileObserver(parent.absolutePath, DELETE or MOVED_FROM or DELETE_SELF or MOVE_SELF) {
                    override fun onEvent(event: Int, child: String?) {
                        if (child == null || child == file.name) handler.post {
                            if (watchedPath == path && !file.exists()) sourceLost()
                        }
                    }
                }.also { it.startWatching() }
            }
        }
        loadArtwork()
    }

    private fun loadArtwork() {
        val data = player.mediaMetadata.artworkData
        if (data === artworkBytes) return
        artworkBytes = data
        artwork = null
        val generation = ++artworkGeneration
        if (data == null || data.isEmpty() || data.size > 8 * 1024 * 1024) return
        artworkWorker.execute {
            val result = runCatching { cacheArtwork(File(filesDir, "fm-media-art"), data) }.getOrNull()
            handler.post {
                if (generation == artworkGeneration) {
                    artwork = result
                    publish()
                }
            }
        }
    }

    private fun savePosition() {
        val path = currentPath ?: return
        if (duration <= 0L || pendingResume > 0L || resumeCandidate > 5000L || error != null) return
        if (video) {
            saved.saveVideo(path, player.currentPosition, duration)
        } else if (rememberedQueue) {
            val position = if (player.playbackState == Player.STATE_ENDED) 0L else player.currentPosition
            saved.saveMusic(path, player.currentMediaItemIndex, position)
        }
    }

    internal fun observe(listener: () -> Unit) { listeners.add(listener) }
    internal fun removeObserver(listener: () -> Unit) { listeners.remove(listener) }
    private fun publish() { listeners.toList().forEach { it() } }

    internal fun queue(): List<String> = (0 until player.mediaItemCount).map { player.getMediaItemAt(it).mediaId }

    internal fun snapshot(): Map<String, Any?> {
        val path = currentPath
        val metadata = player.mediaMetadata
        val position = player.currentPosition
        val size = player.videoSize
        return mapOf(
            "path" to path, "index" to player.currentMediaItemIndex, "count" to player.mediaItemCount,
            "title" to (metadata.title?.toString()?.takeIf { it.isNotBlank() } ?: path?.let { File(it).name }),
            "artist" to metadata.artist?.toString(), "album" to metadata.albumTitle?.toString(), "artwork" to artwork,
            "position" to position, "duration" to duration, "speed" to player.playbackParameters.speed,
            "ready" to (player.playbackState == Player.STATE_READY || player.playbackState == Player.STATE_ENDED),
            "playing" to player.isPlaying, "wantsPlay" to (player.playWhenReady && player.playbackState != Player.STATE_ENDED),
            "video" to video, "background" to backgroundAudio, "pip" to pip,
            "width" to (size.width * size.pixelWidthHeightRatio).toInt(), "height" to size.height,
            "previous" to player.hasPreviousMediaItem(), "next" to player.hasNextMediaItem(),
            "shuffle" to player.shuffleModeEnabled, "repeat" to player.repeatMode,
            "resume" to pendingResume, "error" to error,
            "lastMusic" to if (path == null) saved.offeredMusicName() else null
        )
    }

    override fun onDestroy() {
        savePosition()
        unregisterReceiver(mountedMedia)
        fileWatch?.stopWatching()
        artworkGeneration++
        artworkWorker.shutdownNow()
        handler.removeCallbacksAndMessages(null)
        attachTexture(null)
        player.removeListener(this)
        removeSession(session)
        session.release()
        player.release()
        super.onDestroy()
    }
}

private class PlaybackPreferences(private val prefs: SharedPreferences) {
    data class Music(val paths: List<String>, val index: Int, val position: Long)

    var shuffle: Boolean
        get() = prefs.getBoolean("shuffle", false)
        set(value) { prefs.edit().putBoolean("shuffle", value).apply() }
    var repeat: Int
        get() = prefs.getInt("repeat", Player.REPEAT_MODE_OFF)
        set(value) { prefs.edit().putInt("repeat", value).apply() }

    fun speed(video: Boolean) = prefs.getFloat(if (video) "video_speed" else "music_speed", 1f)
    fun setSpeed(video: Boolean, speed: Float) =
        prefs.edit().putFloat(if (video) "video_speed" else "music_speed", speed).apply()

    fun musicPosition(path: String): Long =
        if (prefs.getString("music_path", null) == path) prefs.getLong("music_pos", 0L) else 0L

    fun saveQueue(paths: List<String>) { prefs.edit().putString("queue", JSONArray(paths).toString()).apply() }

    fun saveMusic(path: String, index: Int, position: Long) {
        prefs.edit().putString("music_path", path).putInt("music_index", index)
            .putLong("music_pos", position).putBoolean("offer", true).apply()
    }

    fun offeredMusicName(): String? =
        if (prefs.getBoolean("offer", false)) prefs.getString("music_path", null)?.let { File(it).name } else null

    fun lastMusic(): Music? {
        if (!prefs.getBoolean("offer", false)) return null
        val path = prefs.getString("music_path", null) ?: return null
        val array = runCatching { JSONArray(prefs.getString("queue", "[]")) }.getOrNull()
        val paths = array?.let { List(it.length()) { index -> it.optString(index) } }.orEmpty()
        val index = prefs.getInt("music_index", -1)
        val at = if (paths.getOrNull(index) == path) index else paths.indexOf(path)
        return if (at >= 0) Music(paths, at, musicPosition(path))
        else Music(listOf(path), 0, musicPosition(path))
    }

    fun dismissMusic() { prefs.edit().putBoolean("offer", false).apply() }

    // A zero entry suppresses an obsolete pre-upgrade Dart bookmark.
    fun videoPosition(path: String): Long? = if (prefs.contains("video:$path")) prefs.getLong("video:$path", 0L) else null

    fun saveVideo(path: String, position: Long, duration: Long) {
        if (duration <= 0L) return
        val order = runCatching { JSONArray(prefs.getString("video_order", "[]")) }.getOrDefault(JSONArray())
        val keys = (0 until order.length()).map(order::optString).filter { it != path } + path
        val editor = prefs.edit()
        keys.dropLast(100).forEach { editor.remove("video:$it") }
        editor.putString("video_order", JSONArray(keys.takeLast(100)).toString())
            .putLong("video:$path", if (position > 5000L && position < duration - 5000L) position else 0L)
            .apply()
    }
}

private fun cacheArtwork(directory: File, data: ByteArray): String {
    val id = MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    directory.mkdirs()
    val file = File(directory, "$id.img")
    if (!file.isFile) {
        val pending = File(directory, "$id.new")
        try {
            pending.writeBytes(data)
            check(pending.renameTo(file))
        } finally {
            pending.delete()
        }
    }
    file.setLastModified(System.currentTimeMillis())
    var total = 0L
    directory.listFiles()?.filter { it.isFile && it.name.endsWith(".img") }
        ?.sortedByDescending { it.lastModified() }?.forEachIndexed { index, entry ->
            total += entry.length()
            if (entry != file && (index >= 64 || total > 32L * 1024 * 1024)) entry.delete()
        }
    return file.absolutePath
}
