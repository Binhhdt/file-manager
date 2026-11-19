import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'storage.dart';

const previewSize = 384;

class ThumbnailPreview {
  final String? path;
  final int duration;
  const ThumbnailPreview(this.path, [this.duration = 0]);
}

typedef ThumbnailGenerator = Future<ThumbnailPreview> Function(
  StorageEntry entry,
  String kind,
  File output,
);

class ThumbnailRequest {
  final Future<ThumbnailPreview> result;
  final void Function() cancel;
  const ThumbnailRequest(this.result, this.cancel);
}

class _ThumbnailJob {
  final String key, kind;
  final StorageEntry entry;
  final completion = Completer<ThumbnailPreview>();
  int listeners = 0;
  bool running = false;
  _ThumbnailJob(this.key, this.kind, this.entry);
}

class ThumbnailCache {
  final Directory directory;
  final ThumbnailGenerator generate;
  final int byteLimit, entryLimit;
  final _jobs = <String, _ThumbnailJob>{};
  final _queue = <_ThumbnailJob>[];
  late final Future<void> _ready = directory.create(recursive: true);
  int _active = 0, _writes = 0;
  bool _foreground = true;
  Timer? _cleanup;
  DateTime? _lastCleanup;

  ThumbnailCache(
    this.directory,
    this.generate, {
    this.byteLimit = 128 * 1024 * 1024,
    this.entryLimit = 4000,
  });

  static String key(StorageEntry entry, String kind) => sha256
      .convert(utf8.encode(jsonEncode([
        1,
        entry.path,
        entry.size,
        entry.modified.microsecondsSinceEpoch,
        entry.version,
        entry.identity,
        kind,
        previewSize,
      ])))
      .toString();

  ThumbnailRequest request(StorageEntry entry, String kind) {
    final fingerprint = key(entry, kind);
    final job = _jobs.putIfAbsent(
        fingerprint, () => _ThumbnailJob(fingerprint, kind, entry));
    job.listeners++;
    if (!job.running) {
      _queue.remove(job);
      _queue.add(job);
    }
    _pump();
    var cancelled = false;
    return ThumbnailRequest(job.completion.future, () {
      if (cancelled) return;
      cancelled = true;
      if (--job.listeners == 0 && !job.running && _queue.remove(job)) {
        _jobs.remove(fingerprint);
        job.completion.complete(const ThumbnailPreview(null));
      }
    });
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    if (foreground) {
      _pump();
    } else {
      _cleanup?.cancel();
      _cleanup = null;
    }
  }

  void _pump() {
    if (!_foreground) return;
    if (_queue.isNotEmpty) _planCleanup();
    while (_active < 2 && _queue.isNotEmpty) {
      final job = _queue.removeLast();
      job.running = true;
      _active++;
      unawaited(_run(job));
    }
  }

  Future<void> _run(_ThumbnailJob job) async {
    try {
      await _ready;
      job.completion.complete(await _load(job));
    } catch (_) {
      // A missing source or unavailable cache uses the normal icon fallback.
      job.completion.complete(const ThumbnailPreview(null));
    } finally {
      _active--;
      _jobs.remove(job.key);
      _pump();
    }
  }

  Future<ThumbnailPreview> _load(_ThumbnailJob job) async {
    final base = p.join(directory.path, job.key);
    final record = File('$base.json');
    final image = File('$base.img');
    try {
      final data = jsonDecode(await record.readAsString()) as List;
      final written = DateTime.fromMillisecondsSinceEpoch(data[2] as int);
      final hasImage = data[0] as bool;
      if (hasImage
          ? await image.exists()
          : DateTime.now().difference(written) < const Duration(minutes: 5)) {
        if (DateTime.now().difference(await record.lastModified()) >
            const Duration(hours: 12)) {
          await record.setLastModified(DateTime.now());
        }
        return ThumbnailPreview(hasImage ? image.path : null, data[1] as int);
      }
    } on FileSystemException {
      // The record was never written, or was removed by cache maintenance.
    } on FormatException {
      // Regenerate a damaged cache entry.
    } on TypeError {
      // Regenerate an entry with an incompatible schema.
    } on RangeError {
      // Regenerate a truncated entry.
    }

    final temporary = File('$base.img.new');
    final metadata = File('$base.json.new');
    try {
      final preview = await generate(job.entry, job.kind, temporary);
      final hasImage = preview.path != null &&
          await temporary.exists() &&
          await temporary.length() > 0 &&
          await temporary.length() <= 4 * 1024 * 1024;
      if (hasImage) await temporary.rename(image.path);
      await metadata.writeAsString(
          jsonEncode([
            hasImage,
            preview.duration,
            DateTime.now().millisecondsSinceEpoch,
          ]),
          flush: true);
      await metadata.rename(record.path);
      if (++_writes % 50 == 0) _planCleanup(force: true);
      return ThumbnailPreview(hasImage ? image.path : null, preview.duration);
    } finally {
      for (final file in [temporary, metadata]) {
        try {
          if (await file.exists()) await file.delete();
        } on FileSystemException {
          // Idle cleanup collects abandoned temporary files.
        }
      }
    }
  }

  void _planCleanup({bool force = false}) {
    if (_cleanup != null || !_foreground) return;
    final last = _lastCleanup;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < const Duration(hours: 1)) return;
    _cleanup = Timer(const Duration(seconds: 5), () {
      _cleanup = null;
      if (_foreground) unawaited(trim());
    });
  }

  Future<void>? _trimming;
  Future<void> trim() {
    if (_trimming case final active?) return active;
    _lastCleanup = DateTime.now();
    final folder = directory.path, bytes = byteLimit, entries = entryLimit;
    final activeKeys = _jobs.keys.toSet();
    final work = _trimOnWorker(folder, bytes, entries, activeKeys);
    _trimming = work;
    return work.whenComplete(() => _trimming = null);
  }

  static final _cleanupName = RegExp(r'^[0-9a-f]{64}\.(img|json)(\.new)?$');

  bool _canClean(String path, DateTime modified) {
    final name = p.basename(path);
    return p.dirname(path) == directory.path &&
        _cleanupName.hasMatch(name) &&
        !_jobs.containsKey(name.split('.').first) &&
        (!name.endsWith('.new') ||
            DateTime.now().difference(modified) > const Duration(days: 1));
  }

  Future<List<StorageEntry>> cleanupCandidates() async {
    await _ready;
    final found = <StorageEntry>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File) continue;
      final stat = await entry.stat();
      if (stat.type == FileSystemEntityType.file &&
          _canClean(entry.path, stat.modified)) {
        found.add(StorageEntry.local(entry.path, stat));
      }
    }
    return found;
  }

  Future<int> removeCleanupCandidate(StorageEntry entry) async {
    if (_trimming case final active?) await active;
    // Check and unlink together before the Dart worker can start another job.
    final type = FileSystemEntity.typeSync(entry.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return 0;
    final stat = FileStat.statSync(entry.path);
    if (type != FileSystemEntityType.file ||
        !_canClean(entry.path, stat.modified) ||
        stat.size != entry.size ||
        stat.modified != entry.modified ||
        stat.changed.microsecondsSinceEpoch != entry.version) {
      throw FileSystemException(
          'Cache đã thay đổi hoặc đang được dùng', entry.path);
    }
    File(entry.path).deleteSync();
    return stat.size;
  }
}

Future<void> _trimOnWorker(
        String path, int bytes, int entries, Set<String> active) =>
    Isolate.run(() => _trim(path, bytes, entries, active));

void _trim(String path, int byteLimit, int entryLimit, Set<String> active) {
  final now = DateTime.now();
  try {
    final records = <(File, File, DateTime, int)>[];
    for (final entry in Directory(path).listSync(followLinks: false)) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      if (name.endsWith('.new') && !active.contains(name.split('.').first)) {
        if (now.difference(entry.lastModifiedSync()) > const Duration(days: 1))
          entry.deleteSync();
        continue;
      }
      if (!RegExp(r'^[0-9a-f]{64}\.json$').hasMatch(name)) continue;
      final key = p.basenameWithoutExtension(name);
      if (active.contains(key)) continue;
      final data = File(p.join(path, '$key.img'));
      records.add((
        entry,
        data,
        entry.lastModifiedSync(),
        entry.lengthSync() + (data.existsSync() ? data.lengthSync() : 0)
      ));
    }
    records.sort((a, b) => b.$3.compareTo(a.$3));
    var bytes = 0;
    for (var i = 0; i < records.length; i++) {
      final (metadata, image, age, size) = records[i];
      bytes += size;
      if (i < entryLimit &&
          bytes <= byteLimit &&
          now.difference(age) < const Duration(days: 30)) continue;
      if (image.existsSync()) image.deleteSync();
      if (metadata.existsSync()) metadata.deleteSync();
    }
    for (final entry in Directory(path).listSync(followLinks: false)) {
      final name = p.basename(entry.path);
      if (entry is! File || !RegExp(r'^[0-9a-f]{64}\.img$').hasMatch(name))
        continue;
      final key = p.basenameWithoutExtension(name);
      if (!active.contains(key) &&
          !File(p.join(path, '$key.json')).existsSync() &&
          now.difference(entry.lastModifiedSync()) > const Duration(days: 1))
        entry.deleteSync();
    }
  } on FileSystemException {
    // Cache maintenance is best-effort.
  }
}

/// Decode a bounded image for thumbnails only. File viewers still open the original.
Future<void> writeImagePreview(String path, File dest) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(path);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final landscape = descriptor.width >= descriptor.height;
    codec = await descriptor.instantiateCodec(
      targetWidth:
          landscape && descriptor.width > previewSize ? previewSize : null,
      targetHeight:
          !landscape && descriptor.height > previewSize ? previewSize : null,
    );
    final frame = await codec.getNextFrame();
    try {
      final encoded =
          await frame.image.toByteData(format: ui.ImageByteFormat.png);
      if (encoded == null) return;
      await dest.writeAsBytes(Uint8List.sublistView(encoded), flush: true);
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}
