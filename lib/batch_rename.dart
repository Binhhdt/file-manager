import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'file_operations.dart';
import 'storage.dart';

enum RenameStyle {
  prefix,
  suffix,
  replace,
  remove,
  number,
  template,
  upper,
  lower,
  trim
}

String batchName(String original, RenameStyle style, String text,
    String replacement, int index,
    {bool editExtension = false}) {
  final extension = p.extension(original);
  final base = editExtension ? original : p.basenameWithoutExtension(original);
  final number = (index + 1).toString().padLeft(3, '0');
  final result = switch (style) {
    RenameStyle.prefix => text + base,
    RenameStyle.suffix => base + text,
    RenameStyle.replace =>
      text.isEmpty ? base : base.replaceAll(text, replacement),
    RenameStyle.remove => text.isEmpty ? base : base.replaceAll(text, ''),
    RenameStyle.number => '$base $number',
    RenameStyle.template => text.replaceAllMapped(
        RegExp(r'\{(name|n|ext)\}'),
        (match) => switch (match[1]) {
              'name' => p.basenameWithoutExtension(original),
              'ext' => editExtension ? extension : '',
              _ => number,
            }),
    RenameStyle.upper => base.toUpperCase(),
    RenameStyle.lower => base.toLowerCase(),
    RenameStyle.trim => base.trim().replaceAll(RegExp(r'\s+'), ' '),
  };
  return editExtension ? result : result + extension;
}

bool isBatchNameValid(String name) =>
    name.trim().isNotEmpty &&
    name != '.' &&
    name != '..' &&
    !privateStorageName(name) &&
    utf8.encode(name).length <= 255 &&
    !RegExp(r'[/\x00-\x1f\x7f]').hasMatch(name);

class RenamePlan {
  final Map<String, String> paths;
  final Map<String, String> errors;
  const RenamePlan(this.paths, this.errors);
  bool get valid => errors.isEmpty && paths.isNotEmpty;
}

class _RenameItem {
  final String from, to, staged, stamp;
  const _RenameItem(this.from, this.to, this.staged, this.stamp);
  _RenameItem.decode(List<dynamic> row)
      : this(row[0] as String, row[1] as String, row[2] as String,
            row[3] as String);
  List<String> toJson() => [from, to, staged, stamp];
}

enum _Phase { staging, publishing, retracting, restoring, committed }

class BatchRename {
  final FileOperations operations;
  final Directory journal;
  final Future<void> Function(String, Map<String, String>) onCommit;
  final void Function(Iterable<String>) markPaths;

  BatchRename(this.operations, this.journal,
      {required this.onCommit, required this.markPaths});

  Storage get _storage => operations.storage;
  File get _pending => File(p.join(journal.path, 'pending.json'));
  File get _undo => File(p.join(journal.path, 'undo.json'));

  Future<bool> hasUndo() => _undo.exists();

  Future<RenamePlan> preview(Map<String, String> names,
      {void Function()? check}) async {
    final changes = <String, String>{};
    final errors = <String, String>{};
    final targetOwners = <String, String>{};
    final sources = names.keys.toSet();
    for (final entry in names.entries) {
      check?.call();
      final path = entry.key, basename = entry.value;
      if (basename == p.basename(path)) continue;
      if (!isBatchNameValid(basename)) {
        errors[path] = 'Tên không hợp lệ';
        continue;
      }
      final target = p.join(p.dirname(path), basename);
      changes[path] = target;
      final key = target.toLowerCase();
      final other = targetOwners[key];
      if (other != null) {
        errors[path] = errors[other] = 'Hai mục có cùng tên đích';
        continue;
      }
      targetOwners[key] = path;
      if (sources.contains(target) && names[target] != p.basename(target))
        continue;
      try {
        if (await _storage.stat(target) != null &&
            !await _caseAlias(path, target)) {
          errors[path] = 'Đã có tập tin hoặc thư mục cùng tên';
        }
      } on Exception catch (error) {
        errors[path] = storageError(error);
      }
    }
    return RenamePlan(changes, errors);
  }

  Future<bool> _caseAlias(String path, String target) async {
    if (path.toLowerCase() != target.toLowerCase() ||
        isSaf(path) ||
        !Platform.isAndroid) return false;
    final ids = <String?>[];
    for (final value in [path, target]) {
      ids.add(await storageChannel
          .invokeMethod<String>('fileIdentity', {'path': value}));
    }
    return ids.first != null && ids.first == ids.last;
  }

  String _stamp(StorageEntry entry) =>
      '${entry.type}:${entry.size}:${entry.modified.microsecondsSinceEpoch}';

  Future<Map<String, Object?>> _read(File file) async =>
      (jsonDecode(await file.readAsString()) as Map).cast<String, Object?>();

  Future<void> _record(
          String id, _Phase phase, List<_RenameItem> items, bool undo) =>
      writeStorageRecord(_pending,
          {'id': id, 'phase': phase.name, 'undo': undo, 'items': items});

  Future<int> apply(Map<String, String> names, TransferProgress progress,
      {void Function(int)? start}) async {
    await operations.recover();
    return operations.exclusive(() async {
      await _recover();
      final plan = await preview(names, check: progress.check);
      if (!plan.valid) {
        throw FileSystemException(plan.errors.isEmpty
            ? 'Không có thay đổi'
            : plan.errors.values.first);
      }
      return _execute(plan, progress, false, start);
    });
  }

  Future<int> undo(TransferProgress progress,
      {void Function(int)? start}) async {
    await operations.recover();
    return operations.exclusive(() async {
      await _recover();
      if (!await _undo.exists())
        throw const FileSystemException('Không có lần đổi tên để hoàn tác');
      final saved = await _read(_undo);
      final names = <String, String>{};
      for (final row in saved['items'] as List) {
        progress.check();
        final item = _RenameItem.decode(row);
        await _require(item.to, item.stamp);
        names[item.to] = p.basename(item.from);
      }
      final plan = await preview(names, check: progress.check);
      if (!plan.valid) throw FileSystemException(plan.errors.values.first);
      return _execute(plan, progress, true, start);
    });
  }

  Future<int> _execute(RenamePlan plan, TransferProgress progress, bool undo,
      void Function(int)? start) async {
    await journal.create(recursive: true);
    final id = storageId();
    final items = <_RenameItem>[];
    final identities = <String>{};
    for (final entry in plan.paths.entries) {
      progress.check();
      await _storage.available(entry.key);
      await operations.requireRealParent(entry.key);
      if (!identities.add(await _storage.identity(entry.key))) {
        throw FileSystemException(
            'Hai đường dẫn trỏ đến cùng tập tin', entry.key);
      }
      final original = await _storage.stat(entry.key);
      if (original?.isFile != true) {
        throw FileSystemException('Không tìm thấy tập tin nguồn', entry.key);
      }
      final stage = p.join(
          p.dirname(entry.key), '$transactionPrefix$id-rename-${items.length}');
      if (await _storage.stat(stage) != null)
        throw FileSystemException('Tên tạm đã tồn tại', stage);
      items.add(_RenameItem(entry.key, entry.value, stage, _stamp(original!)));
    }
    progress.check();
    start?.call(items.length * 2);
    await _record(id, _Phase.staging, items, undo);
    try {
      for (final item in items) {
        progress.check();
        progress.describe(storageDisplayPath(item.from));
        await _require(item.from, item.stamp);
        await _storage.rename(item.from, item.staged);
        progress.add(1);
      }
      await _record(id, _Phase.publishing, items, undo);
      for (final item in items) {
        progress.check();
        progress.describe(storageDisplayPath(item.to));
        await _require(item.staged, item.stamp);
        await _storage.rename(item.staged, item.to);
        progress.add(1);
      }
      progress.check();
      progress.finishing();
      await _record(id, _Phase.committed, items, undo);
    } catch (_) {
      await _recover();
      rethrow;
    }
    await _complete(id, items, undo);
    return items.length;
  }

  Future<void> _require(String path, String stamp) async {
    final current = await _storage.stat(path);
    if (current == null || _stamp(current) != stamp) {
      throw FileSystemException(
          'Tập tin đã thay đổi hoặc mất quyền truy cập', path);
    }
  }

  Future<void> recover() => operations.exclusive(_recover);

  Future<void> _recover() async {
    if (!await _pending.exists()) return;
    final record = await _read(_pending);
    final id = record['id'] as String;
    var phase = _Phase.values.byName(record['phase'] as String);
    final items = (record['items'] as List)
        .map((row) => _RenameItem.decode(row as List))
        .toList();
    final undo = record['undo'] == true;
    if (phase == _Phase.committed) {
      await _complete(id, items, undo);
      return;
    }
    if (phase == _Phase.publishing || phase == _Phase.retracting) {
      if (phase == _Phase.publishing)
        await _record(id, _Phase.retracting, items, undo);
      for (final item in items) {
        await _storage.available(item.staged);
        if (await _storage.stat(item.staged) == null) {
          await _require(item.to, item.stamp);
          await _storage.rename(item.to, item.staged);
        }
      }
      phase = _Phase.restoring;
      await _record(id, phase, items, undo);
    }
    for (final item in items) {
      await _storage.available(item.from);
      if (await _storage.stat(item.staged) != null) {
        await _require(item.staged, item.stamp);
        await _storage.rename(item.staged, item.from);
      } else {
        await _require(item.from, item.stamp);
      }
    }
    markPaths(items.expand((item) => [item.from, item.to]));
    await _pending.delete();
  }

  Future<void> _complete(String id, List<_RenameItem> items, bool undo) async {
    await onCommit(id, {for (final item in items) item.from: item.to});
    if (undo) {
      if (await _undo.exists()) await _undo.delete();
    } else {
      await writeStorageRecord(_undo, {'items': items});
    }
    markPaths(items.expand((item) => [item.from, item.to]));
    await _pending.delete();
  }
}
