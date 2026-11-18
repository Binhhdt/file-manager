import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'storage.dart';

enum Conflict { overwrite, keep, skip }

class TransferCancelled implements Exception {}

class TransferItem {
  final String source, destination;
  final bool overwrite, move, fast;
  final String stage, backup, parked;
  String? publishedStamp;

  TransferItem(this.source, this.destination, this.overwrite, this.move,
      this.fast, String token)
      : stage =
            p.join(p.dirname(destination), '$transactionPrefix$token-stage'),
        backup =
            p.join(p.dirname(destination), '$transactionPrefix$token-backup'),
        parked = p.join(p.dirname(source), '$transactionPrefix$token-source');

  TransferItem.fromJson(Map<String, dynamic> row)
      : source = row['source'] as String,
        destination = row['destination'] as String,
        overwrite = row['overwrite'] as bool,
        move = row['move'] as bool,
        fast = row['fast'] as bool,
        stage = row['stage'] as String,
        backup = row['backup'] as String,
        parked = row['parked'] as String,
        publishedStamp = row['stamp'] as String?;

  Map<String, Object> toJson() => {
        'source': source,
        'destination': destination,
        'overwrite': overwrite,
        'move': move,
        'fast': fast,
        'stage': stage,
        'backup': backup,
        'parked': parked,
        if (publishedStamp case final stamp?) 'stamp': stamp,
      };
}

enum _Phase { prepare, publish, discard, committed, purge }

class FileOperations {
  final Storage storage;
  final Directory journal;
  Future<void> _queue = Future.value();

  FileOperations(this.storage, this.journal);

  Future<T> exclusive<T>(Future<T> Function() action) {
    final work = _queue.then((_) => action());
    _queue =
        work.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return work;
  }

  Future<List<String>> recover() => exclusive(_recover);

  Future<List<String>> _recover() async {
    final failures = <String>[];
    await journal.create(recursive: true);
    await for (final entity in journal.list(followLinks: false)) {
      if (entity is! File) continue;
      try {
        if (entity.path.endsWith('.json.new')) {
          await entity.delete();
          continue;
        }
        if (!entity.path.endsWith('.json')) continue;
        final data =
            jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        final phase = _Phase.values.byName(data['phase'] as String);
        final items = (data['items'] as List)
            .map((m) => TransferItem.fromJson(m as Map<String, dynamic>))
            .toList();
        await _recoverRecord(entity, phase, items);
      } catch (error) {
        failures.add(storageError(error));
      }
    }
    return failures;
  }

  Future<void> _record(File file, _Phase phase, List<TransferItem> items) =>
      writeStorageRecord(file, {'phase': phase.name, 'items': items});

  Future<void> _recoverRecord(
      File record, _Phase phase, List<TransferItem> items) async {
    if (phase == _Phase.purge) {
      final item = items.single;
      await storage.available(item.destination);
      await storage.remove(item.destination);
      await record.delete();
      return;
    }
    if (phase == _Phase.publish) {
      for (final item in items.reversed) {
        await storage.available(item.destination);
        if (item.move) await storage.available(item.source);
        if (item.fast) {
          if (await storage.stat(item.source) == null) {
            await _retract(item, item.source);
          }
          continue;
        }
        if (item.move && await storage.stat(item.parked) != null) {
          await storage.rename(item.parked, item.source);
        }
        final backup =
            item.overwrite && await storage.stat(item.backup) != null;
        if (backup || !item.overwrite) {
          if (await storage.stat(item.stage) == null) {
            await _retract(item, item.stage);
          }
          if (backup) await storage.rename(item.backup, item.destination);
        }
      }
      await _record(record, _Phase.discard, items);
    }
    final failures = <String>[];
    for (final item in items) {
      try {
        if (item.fast) continue;
        await storage.available(item.destination);
        await storage.remove(item.stage);
        if (phase == _Phase.committed && item.overwrite)
          await storage.remove(item.backup);
      } catch (error) {
        failures.add(storageError(error));
      }
      if (phase == _Phase.committed && item.move && !item.fast) {
        try {
          await storage.available(item.source);
          await storage.remove(item.parked);
        } catch (error) {
          failures.add(storageError(error));
        }
      }
    }
    if (failures.isNotEmpty) throw FileSystemException(failures.join('\n'));
    await record.delete();
  }

  Future<void> _retract(TransferItem item, String to) async {
    final published = await storage.stat(item.destination);
    if (published == null) return;
    if (_stamp(published) != item.publishedStamp) {
      throw FileSystemException(
          'Mục đích đã thay đổi trong lúc phục hồi. Hãy chuyển mục hiện tại sang tên khác',
          item.destination);
    }
    await storage.rename(item.destination, to);
  }

  static List<String> selection(Iterable<String> paths) {
    final normalized = paths.map(p.normalize).toSet();
    return normalized.where((path) {
      var next = p.dirname(path);
      while (next != path) {
        if (normalized.contains(next)) return false;
        path = next;
        next = p.dirname(path);
      }
      return true;
    }).toList();
  }

  Future<int> paste(
    List<String> sources,
    String directory, {
    required bool move,
    required Conflict conflict,
    TransferProgress? progress,
  }) =>
      exclusive(() async {
        final token = storageId();
        final items = <TransferItem>[];
        final reserved = <String>{};
        await storage.available(directory);
        final destinationRoot = await storage.identity(directory);
        final identities = <String, String>{};
        for (final source in selection(sources)) {
          progress?.check();
          identities.putIfAbsent(await storage.identity(source), () => source);
        }
        for (final sourceIdentity in selection(identities.keys)) {
          progress?.check();
          final source = identities[sourceIdentity]!;
          if (inDirectory(sourceIdentity, destinationRoot))
            throw FileSystemException(
                'Không thể dán thư mục vào chính nó', source);
          final same = p.dirname(sourceIdentity) == destinationRoot;
          if (move && same) continue;
          final name = p.basename(source);
          var target = p.join(directory, name);
          var replace = false;
          final existing = await storage.stat(target);
          if (existing != null || reserved.contains(target)) {
            if (same ||
                reserved.contains(target) ||
                p.isWithin(await storage.identity(target), sourceIdentity) ||
                conflict == Conflict.keep) {
              target =
                  await storage.unique(directory, name, reserved: reserved);
            } else if (conflict == Conflict.skip) {
              continue;
            } else {
              replace = true;
            }
          }
          reserved.add(target);
          final fast = move &&
              !replace &&
              await storage.canRenameBetween(source, target);
          items.add(TransferItem(
              source, target, replace, move, fast, '$token-${items.length}'));
        }
        return execute(items, progress: progress);
      });

  Future<int> move(String source, String destination, {bool fast = false}) =>
      exclusive(() => execute(
          [TransferItem(source, destination, false, true, fast, storageId())]));

  // Call while holding exclusive(). First detach the selected entry, then
  // persist the irreversible purge before deleting the detached contents.
  Future<void> erase(String source) async {
    final destination =
        p.join(p.dirname(source), '$transactionPrefix${storageId()}-purge');
    final item =
        TransferItem(source, destination, false, true, true, storageId());
    final items = [item];
    await _requireCleanDestinations(items);
    await storage.available(source);
    await requireRealParent(source);
    final original = await storage.stat(source);
    if (original == null)
      throw FileSystemException('Không tìm thấy mục', source);
    item.publishedStamp = _stamp(original);
    final record = File(p.join(journal.path, '${storageId()}.json'));
    await _record(record, _Phase.publish, items);
    try {
      await storage.rename(source, destination);
      await _record(record, _Phase.purge, items);
    } catch (_) {
      await _recoverRecord(record, _Phase.publish, items);
      rethrow;
    }
    await _recoverRecord(record, _Phase.purge, items);
  }

  Future<bool> hasPendingRecords() async {
    await journal.create(recursive: true);
    return journal
        .list(followLinks: false)
        .any((file) => file is File && file.path.endsWith('.json'));
  }

  // Call while holding exclusive(). Each published batch is either retained
  // in full or rolled back. Copies and backups live on the destination volume.
  Future<int> execute(List<TransferItem> items,
      {TransferProgress? progress}) async {
    if (items.isEmpty) return 0;
    await _requireCleanDestinations(items);
    for (final item in items) {
      progress?.check();
      await storage.available(item.source);
      await storage.available(item.destination);
      final source = await storage.identity(item.source);
      final destination = await storage.identity(item.destination);
      if (inDirectory(source, destination) ||
          inDirectory(destination, source)) {
        throw FileSystemException(
            'Nguồn và đích nằm trong cùng cây thư mục', item.source);
      }
      await requireRealParent(item.source);
      await requireRealParent(item.destination);
      final old = await storage.stat(item.destination);
      if ((old != null) != item.overwrite) {
        throw FileSystemException(
            'Mục đích đã thay đổi. Hãy thử lại', item.destination);
      }
    }

    await journal.create(recursive: true);
    final record = File(p.join(journal.path, '${storageId()}.json'));
    var phase = _Phase.prepare;
    await _record(record, phase, items);
    try {
      final stamps = <String, String>{};
      for (final item in items) {
        progress?.check();
        if (item.fast) continue;
        if (item.overwrite) {
          final old = await storage.stat(item.destination);
          final source = await storage.stat(item.source);
          if (old?.type != source?.type) {
            throw FileSystemException(
                'Tên trùng giữa tập tin và thư mục. Hãy chọn Giữ cả hai',
                item.destination);
          }
          if (old?.isDir == true) {
            await _stage(item.destination, item.stage, stamps,
                progress: progress, count: false);
          } else if (old != null) {
            stamps[item.destination] = _stamp(old);
          }
        }
        await _stage(item.source, item.stage, stamps, progress: progress);
      }
      for (final stamp in stamps.entries) {
        progress?.check();
        final current = await storage.stat(stamp.key);
        if (current == null || _stamp(current) != stamp.value) {
          throw FileSystemException(
              'Mục đã thay đổi trong lúc sao chép', stamp.key);
        }
      }
      progress?.check();
      for (final item in items) {
        final prepared =
            await storage.stat(item.fast ? item.source : item.stage);
        if (prepared == null)
          throw FileSystemException(
              'Không tìm thấy mục đã chuẩn bị', item.source);
        item.publishedStamp = _stamp(prepared);
      }
      progress?.check();
      await _record(record, _Phase.publish, items);
      phase = _Phase.publish;
      for (final item in items) {
        progress?.check();
        if (item.fast) {
          await storage.rename(item.source, item.destination);
        } else {
          if (item.overwrite)
            await storage.rename(item.destination, item.backup);
          progress?.check();
          await storage.rename(item.stage, item.destination);
        }
      }
      for (final item in items) {
        progress?.check();
        if (item.move && !item.fast)
          await storage.rename(item.source, item.parked);
      }
      progress?.check();
      progress?.finishing();
      await _record(record, _Phase.committed, items);
      phase = _Phase.committed;
    } catch (error) {
      try {
        await _recoverRecord(record, phase, items);
      } catch (recovery) {
        throw FileSystemException(
            '${storageError(error)}. Chưa thể phục hồi: ${storageError(recovery)}');
      }
      rethrow;
    }

    try {
      await _recoverRecord(record, phase, items);
    } catch (error) {
      throw FileSystemException(
          'Đã hoàn tất, nhưng chưa thể dọn mục tạm: ${storageError(error)}');
    }
    return items.length;
  }

  Future<void> _requireCleanDestinations(List<TransferItem> items) async {
    await _recover();
    await for (final entity in journal.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final data =
          jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
      final pending = (data['items'] as List)
          .map((row) => TransferItem.fromJson(row as Map<String, dynamic>));
      for (final old in pending) {
        final paths = [old.source, old.destination];
        if (items.any((item) => paths.any((path) => [
              item.source,
              item.destination
            ].any(
                (now) => inDirectory(now, path) || inDirectory(path, now))))) {
          throw FileSystemException(
              'Cần kết nối lại thiết bị để phục hồi thao tác trước');
        }
      }
    }
  }

  Future<void> requireRealParent(String path,
      {bool allowMissing = false}) async {
    if (!isSaf(path)) {
      var parent = p.dirname(path);
      if (allowMissing) {
        while (await storage.stat(parent) == null) {
          parent = p.dirname(parent);
        }
      }
      final resolved = await Directory(parent).resolveSymbolicLinks();
      // Private Android directories can have a system-owned alias.
      final trusted = [Directory.systemTemp.path, journal.parent.path];
      for (final base in trusted) {
        if (inDirectory(base, parent)) {
          final realBase = await Directory(base).resolveSymbolicLinks();
          if (resolved ==
              p.normalize(p.join(realBase, p.relative(parent, from: base))))
            return;
        }
      }
      if (resolved != p.normalize(parent))
        throw FileSystemException(
            'Không thao tác qua liên kết thư mục', parent);
    }
  }

  String _stamp(StorageEntry entry) =>
      '${entry.type}:${entry.size}:${entry.modified.microsecondsSinceEpoch}';

  Future<void> _stage(
    String source,
    String stage,
    Map<String, String> stamps, {
    TransferProgress? progress,
    bool count = true,
  }) async {
    progress?.check();
    progress?.describe(p.basename(source));
    final entry = await storage.stat(source);
    if (entry == null)
      throw FileSystemException('Không tìm thấy mục nguồn', source);
    stamps[source] = _stamp(entry);
    final previous = await storage.stat(stage);
    if (previous != null && previous.type != entry.type) {
      throw FileSystemException(
          'Tên trùng giữa tập tin và thư mục. Hãy chọn Giữ cả hai', source);
    }
    if (entry.isDir) {
      if (previous == null) await storage.createDirectory(stage);
      await for (final child in storage.children(source)) {
        if (privateStorageName(p.basename(child.path))) {
          throw FileSystemException(
              'Thư mục chứa dữ liệu thùng rác hoặc giao dịch đang chờ xử lý',
              child.path);
        }
        await _stage(child.path, p.join(stage, p.basename(child.path)), stamps,
            progress: progress, count: count);
      }
    } else if (entry.isFile) {
      if (previous != null) await storage.remove(stage);
      await storage.copyFile(source, stage,
          progress:
              count || progress == null ? progress : _VerifyProgress(progress));
    } else if (entry.type == FileSystemEntityType.link && !isSaf(stage)) {
      if (previous != null) await storage.remove(stage);
      final target = await Link(source).target();
      await Link(stage).create(target);
      if (await Link(stage).target() != target) {
        throw FileSystemException('Không xác minh được liên kết', source);
      }
    } else {
      throw FileSystemException(
          'Thiết bị không hỗ trợ sao chép mục này', source);
    }
  }
}

class _VerifyProgress implements TransferProgress {
  final TransferProgress wrapped;
  _VerifyProgress(this.wrapped);

  @override
  void add(int bytes) {}
  @override
  void check() => wrapped.check();
  @override
  void describe(String label) => wrapped.describe(label);
  @override
  void finishing() => wrapped.finishing();
}
