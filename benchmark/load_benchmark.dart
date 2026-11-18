import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_manager/file_catalog.dart';
import 'package:file_manager/storage.dart';
import 'package:file_manager/thumbnail_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// This is the old BrowserPage's data path, including the sequential type and
// stat calls in Storage.children. The source is unchanged on the baseline.
Future<List<StorageEntry>> previousLoad(String path) =>
    Storage().children(path).toList();

Future<double> clock(Future<void> Function() run) async {
  final stopwatch = Stopwatch()..start();
  await run();
  return stopwatch.elapsedMicroseconds / 1000;
}

String median(List<double> values) {
  values.sort();
  return values[values.length ~/ 2].toStringAsFixed(2);
}

Future<void> decodeThumbnail(String path) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(path);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final codec = await descriptor.instantiateCodec(targetWidth: 360);
  final image = await codec.getNextFrame();
  image.image.dispose();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('real local filesystem and Flutter image decoder measurements',
      () async {
    final directory = await Directory.systemTemp.createTemp('fm-benchmark-');
    try {
      for (final count in [1000, 5000]) {
        final path =
            (await Directory(p.join(directory.path, 'items-$count')).create())
                .path;
        for (var i = 0; i < count; i++) {
          final suffix = ['jpg', 'mp4', 'mp3', 'pdf', 'txt'][i % 5];
          File(p.join(path, 'Tập tin $i.$suffix'))
              .writeAsStringSync('fixture $i');
        }
        final openBefore = <double>[], openAfter = <double>[];
        final warmBefore = <double>[], warmAfter = <double>[];
        final reopenAfter = <double>[],
            addedBefore = <double>[],
            addedAfter = <double>[];
        final worker = FileCatalog(Storage(), path, watch: false);
        await worker.refresh(path);
        for (var i = 0; i < 7; i++) {
          final storage = Directory(p.join(directory.path, 'index-$count-$i'));
          final fresh =
              FileCatalog(Storage(), path, directory: storage, watch: false);
          openBefore.add(await clock(
              () async => expect(await previousLoad(path), hasLength(count))));
          openAfter.add(await clock(
              () async => expect(await fresh.refresh(path), hasLength(count))));
          warmBefore.add(await clock(
              () async => expect(await previousLoad(path), hasLength(count))));
          warmAfter.add(await clock(
              () async => expect(await fresh.refresh(path), hasLength(count))));
          await fresh.save();
          reopenAfter.add(await clock(() async {
            final restarted =
                FileCatalog(Storage(), path, directory: storage, watch: false);
            await restarted.ready;
            expect(restarted.cached(path), hasLength(count));
          }));
        }
        if (FileSystemEntity.isWatchSupported) {
          for (var i = 0; i < 3; i++) {
            final oldFile = File(p.join(path, 'download-old-$i.pdf'));
            final newFile = File(p.join(path, 'download-new-$i.pdf'));
            final watcher = FileCatalog(Storage(), path);
            await watcher.refresh(path, priority: true);
            final event =
                watcher.changes.firstWhere((changed) => changed == path);
            addedBefore.add(await clock(() async {
              // The old screen observed membership on a 3-second poll.
              await oldFile.writeAsString('download');
              await Future<void>.delayed(const Duration(seconds: 3));
              expect(
                  await Directory(path)
                      .list(followLinks: false)
                      .any((file) => file.path == oldFile.path),
                  isTrue);
              expect(await previousLoad(path), hasLength(count + 1));
            }));
            await oldFile.delete();
            // Drain the earlier watch event and establish a fresh subscriber
            // before timing the actual download.
            await event;
            await watcher.refresh(path, priority: true);
            final changed = watcher.changes.where((changed) => changed == path);
            final downloaded = Completer<void>();
            final listener = changed.listen((_) async {
              if (await newFile.exists() && !downloaded.isCompleted)
                downloaded.complete();
            });
            addedAfter.add(await clock(() async {
              await newFile.writeAsString('download');
              await downloaded.future.timeout(const Duration(seconds: 4));
              await Future<void>.delayed(const Duration(milliseconds: 160));
              expect(await watcher.refresh(path, priority: true),
                  hasLength(count + 1));
            }));
            await listener.cancel();
            watcher.setForeground(false);
            await newFile.delete();
          }
        }
        print('BENCH dir $count ms '
            'first ${median(openBefore)} -> ${median(openAfter)}, '
            'warm ${median(warmBefore)} -> ${median(warmAfter)}, '
            'restart cache ${median(reopenAfter)}, '
            'new entry ${addedBefore.isEmpty ? 'watch unsupported' : '${median(addedBefore)} -> ${median(addedAfter)}'}');
      }

      final fixture = Platform.environment['FM_BENCH_JPEG'];
      if (fixture == null) {
        print(
            'BENCH image skipped: set FM_BENCH_JPEG to a local JPEG (at least 1920×1080).');
        return;
      }
      final images = <StorageEntry>[];
      for (var i = 0; i < 24; i++) {
        final file =
            await File(fixture).copy(p.join(directory.path, 'sample-$i.jpg'));
        images.add((await Storage().stat(file.path))!);
      }
      final previews = Directory(p.join(directory.path, 'previews'));
      Future<ThumbnailPreview> generate(
          StorageEntry entry, String kind, File out) async {
        await writeImagePreview(entry.path, out);
        return ThumbnailPreview(out.path);
      }

      final initial = ThumbnailCache(previews, generate);
      for (final file in images) {
        expect((await initial.request(file, 'image').result).path, isNotNull);
      }
      initial.setForeground(false);
      final reopened = ThumbnailCache(
          previews, (_, __, ___) async => fail('Expected a disk cache hit'));
      final before = <double>[], after = <double>[];
      for (final file in images) {
        before.add(await clock(() => decodeThumbnail(file.path)));
        after.add(await clock(() async {
          final cache = await reopened.request(file, 'image').result;
          expect(cache.path, isNotNull);
          await decodeThumbnail(cache.path!);
        }));
      }
      reopened.setForeground(false);
      print(
          'BENCH image 24 JPEGs with empty decoded cache, median ms ${median(before)} -> ${median(after)}');
    } finally {
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
