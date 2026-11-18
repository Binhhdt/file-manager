import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'file_operations.dart';
import 'storage.dart';

class Trash {
  final FileOperations operations;
  final Directory index, legacy;
  final String internalRoot;
  final Map<String, String> Function() legacyOrigins;
  final Future<void> Function(String) forgetLegacy;

  Trash(this.operations, this.index, this.legacy, this.internalRoot,
      this.legacyOrigins, this.forgetLegacy);
  Storage get _storage => operations.storage;

  File _record(String id) => File(p.join(index.path, '$id.json'));

  String _dataRoot(String original) => p.isWithin(internalRoot, original)
      ? p.join(legacy.path, '.items')
      : p.join(index.path, 'items');

  String _dataPath(String id, String original) =>
      p.join(_dataRoot(original), id, p.basename(original));

  Future<Map<String, String?>> _entries() async {
    final entries = <String, String?>{};
    if ((await _storage.stat(legacy.path))?.isDir == true) {
      final old = legacyOrigins();
      try {
        await for (final entry in _storage.children(legacy.path)) {
          if (_isLegacyPath(entry.path)) entries[entry.path] = old[entry.path];
        }
      } on FileSystemException {
        // The app-private entries can still be used without internal storage access.
      }
    }
    await index.create(recursive: true);
    final pending = await operations.hasPendingRecords();
    await for (final file in index.list(followLinks: false)) {
      if (file is! File) continue;
      if (file.path.endsWith('.json.new')) {
        await file.delete();
        continue;
      }
      if (!file.path.endsWith('.json')) continue;
      final original = await _readOrigin(file);
      final id = p.basenameWithoutExtension(file.path);
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id) || original == null) continue;
      final data = _dataPath(id, original);
      final parent = Directory(p.dirname(data));
      if ((await _storage.stat(parent.path))?.isDir == true) {
        await operations.requireRealParent(data);
        if (await _storage.stat(data) != null) {
          entries[data] = original;
        } else if (!pending && await parent.list(followLinks: false).isEmpty) {
          await file.delete();
          await parent.delete();
        }
      }
    }
    return entries;
  }

  Future<List<StorageEntry>> list() async {
    await operations.recover();
    return operations.exclusive(() async {
      final entries = await _entries();
      final result = <StorageEntry>[];
      for (final path in entries.keys) {
        final entry = await _storage.stat(path);
        if (entry != null) result.add(entry);
      }
      return result;
    });
  }

  bool _validOriginal(String path) =>
      p.isAbsolute(path) &&
      p.normalize(path) == path &&
      (p.isWithin(internalRoot, path) ||
          isSaf(path) ||
          path.startsWith('/storage/')) &&
      !p.split(path).any(privateStorageName);

  bool _isLegacyPath(String path) =>
      p.dirname(path) == legacy.path &&
      p.basename(path) != '.items' &&
      !p.basename(path).startsWith(transactionPrefix);

  Future<String?> _readOrigin(File file) async {
    if (!await file.exists()) return null;
    try {
      final origin = jsonDecode(await file.readAsString());
      return origin is String && _validOriginal(origin) ? origin : null;
    } on FormatException {
      return null;
    }
  }

  Future<String?> _origin(String path) async {
    if (_isLegacyPath(path)) {
      if ((await _storage.stat(legacy.path))?.isDir == true &&
          await _storage.stat(path) != null) {
        return legacyOrigins()[path];
      }
    } else {
      final id = p.basename(p.dirname(path));
      if (RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) {
        final original = await _readOrigin(_record(id));
        if (original != null && path == _dataPath(id, original)) {
          await operations.requireRealParent(path);
          if (await _storage.stat(path) != null) return original;
        }
      }
    }
    throw FileSystemException('Mục này không nằm trong Thùng rác', path);
  }

  Future<void> put(String source) => operations.exclusive(() async {
        if (!_validOriginal(source))
          throw FileSystemException(
              'Không thể chuyển vị trí này vào Thùng rác', source);
        await _storage.available(source);
        if (await _storage.stat(source) == null)
          throw FileSystemException('Không tìm thấy mục', source);
        final fast = p.isWithin(internalRoot, source);
        if (fast && (await _storage.stat(legacy.path))?.isDir == false) {
          throw FileSystemException(
              'Thư mục Thùng rác không hợp lệ', legacy.path);
        }
        final id = storageId();
        final destination = _dataPath(id, source);
        await index.create(recursive: true);
        await writeStorageRecord(_record(id), source);
        await operations.requireRealParent(destination, allowMissing: true);
        await _storage.createDirectory(p.dirname(destination), recursive: true);
        await operations.execute([
          TransferItem(source, destination, false, true, fast, storageId())
        ]);
      });

  Future<void> restore(String path) async {
    await operations.recover();
    return operations.exclusive(() async {
      final original = await _origin(path);
      if (original == null || !_validOriginal(original)) {
        throw FileSystemException(
            'Không có thông tin đường dẫn gốc để khôi phục', path);
      }
      await _storage.available(original);
      final parent = p.dirname(original);
      await operations.requireRealParent(original, allowMissing: true);
      await _storage.createDirectory(parent, recursive: true);
      final destination = await _storage.unique(parent, p.basename(original));
      final fast =
          p.isWithin(legacy.path, path) && p.isWithin(internalRoot, original);
      await operations.execute(
          [TransferItem(path, destination, false, true, fast, storageId())]);
      await _forget(path);
    });
  }

  Future<void> purge(String path) async {
    await operations.recover();
    return operations.exclusive(() async {
      await _origin(path);
      await operations.erase(path);
      await _forget(path);
    });
  }

  Future<void> _forget(String path) async {
    if (p.dirname(path) == legacy.path) {
      await forgetLegacy(path);
    } else {
      final parent = Directory(p.dirname(path));
      await _record(p.basename(parent.path)).delete();
      // The parent may still contain a parked source awaiting journal cleanup.
      if (await parent.list(followLinks: false).isEmpty) await parent.delete();
    }
  }
}
