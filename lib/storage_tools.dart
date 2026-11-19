import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'file_catalog.dart';
import 'file_operations.dart';
import 'storage.dart';

bool excludedFromTools(String path) {
  final parts = p.split(path.toLowerCase());
  return parts.any(privateStorageName) ||
      parts.any((part) => part == '.fmvault' || part == 'android');
}

class StorageSurvey {
  final entries = <StorageEntry>[];
  final emptyFolders = <StorageEntry>[];
  int skipped = 0;

  static Future<StorageSurvey> scan(
    FileCatalog catalog,
    List<CatalogRoot> roots,
    TransferProgress progress,
  ) async {
    final survey = StorageSurvey();
    final visited = <String>{};
    final folders = <(String, String, StorageEntry?)>[
      for (final root in roots) (root.path, root.identity, null),
    ];
    while (folders.isNotEmpty) {
      progress.check();
      final (path, identity, entry) = folders.removeLast();
      if (excludedFromTools(identity) || !visited.add(identity)) continue;
      progress.describe(storageDisplayPath(path));
      try {
        final children = await catalog.refresh(path, audit: true);
        if (children.isEmpty && entry != null) survey.emptyFolders.add(entry);
        for (final child in children) {
          progress.check();
          final key = p.join(identity, p.basename(child.path));
          if (excludedFromTools(key)) continue;
          if (child.isDir) {
            folders.add((child.path, key, child));
          } else if (child.isFile && visited.add(key)) {
            survey.entries.add(child);
          }
        }
      } on TransferCancelled {
        rethrow;
      } on Exception {
        survey.skipped++;
      }
    }
    return survey;
  }
}

class DuplicateGroup {
  final String hash;
  final List<StorageEntry> files;
  const DuplicateGroup(this.hash, this.files);
  int get reclaimable => (files.length - 1) * files.first.size;
}

class DuplicateScan {
  final Storage storage;
  final File index;
  List<DuplicateGroup> verified = const [];
  int skipped = 0;

  DuplicateScan(this.storage, this.index);

  static List<Object?> fingerprint(StorageEntry entry) => [
        entry.size,
        entry.modified.microsecondsSinceEpoch,
        entry.version,
        entry.identity,
      ];
  static bool unchanged(StorageEntry entry, StorageEntry? current) =>
      current?.type == entry.type &&
      jsonEncode(fingerprint(entry)) == jsonEncode(fingerprint(current!));

  Future<String> _physicalPath(String path) async {
    final identity = await storage.identity(path);
    if (Platform.isAndroid) {
      final inode = await storageChannel.invokeMethod<String>(
        'fileIdentity',
        {'path': identity},
      );
      if (inode != null) return inode;
    }
    return identity;
  }

  Future<String> digest(StorageEntry entry, TransferProgress progress) async {
    if (!unchanged(entry, await storage.stat(entry.path))) {
      throw FileSystemException('Tập tin đã thay đổi', entry.path);
    }
    final receiver = _DigestSink();
    final hash = sha256.startChunkedConversion(receiver);
    var length = 0;
    final reader = await storage.open(entry.path);
    try {
      for (;;) {
        progress.check();
        final bytes = await reader.read();
        if (bytes.isEmpty) break;
        hash.add(bytes);
        length += bytes.length;
        progress.add(bytes.length);
        // Yield between chunks even if the transport completes immediately.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      await reader.close();
      hash.close();
    }
    if (length != entry.size ||
        !unchanged(entry, await storage.stat(entry.path))) {
      throw FileSystemException('Tập tin đã thay đổi', entry.path);
    }
    return receiver.value.toString();
  }

  Future<List<DuplicateGroup>> find(
      Iterable<StorageEntry> entries, TransferProgress progress,
      {void Function(int)? onTotal}) async {
    skipped = 0;
    final saved = <String, dynamic>{};
    try {
      if (await index.length() <= 8 * 1024 * 1024) {
        saved.addAll(
            jsonDecode(await index.readAsString()) as Map<String, dynamic>);
      }
    } on Exception {
      // Hash cache is optional.
    } on TypeError {
      // Ignore an old cache schema.
    }
    final sizes = <int, List<StorageEntry>>{};
    for (final entry in entries) {
      if (entry.isFile && entry.size >= 0) {
        (sizes[entry.size] ??= []).add(entry);
      }
    }
    final candidates = sizes.values.where((items) => items.length > 1);
    onTotal?.call(candidates
        .expand((files) => files)
        .fold(0, (n, file) => n + file.size));
    final hashes = <(int, String), List<StorageEntry>>{};
    final next = <String, Object>{};
    final identities = <String>{};
    for (final bucket in candidates) {
      for (final entry in bucket) {
        progress.check();
        progress.describe(storageDisplayPath(entry.path));
        try {
          final identity = await _physicalPath(entry.path);
          if (identities.contains(identity)) {
            progress.add(entry.size);
            continue;
          }
          final cached = saved[entry.path];
          final key = jsonEncode(fingerprint(entry));
          final reusable = (entry.version != 0 ||
                  (entry.identity != null &&
                      entry.modified.millisecondsSinceEpoch > 0)) &&
              cached is List &&
              cached.length == 2 &&
              cached.first == key &&
              cached.last is String &&
              unchanged(entry, await storage.stat(entry.path));
          final String value;
          if (reusable) {
            value = cached.last as String;
            progress.add(entry.size);
          } else {
            value = await digest(entry, progress);
          }
          identities.add(identity);
          (hashes[(entry.size, value)] ??= []).add(entry);
          if (next.length < 16000) next[entry.path] = [key, value];
        } on TransferCancelled {
          rethrow;
        } on Exception {
          skipped++;
        }
      }
    }
    final result = [
      for (final group in hashes.entries)
        if (group.value.length > 1) DuplicateGroup(group.key.$2, group.value),
    ]..sort((a, b) => b.reclaimable.compareTo(a.reclaimable));
    verified = result;
    try {
      await writeStorageRecord(index, next);
    } on FileSystemException {
      // Detection still works when the optional cache is unavailable.
    }
    return result;
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
