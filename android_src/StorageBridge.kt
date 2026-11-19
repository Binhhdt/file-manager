package com.fmdemo.file_manager

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.Cursor
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.os.StatFs
import android.os.storage.StorageManager
import android.os.storage.StorageVolume
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.util.Size
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.InputStream
import java.util.Locale
import java.util.concurrent.Executors

internal class StorageBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private companion object {
        const val CHANNEL = "fm/storage"
        const val AUTHORITY = "com.android.externalstorage.documents"
        const val PREFIX = "/@saf/"
        const val PICK_TREE = 5812
        const val CHUNK = 512 * 1024
        val columns = arrayOf(
            Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED, Document.COLUMN_FLAGS
        )
    }

    private class Offline : IllegalStateException("Thiết bị lưu trữ đã ngắt kết nối")
    private val channel = MethodChannel(messenger, CHANNEL)
    private val resolver = activity.contentResolver
    private val manager = activity.getSystemService(Context.STORAGE_SERVICE) as StorageManager
    private val worker = Executors.newSingleThreadExecutor()
    private var picker: MethodChannel.Result? = null

    private data class Handle(
        val input: InputStream? = null,
        val output: ParcelFileDescriptor.AutoCloseOutputStream? = null
    ) {
        fun close() {
            input?.close()
            output?.close()
        }
    }

    private val handles = HashMap<Int, Handle>()
    private var nextHandle = 1

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            channel.invokeMethod("changed", null)
        }
    }

    init {
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_MEDIA_MOUNTED)
            addAction(Intent.ACTION_MEDIA_UNMOUNTED)
            addAction(Intent.ACTION_MEDIA_EJECT)
            addAction(Intent.ACTION_MEDIA_REMOVED)
            addAction(Intent.ACTION_MEDIA_BAD_REMOVAL)
            addDataScheme("file")
        }
        if (Build.VERSION.SDK_INT >= 33) activity.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else @Suppress("DEPRECATION") activity.registerReceiver(receiver, filter)
        channel.setMethodCallHandler { call, result ->
            if (call.method == "grant") {
                chooseTree(call.argument<String>("id"), result)
                return@setMethodCallHandler
            }
            if (call.method == "open") {
                try {
                    val path = requireNotNull(call.argument<String>("path"))
                    worker.execute {
                        try {
                            val node = resolve(path) ?: throw FileNotFoundException(path)
                            val uri = documentUri(tree(path).uri, node.id)
                            activity.runOnUiThread {
                                try {
                                    val intent = Intent(Intent.ACTION_VIEW).apply {
                                        setDataAndType(uri, node.mime)
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    }
                                    activity.startActivity(intent)
                                    result.success(true)
                                } catch (error: Exception) {
                                    fail(result, error)
                                }
                            }
                        } catch (error: Exception) {
                            activity.runOnUiThread { fail(result, error) }
                        }
                    }
                } catch (error: Exception) {
                    fail(result, error)
                }
                return@setMethodCallHandler
            }
            worker.execute {
                try {
                    fun path() = requireNotNull(call.argument<String>("path"))
                    fun handle() = handles.getValue(requireNotNull(call.argument<Int>("handle")))
                    val value: Any? = when (call.method) {
                        "volumes" -> volumes()
                        "privateDir" -> activity.filesDir.absolutePath
                        "available" -> { ensureAvailable(path()); null }
                        "identity" -> identity(path())
                        "fileIdentity" -> try {
                            val node = Os.lstat(path())
                            "${node.st_dev}:${node.st_ino}"
                        } catch (_: android.system.ErrnoException) {
                            null
                        }
                        "sameDevice" -> {
                            val from = path()
                            val to = requireNotNull(call.argument<String>("to"))
                            ensureAvailable(from)
                            ensureAvailable(to)
                            Os.stat(File(from).parent).st_dev == Os.stat(File(to).parent).st_dev
                        }
                        "stat" -> resolve(path())?.data()
                        "list" -> list(path()).map(Node::data)
                        "mkdir" -> { create(path(), Document.MIME_TYPE_DIR); null }
                        "rename" -> { rename(path(), requireNotNull(call.argument<String>("to"))); null }
                        "delete" -> { delete(path()); null }
                        "streamOpen" -> openStream(path(), call.argument<Boolean>("write") == true)
                        "streamRead" -> read(requireNotNull(handle().input))
                        "streamWrite" -> {
                            requireNotNull(handle().output).write(requireNotNull(call.argument<ByteArray>("bytes")))
                            null
                        }
                        "streamFlush" -> {
                            requireNotNull(handle().output).apply {
                                flush()
                                fd.sync()
                            }
                            null
                        }
                        "streamClose" -> { handles.remove(call.argument<Int>("handle"))?.close(); null }
                        else -> {
                            activity.runOnUiThread { result.notImplemented() }
                            return@execute
                        }
                    }
                    activity.runOnUiThread { result.success(value) }
                } catch (error: Exception) {
                    activity.runOnUiThread { fail(result, error) }
                }
            }
        }
    }

    fun close() {
        activity.unregisterReceiver(receiver)
        picker?.success(null)
        picker = null
        channel.setMethodCallHandler(null)
        worker.execute {
            handles.values.forEach { runCatching { it.close() } }
            handles.clear()
        }
        worker.shutdown()
    }

    private fun fail(result: MethodChannel.Result, error: Exception) {
        val causes = generateSequence<Throwable>(error) { it.cause }.take(8).toList()
        val errno = causes.filterIsInstance<ErrnoException>().firstOrNull()?.errno
        val message = causes.mapNotNull { it.message }.joinToString(" ")
        val code = when {
            causes.any { it is Offline } || errno == OsConstants.ENODEV -> "offline"
            errno == OsConstants.ENOSPC || errno == OsConstants.EDQUOT ||
                message.contains("ENOSPC") || message.contains("EDQUOT") -> "space"
            causes.any { it is SecurityException } || errno == OsConstants.EACCES ||
                errno == OsConstants.EROFS || message.contains("EACCES") ||
                message.contains("EROFS") || message.contains("EPERM") -> "permission"
            else -> "storage"
        }
        result.error(code, error.message ?: error.javaClass.simpleName, null)
    }

    private fun mounted(volume: StorageVolume) =
        volume.state == Environment.MEDIA_MOUNTED || volume.state == Environment.MEDIA_MOUNTED_READ_ONLY

    private fun removable(): List<StorageVolume> =
        if (Build.VERSION.SDK_INT >= 24) manager.storageVolumes.filter { !it.isPrimary && mounted(it) }
        else emptyList()

    private fun root(volume: StorageVolume): File? {
        if (Build.VERSION.SDK_INT >= 30) return volume.directory
        val uuid = volume.uuid ?: return null
        return activity.getExternalFilesDirs(null).filterNotNull().mapNotNull { dir ->
            val prefix = dir.absolutePath.substringBefore("/Android/", "")
            if (prefix.isEmpty()) null else File(prefix)
        }.firstOrNull { it.name.equals(uuid, ignoreCase = true) }
    }

    private fun volumeId(volume: StorageVolume) = volume.uuid ?: root(volume)?.name

    private fun mountFor(id: String) = removable().firstOrNull { volumeId(it).equals(id, ignoreCase = true) }

    private fun capacity(root: File?, uri: Uri? = null): Pair<Long, Long> {
        if (root != null) {
            val stats = runCatching { StatFs(root.absolutePath) }.getOrNull()
            if (stats != null) return stats.totalBytes to stats.availableBytes
        }
        if (uri != null) {
            val id = DocumentsContract.getTreeDocumentId(uri).substringBefore(':')
            val roots = DocumentsContract.buildRootsUri(AUTHORITY)
            runCatching {
                resolver.query(roots, arrayOf(
                    DocumentsContract.Root.COLUMN_ROOT_ID, DocumentsContract.Root.COLUMN_CAPACITY_BYTES,
                    DocumentsContract.Root.COLUMN_AVAILABLE_BYTES
                ), null, null, null)?.use { cursor ->
                    while (cursor.moveToNext()) {
                        if (cursor.getString(0).equals(id, ignoreCase = true)) {
                            return cursor.getLong(1) to cursor.getLong(2)
                        }
                    }
                }
            }
        }
        return 0L to 0L
    }

    private fun treePath(uri: Uri) = PREFIX + Uri.encode(uri.toString())

    private fun volumes(): List<Map<String, Any?>> {
        val results = ArrayList<Map<String, Any?>>()
        for (volume in removable()) {
            val id = volumeId(volume) ?: continue
            val folder = root(volume)
            val direct = folder?.takeIf { it.list() != null }
            val (total, free) = capacity(folder)
            results.add(mapOf(
                "id" to id, "label" to volume.getDescription(activity), "path" to direct?.absolutePath,
                "directRoot" to folder?.absolutePath, "total" to total, "free" to free,
                "writable" to (volume.state == Environment.MEDIA_MOUNTED && direct?.canWrite() == true)
            ))
        }
        for (grant in resolver.persistedUriPermissions) {
            if (!grant.isReadPermission || grant.uri.authority != AUTHORITY || !DocumentsContract.isTreeUri(grant.uri)) continue
            val id = DocumentsContract.getTreeDocumentId(grant.uri)
            val volume = mountFor(id.substringBefore(':')) ?: continue
            val node = runCatching { queryDocument(grant.uri, id) }.getOrNull() ?: continue
            val (total, free) = capacity(root(volume), grant.uri)
            results.add(mapOf(
                "id" to id.substringBefore(':'), "label" to "${volume.getDescription(activity)} · ${node.name}",
                "path" to treePath(grant.uri), "directRoot" to null, "total" to total, "free" to free,
                "writable" to (grant.isWritePermission && volume.state == Environment.MEDIA_MOUNTED)
            ))
        }
        return results
    }

    private fun chooseTree(id: String?, result: MethodChannel.Result) {
        if (picker != null) {
            result.error("storage", "Đang chờ chọn thư mục", null)
            return
        }
        try {
            val volume = id?.let(::mountFor)
            val intent = if (Build.VERSION.SDK_INT >= 29 && volume != null) volume.createOpenDocumentTreeIntent()
                else Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            picker = result
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, PICK_TREE)
        } catch (error: Exception) {
            picker = null
            fail(result, error)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_TREE) return false
        val result = picker ?: return true
        picker = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        try {
            if (uri.authority != AUTHORITY || !DocumentsContract.isTreeUri(uri)) {
                throw SecurityException("Hãy chọn thư mục trên SD/USB trong trình chọn của Android")
            }
            val id = DocumentsContract.getTreeDocumentId(uri).substringBefore(':')
            if (mountFor(id) == null) throw SecurityException("Hãy chọn thư mục trên SD/USB đang kết nối")
            val modes = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            resolver.takePersistableUriPermission(uri, modes)
            result.success(treePath(uri))
            channel.invokeMethod("changed", null)
        } catch (error: Exception) {
            fail(result, error)
        }
        return true
    }

    private data class Tree(val uri: Uri, val id: String, val parts: List<String>, val writable: Boolean)

    private fun tree(path: String, writing: Boolean = false): Tree {
        require(path.startsWith(PREFIX))
        val parts = path.removePrefix(PREFIX).split('/')
        val uri = Uri.parse(Uri.decode(parts.first()))
        require(uri.authority == AUTHORITY && DocumentsContract.isTreeUri(uri))
        val id = DocumentsContract.getTreeDocumentId(uri)
        val volume = mountFor(id.substringBefore(':')) ?: throw Offline()
        val permission = resolver.persistedUriPermissions.firstOrNull { it.uri == uri && it.isReadPermission }
            ?: throw SecurityException("Quyền thư mục SD/USB đã bị thu hồi")
        val writable = permission.isWritePermission && volume.state == Environment.MEDIA_MOUNTED
        if (writing && !writable) throw SecurityException("Thiết bị hoặc thư mục chỉ cho phép đọc")
        val names = parts.drop(1)
        require(names.none { it.isEmpty() || it == "." || it == ".." || it.indexOf('\u0000') >= 0 })
        return Tree(uri, id, names, writable)
    }

    private fun ensureAvailable(path: String) {
        if (path.startsWith(PREFIX)) {
            val info = tree(path)
            if (queryDocument(info.uri, info.id) == null) throw FileNotFoundException("Thư mục được cấp quyền không còn tồn tại")
        } else if (path.startsWith("/storage/") &&
            path != "/storage/emulated/0" && !path.startsWith("/storage/emulated/0/")) {
            if (removable().none {
                root(it)?.absolutePath?.let { mount -> path == mount || path.startsWith("$mount/") } == true
            }) throw Offline()
        }
    }

    private fun identity(path: String): String {
        if (!path.startsWith(PREFIX)) return path
        val tree = tree(path)
        val id = tree.id.substringBefore(':')
        val volume = mountFor(id) ?: throw Offline()
        val base = root(volume)?.absolutePath ?: "/storage/$id"
        return (listOf(base, tree.id.substringAfter(':', "")) + tree.parts).filter(String::isNotEmpty).joinToString("/")
    }

    private data class Node(val id: String, val name: String, val mime: String, val size: Long, val modified: Long) {
        val directory: Boolean get() = mime == Document.MIME_TYPE_DIR
        fun data() = mapOf("id" to id, "name" to name, "dir" to directory, "size" to size, "modified" to modified)
    }

    private fun node(cursor: Cursor) = Node(
        cursor.getString(0), cursor.getString(1), cursor.getString(2),
        if (cursor.isNull(3)) -1L else cursor.getLong(3),
        if (cursor.isNull(4)) 0L else cursor.getLong(4)
    )

    private fun documentUri(uri: Uri, id: String) = DocumentsContract.buildDocumentUriUsingTree(uri, id)

    private fun queryDocument(uri: Uri, id: String): Node? =
        resolver.query(documentUri(uri, id), columns, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) node(cursor) else null
        }

    private fun children(uri: Uri, parent: String): List<Node> {
        val listUri = DocumentsContract.buildChildDocumentsUriUsingTree(uri, parent)
        return resolver.query(listUri, columns, null, null, null)?.use { cursor ->
            buildList { while (cursor.moveToNext()) add(node(cursor)) }
        } ?: throw FileNotFoundException("Không đọc được thư mục SD/USB")
    }

    private fun find(nodes: List<Node>, name: String) = nodes.firstOrNull { it.name == name }
        ?: nodes.singleOrNull { it.name.equals(name, ignoreCase = true) }

    private fun resolve(info: Tree, parts: List<String> = info.parts): Node? {
        var current = queryDocument(info.uri, info.id)
            ?: throw FileNotFoundException("Thư mục được cấp quyền không còn tồn tại")
        for (name in parts) {
            if (!current.directory) return null
            current = find(children(info.uri, current.id), name) ?: return null
        }
        return current
    }

    private fun resolve(path: String): Node? = resolve(tree(path))

    private fun list(path: String): List<Node> {
        val info = tree(path)
        val dir = resolve(info) ?: throw FileNotFoundException(path)
        require(dir.directory)
        return children(info.uri, dir.id)
    }

    private fun create(path: String, mime: String): Uri {
        val info = tree(path, writing = true)
        val name = info.parts.lastOrNull() ?: throw SecurityException("Không thể ghi đè thư mục được cấp quyền")
        val dir = resolve(info, info.parts.dropLast(1)) ?: throw FileNotFoundException(path)
        if (find(children(info.uri, dir.id), name) != null) throw IllegalStateException("Tên đã tồn tại: $name")
        val uri = DocumentsContract.createDocument(resolver, documentUri(info.uri, dir.id), mime, name)
            ?: throw IllegalStateException("Android không tạo được $name")
        if (queryDocument(info.uri, DocumentsContract.getDocumentId(uri))?.name != name) {
            DocumentsContract.deleteDocument(resolver, uri)
            throw IllegalStateException("Android không chấp nhận tên $name")
        }
        return uri
    }

    private fun rename(path: String, destination: String) {
        val sourceTree = tree(path, writing = true)
        val targetTree = tree(destination, writing = true)
        require(sourceTree.uri == targetTree.uri && sourceTree.parts.dropLast(1) == targetTree.parts.dropLast(1))
        if (sourceTree.parts.isEmpty() || targetTree.parts.isEmpty()) throw SecurityException("Không thể đổi tên thư mục được cấp quyền")
        val source = resolve(sourceTree) ?: throw FileNotFoundException(path)
        val name = targetTree.parts.last()
        if (resolve(targetTree) != null) throw IllegalStateException("Tên đã tồn tại: $name")
        val uri = DocumentsContract.renameDocument(resolver, documentUri(sourceTree.uri, source.id), name)
            ?: throw IllegalStateException("Android không đổi tên được $name")
        if (queryDocument(sourceTree.uri, DocumentsContract.getDocumentId(uri))?.name != name) {
            DocumentsContract.renameDocument(resolver, uri, source.name)
            throw IllegalStateException("Android không chấp nhận tên $name")
        }
    }

    private fun delete(path: String) {
        val info = tree(path, writing = true)
        if (info.parts.isEmpty()) throw SecurityException("Không thể xoá thư mục được cấp quyền")
        val item = resolve(info) ?: return
        if (!DocumentsContract.deleteDocument(resolver, documentUri(info.uri, item.id))) {
            throw IllegalStateException("Android không xoá được ${item.name}")
        }
    }

    // Called by the bounded thumbnail queue, independently of file transfers.
    fun preview(method: String, path: String, destination: String): Any {
        val info = tree(path)
        val item = resolve(info) ?: throw FileNotFoundException(path)
        val uri = documentUri(info.uri, item.id)
        if (method == "documentDuration") {
            val reader = MediaMetadataRetriever()
            try {
                reader.setDataSource(activity, uri)
                return reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            } finally {
                reader.release()
            }
        }
        if (Build.VERSION.SDK_INT < 29) return false
        val bitmap = resolver.loadThumbnail(uri, Size(384, 384), null)
        try {
            return FileOutputStream(destination).use {
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
            }
        } finally {
            bitmap.recycle()
        }
    }

    private fun openStream(path: String, write: Boolean): Int {
        val handle = if (write) {
            val ext = path.substringAfterLast('/').substringAfterLast('.', "").lowercase(Locale.ROOT)
            val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
            val uri = create(path, mime)
            val descriptor = resolver.openFileDescriptor(uri, "w") ?: throw FileNotFoundException(path)
            Handle(output = ParcelFileDescriptor.AutoCloseOutputStream(descriptor))
        } else {
            val info = tree(path)
            val item = resolve(info) ?: throw FileNotFoundException(path)
            val input = resolver.openInputStream(documentUri(info.uri, item.id)) ?: throw FileNotFoundException(path)
            Handle(input = input)
        }
        val id = nextHandle++
        handles[id] = handle
        return id
    }

    private fun read(input: InputStream): ByteArray {
        val bytes = ByteArray(CHUNK)
        var offset = 0
        while (offset < bytes.size) {
            val count = input.read(bytes, offset, bytes.size - offset)
            if (count <= 0) break
            offset += count
        }
        return if (offset == bytes.size) bytes else bytes.copyOf(offset)
    }
}
