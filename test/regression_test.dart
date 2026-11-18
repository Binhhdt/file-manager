import 'dart:convert';
import 'dart:io';

import 'package:file_manager/file_operations.dart';
import 'package:file_manager/main.dart' as app;
import 'package:file_manager/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class FakePlayer extends VideoPlayerPlatform {
  final opened = <String>[];
  int plays = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    opened.add(options.dataSource.uri!);
    return opened.length;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => Stream.value(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(minutes: 1),
          size: const Size(640, 360),
        ),
      );

  @override
  Future<void> dispose(int playerId) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> play(int playerId) async => plays++;

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox(
        key: ValueKey('video surface'),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fm-regression-');
    SharedPreferences.setMockInitialValues({});
    app.prefs = await SharedPreferences.getInstance();
    app.operations =
        FileOperations(app.storage, Directory(p.join(temp.path, 'journal')));
  });
  tearDown(() => temp.delete(recursive: true));

  test('Vietnamese search and existing category extensions are preserved', () {
    expect(app.noAccent('Đường Mưa Hà Nội'), 'duong mua ha noi');
    expect(app.noAccent('TÀI LIỆU'), 'tai lieu');
    expect(app.catOf('Ảnh.PNG')?.name, 'Hình');
    expect(app.catOf('video.mp4')?.name, 'Video');
    expect(app.catOf('Nhạc.flac')?.name, 'Âm thanh');
    expect(app.catOf('Văn bản.pdf')?.name, 'Sách');
    expect(app.catOf('Lưu trữ.zip')?.name, 'Đã nén');
  });

  test('ZIP creation and extraction keep nested and individual files',
      () async {
    final file = File(p.join(temp.path, 'folder', 'deep', 'file.txt'));
    await file.parent.create(recursive: true);
    await file.writeAsString('nested data');
    final single = await File(p.join(temp.path, 'single.txt'))
        .writeAsString('single data');
    final zip = p.join(temp.path, 'files.zip');
    final output = p.join(temp.path, 'extracted');

    await app.zipPaths([p.join(temp.path, 'folder'), single.path], zip);
    expect(await File(zip).length(), greaterThan(0));
    await app.unzipTo(zip, output);

    expect(
        await File(p.join(output, 'folder', 'deep', 'file.txt')).readAsString(),
        'nested data');
    expect(
        await File(p.join(output, 'single.txt')).readAsString(), 'single data');
  });

  testWidgets('opening a local image still routes to the built-in viewer',
      (tester) async {
    final path = p.join(temp.path, 'photo.png');
    File(path).writeAsBytesSync(base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jGKsAAAAASUVORK5CYII=',
    ));
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                  onPressed: () => app.openFile(context, path),
                  child: const Text('Open'),
                ))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(app.ImageViewerPage), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'opening local music and video still plays through the existing player UI',
      (tester) async {
    final previous = VideoPlayerPlatform.instance;
    final player = FakePlayer();
    VideoPlayerPlatform.instance = player;
    addTearDown(() => VideoPlayerPlatform.instance = previous);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(app.nativeCh, (_) async => true);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(app.nativeCh, null));
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Column(children: [
                  TextButton(
                      onPressed: () =>
                          app.openFile(context, p.join(temp.path, 'song.mp3')),
                      child: const Text('Music')),
                  TextButton(
                      onPressed: () =>
                          app.openFile(context, p.join(temp.path, 'clip.mp4')),
                      child: const Text('Video')),
                ]))));
    await tester.tap(find.text('Music'));
    await tester.pumpAndSettle();
    expect(find.byType(app.PlayerPage), findsOneWidget);
    expect(find.byIcon(Icons.music_note), findsOneWidget);
    await tester.tap(find.byTooltip('Quay lại'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Video'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('video surface')), findsOneWidget);
    expect(player.opened.map((uri) => p.basename(Uri.parse(uri).toFilePath())),
        ['song.mp3', 'clip.mp4']);
    expect(player.plays, 2);
    await tester.tap(find.byTooltip('Quay lại'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('folder browser creates, enters and leaves a local folder',
      (tester) async {
    Future<void> waitFor(Finder finder) async {
      for (var attempt = 0;
          attempt < 10 && finder.evaluate().isEmpty;
          attempt++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(finder, findsWidgets);
    }

    final base = Directory(p.join(temp.path, 'browse'))..createSync();
    await tester.pumpWidget(MaterialApp(
        home: app.BrowserPage(mode: app.Mode.dir, path: base.path)));
    await waitFor(find.text('Thư mục trống. Nhấn + để thêm.'));
    await tester.tap(find.byTooltip('Thêm mới'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Thư mục mới'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Mục thử');
    await tester.tap(find.text('OK'));
    await tester.pump();
    await waitFor(find.text('Đã tạo thư mục'));
    await waitFor(find.text('Mục thử'));
    expect(Directory(p.join(base.path, 'Mục thử')).existsSync(), isTrue);
    await tester.tap(find.text('Mục thử').first);
    await waitFor(find.text('Thư mục trống. Nhấn + để thêm.'));
    await tester.binding.handlePopRoute();
    await waitFor(find.text('Mục thử'));
    await tester.pumpWidget(const SizedBox());
  });

  test('SD tree paths display their names and preserve encoded document IDs',
      () {
    final root =
        '$safPrefix${Uri.encodeComponent('content://com.android.externalstorage.documents/tree/ABCD%3AMedia')}';
    expect(storageDisplayPath(p.join(root, 'Mưa', 'ảnh.png')),
        'ABCD/Media/Mưa/ảnh.png');
    expect(storageDisplayName(root), 'Media');
  });
}
