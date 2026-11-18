import 'dart:async';
import 'dart:io';

import 'package:file_manager/file_catalog.dart';
import 'package:file_manager/storage.dart';
import 'package:file_manager/thumbnail_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory work, source;
  File file(String name) => File(p.join(source.path, name));
  setUp(() async {
    work = await Directory.systemTemp.createTemp('fm-loading-test-');
    source = await Directory(p.join(work.path, 'source')).create();
  });
  tearDown(() => work.delete(recursive: true));

  test('loads all 5000 entries and retains unchanged metadata when adding one',
      () async {
    for (var i = 0; i < 5000; i++) {
      file('file-$i.txt').writeAsStringSync('known');
    }
    final catalog = FileCatalog(Storage(), source.path, watch: false);
    final before = await catalog.refresh(source.path);
    expect(before, hasLength(5000));
    final added = await file('new.txt').writeAsString('new!');
    catalog.markPath(added.path);
    final after = await catalog.refresh(source.path);
    expect(after, hasLength(5001));
    final byPath = {for (final entry in after) entry.path: entry};
    expect(byPath[added.path]?.size, 4);
    for (final entry in before) {
      expect(identical(entry, byPath[entry.path]), isTrue);
    }
  });

  test(
      'persisted rows appear immediately and resume reconciles edit, rename and removal',
      () async {
    final kept = await file('edit.png').writeAsString('old');
    final rename = await file('rename.txt').writeAsString('old');
    final remove = await file('remove.txt').writeAsString('old');
    final cache = Directory(p.join(work.path, 'private'));
    final first =
        FileCatalog(Storage(), source.path, directory: cache, watch: false);
    expect(await first.refresh(source.path), hasLength(3));
    await first.save();

    await kept.writeAsString('longer content');
    await rename.rename(file('renamed.txt').path);
    await remove.delete();
    final reopened =
        FileCatalog(Storage(), source.path, directory: cache, watch: false);
    await reopened.ready;
    expect(reopened.cached(source.path)!.map((e) => p.basename(e.path)),
        unorderedEquals(['edit.png', 'rename.txt', 'remove.txt']));
    final rows =
        await reopened.refresh(source.path, priority: true, audit: true);
    expect(rows.map((e) => p.basename(e.path)),
        unorderedEquals(['edit.png', 'renamed.txt']));
    expect(rows.singleWhere((e) => e.path == kept.path).size, 14);
    await reopened.save();
  });

  test('fallback discovers a new download without a watcher', () async {
    final catalog = FileCatalog(Storage(), source.path, watch: false);
    final previous = await file('keep.txt').writeAsString('existing');
    await catalog.refresh(source.path);
    final original = catalog.cached(source.path)!.single;
    // A millisecond-resolution directory timestamp needs a different tick.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final downloaded = await file('download.pdf').writeAsString('new file');
    final rows = await catalog.refresh(source.path);
    expect(rows.map((entry) => entry.path),
        unorderedEquals([previous.path, downloaded.path]));
    expect(rows.singleWhere((entry) => entry.path == previous.path),
        same(original));
  });

  test('watches external writes, including same-name replacement and deletion',
      () async {
    final catalog = FileCatalog(Storage(), source.path);
    addTearDown(() => catalog.setForeground(false));
    final target = await file('image.jpg').writeAsString('old!');
    final rows = await catalog.refresh(source.path, priority: true);
    final event = catalog.changes.firstWhere((path) => path == source.path);
    await target.writeAsString('new and longer');
    await event.timeout(const Duration(seconds: 4));
    final update = await catalog.refresh(source.path, priority: true);
    expect(update.single.size, 14);
    expect(update.single.version, isNot(rows.single.version));
    final deleted = catalog.changes.firstWhere((path) => path == source.path);
    await target.delete();
    await deleted.timeout(const Duration(seconds: 4));
    expect(await catalog.refresh(source.path, priority: true), isEmpty);
  }, skip: !FileSystemEntity.isWatchSupported);

  test(
      'dirty category updates add nested files and stop before filtered subtrees',
      () async {
    final visible = Directory(p.join(source.path, 'visible'))..createSync();
    for (final name in ['.hidden', 'Android', '.FMTrash']) {
      final dir = Directory(p.join(source.path, name))..createSync();
      File(p.join(dir.path, 'ignore.jpg')).writeAsStringSync('hidden');
    }
    final old = File(p.join(visible.path, 'old.mp4'))..writeAsStringSync('old');
    final catalog = FileCatalog(Storage(), source.path, watch: false);
    final roots = [CatalogRoot(source.path)];
    await Future.wait([catalog.refreshTree(roots), catalog.refreshTree(roots)]);
    final oldMetadata = catalog.cachedTree(roots)!.single;
    expect(oldMetadata.path, old.path);

    final folder = Directory(p.join(visible.path, 'Mới'))..createSync();
    final fresh = File(p.join(folder.path, 'Tài liệu.pdf'))
      ..writeAsStringSync('new');
    catalog.markPath(folder.path);
    await catalog.refreshTree(roots);
    expect(catalog.cachedTree(roots)!.map((entry) => entry.path),
        unorderedEquals([old.path, fresh.path]));
    expect(
        catalog
            .cachedTree(roots)!
            .firstWhere((entry) => entry.path == old.path),
        same(oldMetadata));
  });

  test('cache failure does not prevent browsing', () async {
    final cache = await Directory(p.join(work.path, 'private')).create();
    await File(p.join(cache.path, 'file-catalog-v1.json'))
        .writeAsString('{"old":[1,[[2]]]}');
    await file('present').create();
    final index =
        FileCatalog(Storage(), source.path, directory: cache, watch: false);
    await index.ready;
    expect(await index.refresh(source.path), hasLength(1));
    await index.save();
  });

  test(
      'thumbnail cache persists across instances and invalidates changed identity',
      () async {
    final media = await file('sample.mp4').writeAsString('video metadata');
    final entry = (await Storage().stat(media.path))!;
    final cacheDir = Directory(p.join(work.path, 'previews'));
    var calls = 0;
    Future<ThumbnailPreview> generate(
        StorageEntry entry, String kind, File out) async {
      calls++;
      await out.writeAsString('content');
      return ThumbnailPreview(out.path, 300);
    }

    final cache = ThumbnailCache(cacheDir, generate);
    final first = await cache.request(entry, 'video').result;
    cache.setForeground(false);
    final reopened = ThumbnailCache(cacheDir, generate);
    final repeated = await reopened.request(entry, 'video').result;
    expect(repeated.path, first.path);
    expect(repeated.duration, 300);
    expect(calls, 1);
    final changed = StorageEntry(
        entry.path, entry.type, entry.size, entry.modified,
        version: entry.version + 1);
    expect((await reopened.request(changed, 'video').result).path,
        isNot(first.path));
    expect(calls, 2);
    reopened.setForeground(false);
  });

  test('thumbnail work is bounded, deduplicated, cancelled and paused',
      () async {
    final releases = <Completer<void>>[];
    var active = 0, peak = 0;
    final generated = <String>[];
    final cache = ThumbnailCache(Directory(p.join(work.path, 'previews')),
        (entry, kind, out) async {
      generated.add(entry.path);
      if (++active > peak) peak = active;
      final gate = Completer<void>();
      releases.add(gate);
      await gate.future;
      await out.writeAsString('ready');
      active--;
      return ThumbnailPreview(out.path);
    });
    final entries = [
      for (var i = 0; i < 5; i++)
        StorageEntry(file('image-$i').path, FileSystemEntityType.file, i,
            DateTime(2025)),
    ];
    final one = cache.request(entries[0], 'image');
    final duplicate = cache.request(entries[0], 'image');
    final two = cache.request(entries[1], 'image');
    final cancelled = cache.request(entries[2], 'image');
    cancelled.cancel();
    final queued = cache.request(entries[3], 'image');
    for (var i = 0; i < 100 && releases.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(releases, hasLength(2));
    cache.setForeground(false);
    for (final release in releases) {
      release.complete();
    }
    await Future.wait([one.result, duplicate.result, two.result]);
    expect((await cancelled.result).path, isNull);
    expect(generated, hasLength(2));
    cache.setForeground(true);
    for (var i = 0; i < 100 && releases.length < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(releases, hasLength(3));
    releases.last.complete();
    await queued.result;
    expect(peak, 2);
    expect(generated,
        unorderedEquals([entries[0].path, entries[1].path, entries[3].path]));
    cache.setForeground(false);
  });

  test(
      'thumbnail cleanup evicts only cache entries beyond the configured limit',
      () async {
    final cacheDir = Directory(p.join(work.path, 'previews'));
    final sourceFile = await file('original.jpg').writeAsString('untouched');
    final cache = ThumbnailCache(cacheDir, (entry, kind, out) async {
      await out.writeAsString('preview');
      return ThumbnailPreview(out.path);
    }, entryLimit: 2);
    for (var i = 0; i < 5; i++) {
      await cache
          .request(
              StorageEntry(sourceFile.path, FileSystemEntityType.file, i,
                  DateTime(2025)),
              'image')
          .result;
    }
    await cache.trim();
    expect(cacheDir.listSync().where((file) => file.path.endsWith('.img')),
        hasLength(2));
    expect(await sourceFile.readAsString(), 'untouched');
    cache.setForeground(false);
  });
}
