import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

const safPrefix = '/@saf/';
const transactionPrefix = '.fm-transaction-';
const storageChannel = MethodChannel('fm/storage');

bool isSaf(String path) => path.startsWith(safPrefix);
String storageDisplayPath(String path) {
  if (!isSaf(path))
    return path.replaceFirst('/storage/emulated/0', 'Bộ nhớ trong');
  final parts = path.substring(safPrefix.length).split('/');
  final tree = Uri.parse(Uri.decodeComponent(parts.first));
  final id = tree.pathSegments.last;
  final split = id.indexOf(':');
  final label =
      split < 0 ? id : '${id.substring(0, split)}/${id.substring(split + 1)}';
  return [label.replaceFirst(RegExp(r'/$'), ''), ...parts.skip(1)].join('/');
}

String storageDisplayName(String path) => p.basename(storageDisplayPath(path));
bool inDirectory(String dir, String path) =>
    path == dir || p.isWithin(dir, path);
bool privateStorageName(String name) =>
    name.toLowerCase() == '.fmtrash' ||
    name.toLowerCase().startsWith(transactionPrefix);

class StorageEntry {
  final String path;
  final FileSystemEntityType type;
  final int size;
  final DateTime modified;

  final int version;
  final String? identity;

  StorageEntry(this.path, this.type, this.size, this.modified,
      {this.version = 0, this.identity});

  bool get isDir => type == FileSystemEntityType.directory;
  bool get isFile => type == FileSystemEntityType.file;

  factory StorageEntry.local(String path, FileStat stat) =>
      StorageEntry(path, stat.type, stat.size, stat.modified,
          version: stat.changed.microsecondsSinceEpoch);

  factory StorageEntry.document(String path, Map<dynamic, dynamic> data) =>
      StorageEntry(
        path,
        data['dir'] == true
            ? FileSystemEntityType.directory
            : FileSystemEntityType.file,
        data['size'] as int,
        DateTime.fromMillisecondsSinceEpoch(data['modified'] as int),
        identity: data['id'] as String?,
      );
}

class StorageVolume {
  final String id, label;
  final String? path, directRoot;
  final int total, free;
  final bool writable;

  StorageVolume(Map<dynamic, dynamic> data)
      : id = data['id'] as String,
        label = data['label'] as String,
        path = data['path'] as String?,
        directRoot = data['directRoot'] as String?,
        total = data['total'] as int? ?? 0,
        free = data['free'] as int? ?? 0,
        writable = data['writable'] as bool? ?? false;
}

String storageError(Object error) {
  if (error is FileSystemException) {
    final path = error.path;
    final detail = switch (error.osError?.errorCode) {
      1 ||
      13 ||
      30 =>
        'Không có quyền ghi hoặc đọc, hoặc thiết bị đang ở chế độ chỉ đọc',
      28 || 122 => 'Không đủ dung lượng',
      19 || 116 => 'Thiết bị lưu trữ đã ngắt kết nối',
      _ => error.message,
    };
    return path == null ? detail : '$detail ($path)';
  }
  if (error is PlatformException) {
    final detail = switch (error.code) {
      'permission' =>
        'Không có quyền truy cập. Hãy cấp lại quyền thư mục SD/USB hoặc kiểm tra chế độ chỉ đọc',
      'offline' => 'Thiết bị lưu trữ đã ngắt kết nối',
      'space' => 'Không đủ dung lượng',
      _ => error.message ?? error.code,
    };
    return detail;
  }
  return error.toString();
}

class Storage {
  Future<List<StorageVolume>> volumes() async {
    if (!Platform.isAndroid) return [];
    final data = await storageChannel.invokeListMethod<dynamic>('volumes');
    return [for (final row in data ?? []) StorageVolume(row as Map)];
  }

  Future<String?> grant([String? id]) =>
      storageChannel.invokeMethod<String>('grant', {'id': id});

  Future<bool> openDocument(String path) async =>
      await storageChannel.invokeMethod<bool>('open', {'path': path}) ?? false;

  Future<void> available(String path) async {
    if (isSaf(path) || (Platform.isAndroid && path.startsWith('/storage/'))) {
      await storageChannel.invokeMethod<void>('available', {'path': path});
    }
  }

  Future<String> identity(String path) async => isSaf(path)
      ? (await storageChannel.invokeMethod<String>('identity', {'path': path}))!
      : p.normalize(path);

  Future<bool> canRenameBetween(String from, String to) async {
    if (!Platform.isAndroid || isSaf(from) || isSaf(to)) return false;
    return await storageChannel
            .invokeMethod<bool>('sameDevice', {'path': from, 'to': to}) ??
        false;
  }

  Future<StorageEntry?> stat(String path) async {
    if (isSaf(path)) {
      final m = await storageChannel
          .invokeMapMethod<dynamic, dynamic>('stat', {'path': path});
      return m == null ? null : StorageEntry.document(path, m);
    }
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type == FileSystemEntityType.link) {
      return StorageEntry(
          path, type, 0, DateTime.fromMillisecondsSinceEpoch(0));
    }
    final stat = await FileStat.stat(path);
    return stat.type == FileSystemEntityType.notFound
        ? null
        : StorageEntry.local(path, stat);
  }

  Stream<StorageEntry> children(String path) async* {
    if (isSaf(path)) {
      final docs = await storageChannel
          .invokeListMethod<dynamic>('list', {'path': path});
      for (final doc in docs ?? []) {
        final data = doc as Map;
        yield StorageEntry.document(p.join(path, data['name'] as String), data);
      }
      return;
    }
    await for (final node in Directory(path).list(followLinks: false)) {
      final entry = await stat(node.path);
      if (entry != null) yield entry;
    }
  }

  Future<void> createDirectory(String path, {bool recursive = false}) async {
    if (!isSaf(path)) {
      await Directory(path).create(recursive: recursive);
      return;
    }
    if (recursive) {
      final existing = await stat(path);
      if (existing?.isDir == true) return;
      if (existing != null)
        throw FileSystemException(
            'Vị trí khôi phục trùng với một tập tin', path);
      await createDirectory(p.dirname(path), recursive: true);
    }
    await storageChannel.invokeMethod<void>('mkdir', {'path': path});
  }

  Future<String> unique(String dir, String name,
      {Set<String> reserved = const {}}) async {
    final base = p.basenameWithoutExtension(name);
    final ext = p.extension(name);
    var candidate = p.join(dir, name);
    var index = 1;
    while (reserved.contains(candidate) || await stat(candidate) != null) {
      candidate = p.join(dir, '$base (${index++})$ext');
    }
    return candidate;
  }

  Future<int> size(String path, {void Function()? check}) async {
    Future<int> measure(StorageEntry entry) async {
      check?.call();
      if (entry.isFile) return max(0, entry.size);
      if (!entry.isDir) return 0;
      var total = 0;
      await for (final child in children(entry.path)) {
        total += await measure(child);
      }
      return total;
    }

    final entry = await stat(path);
    if (entry == null) throw FileSystemException('Không tìm thấy mục', path);
    return measure(entry);
  }

  Future<void> remove(String path) async {
    final entry = await stat(path);
    if (entry == null) return;
    if (isSaf(path)) {
      await storageChannel.invokeMethod<void>('delete', {'path': path});
    } else if (entry.isDir) {
      await Directory(path).delete(recursive: true);
    } else if (entry.type == FileSystemEntityType.link) {
      await Link(path).delete();
    } else {
      await File(path).delete();
    }
  }

  // All moves here require a vacant destination. Android also checks the
  // volume or persisted tree permission before touching a removable device.
  Future<void> rename(String from, String to) async {
    if (await stat(to) != null) throw FileSystemException('Tên đã tồn tại', to);
    if (isSaf(from) || isSaf(to)) {
      await storageChannel
          .invokeMethod<void>('rename', {'path': from, 'to': to});
      return;
    }
    final entry = await stat(from);
    if (entry == null) throw FileSystemException('Không tìm thấy mục', from);
    if (entry.isDir) {
      await Directory(from).rename(to);
    } else if (entry.type == FileSystemEntityType.link) {
      await Link(from).rename(to);
    } else {
      await File(from).rename(to);
    }
  }

  Future<StorageStream> open(String path, {bool write = false}) async {
    if (isSaf(path)) {
      final handle = await storageChannel
          .invokeMethod<int>('streamOpen', {'path': path, 'write': write});
      return StorageStream.document(handle!);
    }
    if (write) await File(path).create(exclusive: true);
    return StorageStream.local(
        await File(path).open(mode: write ? FileMode.write : FileMode.read));
  }

  Future<String> materialize(String path) async {
    final dir = await Directory.systemTemp.createTemp('fm-open-');
    final dest = p.join(dir.path, p.basename(path));
    try {
      await copyFile(path, dest);
      return dest;
    } catch (_) {
      await dir.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> copyFile(String src, String dest,
      {TransferProgress? progress}) async {
    final before = await stat(src);
    if (before == null || !before.isFile)
      throw FileSystemException('Không đọc được tập tin nguồn', src);
    final input = await open(src);
    try {
      final output = await open(dest, write: true);
      try {
        var written = 0;
        while (true) {
          progress?.check();
          final bytes = await input.read();
          if (bytes.isEmpty) break;
          await output.write(bytes);
          written += bytes.length;
          progress?.add(bytes.length);
        }
        if (written != before.size && !(isSaf(src) && before.size < 0)) {
          throw FileSystemException(
              'Kích thước nguồn thay đổi trong lúc sao chép', src);
        }
        await output.flush();
      } finally {
        await output.close();
      }
    } finally {
      await input.close();
    }

    progress?.describe('Đang xác minh ${p.basename(src)}');
    final original = await open(src);
    try {
      final copied = await open(dest);
      try {
        while (true) {
          progress?.check();
          final bytes = await original.read();
          final check = await copied.read();
          if (!_equalBytes(bytes, check)) {
            throw FileSystemException(
                'Dữ liệu bản sao không khớp với nguồn', src);
          }
          if (bytes.isEmpty) break;
        }
      } finally {
        await copied.close();
      }
    } finally {
      await original.close();
    }
    final after = await stat(src);
    if (after == null ||
        before.size != after.size ||
        before.modified != after.modified) {
      throw FileSystemException(
          'Tập tin nguồn đã thay đổi trong lúc sao chép', src);
    }
  }
}

bool _equalBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

const streamChunk = 512 * 1024;

class StorageStream {
  final RandomAccessFile? _file;
  final int? _handle;

  StorageStream.local(this._file) : _handle = null;
  StorageStream.document(this._handle) : _file = null;

  Future<Uint8List> read() async {
    if (_file == null) {
      return (await storageChannel
          .invokeMethod<Uint8List>('streamRead', {'handle': _handle}))!;
    }
    final bytes = Uint8List(streamChunk);
    var offset = 0;
    while (offset < bytes.length) {
      final count = await _file.readInto(bytes, offset);
      if (count == 0) break;
      offset += count;
    }
    return Uint8List.sublistView(bytes, 0, offset);
  }

  Future<void> write(Uint8List bytes) async {
    if (_file != null) {
      await _file.writeFrom(bytes);
    } else {
      await storageChannel.invokeMethod<void>(
          'streamWrite', {'handle': _handle, 'bytes': bytes});
    }
  }

  Future<void> flush() async {
    if (_file != null) {
      await _file.flush();
    } else {
      await storageChannel
          .invokeMethod<void>('streamFlush', {'handle': _handle});
    }
  }

  Future<void> close() async {
    if (_file != null) {
      await _file.close();
    } else {
      await storageChannel
          .invokeMethod<void>('streamClose', {'handle': _handle});
    }
  }
}

abstract interface class TransferProgress {
  void check();
  void add(int bytes);
  void describe(String label);
  void finishing();
}

String storageId() {
  final random = Random.secure();
  return List.generate(
      16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

Future<void> writeStorageRecord(File file, Object data) async {
  final temporary = File('${file.path}.new');
  try {
    await temporary.writeAsString(jsonEncode(data), flush: true);
    await temporary.rename(file.path);
  } catch (_) {
    try {
      if (await temporary.exists()) await temporary.delete();
    } on FileSystemException {
      // Recovery retries cleanup if the journal filesystem is unavailable.
    }
    rethrow;
  }
}
