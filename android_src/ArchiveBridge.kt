package com.fmdemo.file_manager

import android.app.Activity
import android.os.StatFs
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import me.zhanghai.android.libarchive.Archive
import me.zhanghai.android.libarchive.ArchiveEntry
import org.apache.commons.compress.archivers.sevenz.SevenZFile
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

internal class ArchiveBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "fm/archive")
    private val worker = Executors.newSingleThreadExecutor()
    private val requests = ConcurrentHashMap<String, AtomicBoolean>()

    init {
        channel.setMethodCallHandler { call, result ->
            val id = call.argument<String>("id")
            if (id == null) {
                result.error("archive", "Thiếu mã thao tác", null)
                return@setMethodCallHandler
            }
            if (call.method == "cancel") {
                requests[id]?.set(true)
                result.success(null)
                return@setMethodCallHandler
            }
            if (call.method != "list" && call.method != "extract") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val cancel = AtomicBoolean(false)
            if (requests.putIfAbsent(id, cancel) != null) {
                result.error("archive", "Thao tác đang chạy", null)
                return@setMethodCallHandler
            }
            worker.execute {
                val password = call.argument<String>("password")
                try {
                    val path = File(requireNotNull(call.argument<String>("path")))
                    if (!path.isFile) throw IOException("Không đọc được tập tin nén")
                    val destination = call.argument<String>("destination")?.let(::File)
                    if (destination != null) {
                        val root = activity.cacheDir.canonicalPath + File.separator
                        require(destination.canonicalPath.startsWith(root) &&
                            destination.isDirectory && destination.list()?.isEmpty() == true)
                    }
                    val selected = call.argument<List<Int>>("indices")?.toSet()
                    val details = inspect(path, password, destination, selected, cancel) { count ->
                        activity.runOnUiThread { channel.invokeMethod("progress", mapOf("id" to id, "bytes" to count)) }
                    }
                    activity.runOnUiThread { result.success(details) }
                } catch (error: Exception) {
                    val message = error.message.orEmpty()
                    val kind = when {
                        cancel.get() -> "cancel"
                        message.contains("unsupported", true) ||
                            message.contains("not supported", true) -> "unsupported"
                        message.contains("password", true) || message.contains("passphrase", true) ||
                            (password == null && message.contains("encrypt", true)) -> "password"
                        message.contains("ENOSPC", true) || message.contains("No space", true) -> "space"
                        else -> "archive"
                    }
                    activity.runOnUiThread { result.error(kind, message.ifEmpty { "Không đọc được tập tin nén" }, null) }
                } finally {
                    requests.remove(id)
                }
            }
        }
    }

    fun close() {
        channel.setMethodCallHandler(null)
        requests.values.forEach { it.set(true) }
        worker.shutdown()
    }

    private data class Entry(val name: String, val size: Long, val directory: Boolean,
        val encrypted: Boolean = false, val link: Boolean = false)

    private interface Reader : Closeable {
        fun next(): Entry?
        fun read(bytes: ByteArray): Int
    }

    private class NativeReader(path: File, password: String?) : Reader {
        private val handle = Archive.readNew()

        init {
            try {
                for (format in intArrayOf(Archive.FORMAT_ZIP, Archive.FORMAT_TAR,
                    Archive.FORMAT_RAR, Archive.FORMAT_RAR_V5)) {
                    Archive.readSupportFormatByCode(handle, format)
                }
                Archive.readSupportFilterByCode(handle, Archive.FILTER_NONE)
                Archive.readSupportFilterByCode(handle, Archive.FILTER_GZIP)
                if (password != null) Archive.readAddPassphrase(handle, password.toByteArray())
                Archive.readOpenFileName(handle, path.path.toByteArray(), 128 * 1024L)
            } catch (error: Exception) {
                Archive.free(handle)
                throw error
            }
        }

        override fun next(): Entry? {
            val entry = Archive.readNextHeader(handle)
            if (entry == 0L) return null
            val type = ArchiveEntry.filetype(entry)
            val name = ArchiveEntry.pathnameUtf8(entry)
                ?: ArchiveEntry.pathname(entry)?.toString(Charsets.UTF_8)
                ?: throw IOException("Tên trong tập tin nén bị lỗi")
            if ('\uFFFD' in name) throw IOException("Bảng mã tên trong tập tin nén không được hỗ trợ")
            return Entry(name, if (ArchiveEntry.sizeIsSet(entry)) ArchiveEntry.size(entry) else -1L,
                type == ArchiveEntry.AE_IFDIR, ArchiveEntry.isEncrypted(entry),
                ArchiveEntry.hardlinkIsSet(entry) ||
                    type !in setOf(ArchiveEntry.AE_IFREG, ArchiveEntry.AE_IFDIR))
        }

        override fun read(bytes: ByteArray): Int {
            val buffer = ByteBuffer.wrap(bytes)
            Archive.readData(handle, buffer)
            return buffer.position()
        }

        override fun close() = Archive.free(handle)
    }

    private class SevenReader(path: File, password: String?) : Reader {
        private val file = SevenZFile.builder()
            .setSeekableByteChannel(RandomAccessFile(path, "r").channel)
            .setDefaultName(path.name)
            .setMaxMemoryLimitKiB(128 * 1024).setTryToRecoverBrokenArchives(false)
            .apply { if (password != null) setPassword(password) }.get()

        override fun next(): Entry? {
            val item = file.nextEntry ?: return null
            val attrs = item.windowsAttributes
            val mode = (attrs ushr 16) and 0xF000
            return Entry(item.name ?: throw IOException("Tên trong tập tin 7Z bị lỗi"),
                item.size, item.isDirectory,
                link = item.isAntiItem || (attrs and 0x400) != 0 ||
                    mode !in setOf(0, 0x4000, 0x8000))
        }

        override fun read(bytes: ByteArray) = file.read(bytes)
        override fun close() = file.close()
    }

    private fun relativePath(entry: Entry): String? {
        if (entry.link) throw IOException("Tập tin nén chứa liên kết hoặc mục đặc biệt")
        var name = entry.name.replace('\\', '/')
        if (name.startsWith('/') || Regex("^[A-Za-z]:").containsMatchIn(name)) {
            throw IOException("Tập tin nén chứa đường dẫn tuyệt đối")
        }
        while (name.startsWith("./")) name = name.substring(2)
        if (entry.directory) name = name.trimEnd('/')
        if (entry.directory && (name.isEmpty() || name == ".")) return null
        val parts = name.split('/')
        if (parts.size > 64 || name.length > 4096 || parts.any {
            it.isEmpty() || it == "." || it == ".." ||
                it.any { char -> char.code < 32 || char.code == 127 } ||
                it.equals(".fmtrash", true) || it.startsWith(".fm-transaction-", true) ||
                it.equals(".fmvault", true)
        }) throw IOException("Tập tin nén chứa đường dẫn không an toàn")
        return name
    }

    private fun inspect(path: File, password: String?, folder: File?, indices: Set<Int>?,
        cancelled: AtomicBoolean, update: (Long) -> Unit): List<Map<String, Any>> {
        val limit = 32L * 1024 * 1024 * 1024
        val space = folder?.let { StatFs(it.path).availableBytes }
        val facts = ArrayList<Map<String, Any>>()
        val seen = HashMap<String, Boolean>()
        val bytes = ByteArray(128 * 1024)
        val source: Reader = if (path.extension.equals("7z", true)) {
            SevenReader(path, password)
        } else NativeReader(path, password)
        var written = 0L
        var declared = 0L
        var last = 0L
        var index = 0
        var completed = 0
        var pathCharacters = 0
        source.use { reader ->
            while (true) {
                if (cancelled.get()) throw IOException("Đã huỷ")
                val entry = reader.next() ?: break
                if (index >= 50000) throw IOException("Tập tin nén có hơn 50.000 mục")
                val number = index++
                val name = relativePath(entry) ?: continue
                pathCharacters += name.length
                if (pathCharacters > 4_000_000) throw IOException("Mục lục tập tin nén quá lớn")
                val normalized = name.lowercase(Locale.ROOT)
                if (seen.put(normalized, entry.directory)?.let { !it || !entry.directory } == true) {
                    throw IOException("Tập tin nén chứa tên trùng: $name")
                }
                var parent = normalized.substringBeforeLast('/', "")
                while (parent.isNotEmpty()) {
                    if (seen.putIfAbsent(parent, true) == false) {
                        throw IOException("Đường dẫn trùng với tập tin: $name")
                    }
                    parent = parent.substringBeforeLast('/', "")
                }
                if (!entry.directory && entry.size > 0) {
                    if (entry.size > limit - declared) throw IOException("Vượt giới hạn 32 GiB giải nén")
                    declared += entry.size
                }
                if (folder == null) {
                    facts.add(mapOf("index" to number, "name" to name, "size" to entry.size,
                        "directory" to entry.directory, "encrypted" to entry.encrypted))
                    continue
                }
                if (indices != null && number !in indices) continue
                val output = File(folder, name)
                if (entry.directory) {
                    if (!output.isDirectory && !output.mkdirs()) throw IOException("Không tạo được thư mục $name")
                } else {
                    if (entry.encrypted && password == null) throw IOException("Password required")
                    if (entry.size >= 0 && space != null && entry.size > space - written) {
                        throw IOException("No space left")
                    }
                    val dir = requireNotNull(output.parentFile)
                    if ((!dir.isDirectory && !dir.mkdirs()) || !output.createNewFile()) {
                        throw IOException("Không tạo được tập tin $name")
                    }
                    var count = 0L
                    FileOutputStream(output).use { stream ->
                        while (true) {
                            if (cancelled.get()) throw IOException("Đã huỷ")
                            val length = reader.read(bytes)
                            if (length <= 0) break
                            if (length > limit - written || (entry.size >= 0 && length > entry.size - count)) {
                                throw IOException("Dữ liệu giải nén vượt quá giới hạn")
                            }
                            if (space != null && length > space - written) throw IOException("No space left")
                            stream.write(bytes, 0, length)
                            count += length
                            written += length
                            val now = SystemClock.elapsedRealtime()
                            if (now - last >= 180L) {
                                update(written)
                                last = now
                            }
                        }
                        stream.fd.sync()
                    }
                    if (entry.size >= 0 && count != entry.size) throw IOException("Tập tin nén thiếu dữ liệu: $name")
                }
                completed++
            }
        }
        if (folder != null) {
            if (completed == 0 || (indices != null && completed != indices.size)) {
                throw IOException("Danh sách tập tin nén đã thay đổi")
            }
            update(written)
        }
        return facts
    }
}
