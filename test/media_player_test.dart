import 'package:file_manager/media_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const first = '/storage/emulated/0/Download/one.mp3';
const second = '/@saf/tree/two.flac';
const video = '/storage/emulated/0/Download/movie.mp4';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestDefaultBinaryMessenger messenger;
  late MediaPlayback playback;
  late List<MethodCall> commands;
  late int openActions;

  setUp(() {
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    playback = MediaPlayback();
    commands = [];
    openActions = 0;
    messenger.setMockMethodCallHandler(
        const MethodChannel('fm/media-events'), (_) async => null);
    messenger.setMockMethodCallHandler(mediaCommands, (call) async {
      commands.add(call);
      switch (call.method) {
        case 'queue':
          return [first, second];
        case 'pip':
          return true;
        default:
          return null;
      }
    });
    playback.connect(() => openActions++);
  });

  tearDown(() {
    playback.dispose();
    messenger.setMockMethodCallHandler(
        const MethodChannel('fm/media-events'), null);
    messenger.setMockMethodCallHandler(mediaCommands, null);
  });

  Future<void> emit(Map<String, Object?> value) async {
    await messenger.handlePlatformMessage(
      mediaEvents.name,
      const StandardMethodCodec().encodeSuccessEnvelope(value),
      (_) {},
    );
  }

  Map<String, Object?> music({String path = first, bool playing = true}) => {
        'path': path,
        'title': path == first ? 'Tên bài hát' : 'FLAC từ thẻ nhớ',
        'artist': 'Ca sĩ',
        'album': 'Album',
        'ready': true,
        'playing': playing,
        'wantsPlay': playing,
        'duration': 62000,
        'position': 20000,
        'speed': 1.0,
        'index': path == first ? 0 : 1,
        'next': path == first,
        'previous': path == second,
      };

  Map<String, Object?> movie(
          {bool background = false, bool pip = false, int resume = 0}) =>
      {
        'path': video,
        'title': 'Video',
        'video': true,
        'playing': resume == 0,
        'wantsPlay': resume == 0,
        'duration': 82000,
        'position': 26000,
        'ready': true,
        'supportsPip': true,
        'background': background,
        'pip': pip,
        'resume': resume,
      };

  Widget app({List<String>? paths, bool isVideo = false}) => MaterialApp(
          home: Scaffold(
        body: Builder(
            builder: (context) => TextButton(
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => AndroidMediaPage(
                          playback: playback,
                          paths: paths,
                          video: isVideo,
                          oldPositions: const {video: 21000},
                          testVideoSurface: const ColoredBox(
                              key: Key('fake video'), color: Colors.blue),
                          openExternal: (_, __) async {},
                          share: (_, __) async {},
                        ),
                      )),
                  child: const Text('Mở'),
                )),
      ));

  test(
      'shares native state with system notification and passes SAF paths untouched',
      () async {
    await playback.open([first, second], 1, false, const {});
    expect(commands.single.arguments, {
      'paths': [first, second],
      'index': 1,
      'video': false
    });
    await emit(music(path: second));
    expect(playback.state.title, 'FLAC từ thẻ nhớ');
    expect(playback.state.subtitle, 'Ca sĩ · Album');
    expect(playback.state.previous, isTrue);
    expect(playback.state.duration, 62000);
    await emit({'openPlayer': true});
    expect(openActions, 1);
    expect(playback.state.path, second);
  });

  testWidgets(
      'music controls keep native queue active while full screen closes and reopens',
      (tester) async {
    await emit(music());
    await tester.pumpWidget(app(paths: [first, second]));
    await tester.tap(find.text('Mở'));
    await tester.pumpAndSettle();
    expect(find.text('Ca sĩ · Album'), findsOneWidget);
    expect(commands.where((call) => call.method == 'open').length, 1);
    await tester.tap(find.byTooltip('Tới 10 giây'));
    await tester.tap(find.byTooltip('Bài sau'));
    await tester.tap(find.byTooltip('Phát ngẫu nhiên'));
    await tester.tap(find.byTooltip('Tắt lặp'));
    expect(commands.last.method, 'repeat');
    expect(commands.firstWhere((call) => call.method == 'seek').arguments,
        {'position': 30000});
    expect(commands.any((call) => call.method == 'next'), isTrue);
    expect(commands.any((call) => call.method == 'shuffle'), isTrue);
    await tester.tap(find.byTooltip('Danh sách phát'));
    await tester.pumpAndSettle();
    expect(find.text('two.flac'), findsOneWidget);
    await tester.tap(find.text('two.flac'));
    await tester.pumpAndSettle();
    expect(commands.last.arguments, {'index': 1});
    await emit(music(path: second));
    await tester.pumpAndSettle();
    expect(find.text('FLAC từ thẻ nhớ'), findsWidgets);
    await tester.tap(find.byTooltip('Quay lại'));
    await tester.pumpAndSettle();
    expect(playback.fullPlayerVisible, isFalse);
    expect(commands.last.method, 'hide');
    expect(commands.any((call) => call.method == 'stop'), isFalse);
    await tester.pumpWidget(app());
    await tester.tap(find.text('Mở'));
    await tester.pumpAndSettle();
    expect(find.text('FLAC từ thẻ nhớ'), findsWidgets);
    expect(commands.where((call) => call.method == 'open').length, 1);
    await tester.tap(find.byTooltip('Quay lại'));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'video resume, background audio and PiP use the same active session',
      (tester) async {
    await tester.pumpWidget(app(paths: [video], isVideo: true));
    await tester.tap(find.text('Mở'));
    await tester.pump();
    await emit(movie(resume: 21000));
    await tester.pumpAndSettle();
    expect(find.text('Xem tiếp?'), findsOneWidget);
    final request = commands.firstWhere((call) => call.method == 'open');
    expect(request.arguments['legacy'], {video: 21000});
    await tester.tap(find.text('Xem tiếp'));
    await tester.pumpAndSettle();
    expect(commands.firstWhere((call) => call.method == 'resume').arguments,
        {'keep': true});

    await emit(movie());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fake video')), findsOneWidget);
    await tester.tap(find.byTooltip('Tuỳ chọn phát'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, 'Phát âm thanh nền'));
    await tester.pumpAndSettle();
    expect(commands.last.method, 'background');
    await emit(movie(background: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Cửa sổ nổi (PiP)'));
    expect(commands.last.method, 'pip');
    await emit(movie(background: true, pip: true));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Tuỳ chọn phát'), findsNothing);
    expect(find.byKey(const Key('fake video')), findsOneWidget);
    await emit(movie(background: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Quay lại'));
    await tester.pumpAndSettle();
    expect(commands.where((call) => call.method == 'open').length, 1);
    expect(playback.state.position, 26000);
  });

  testWidgets('mini player stops and toggles the authoritative session',
      (tester) async {
    await emit(music(playing: false));
    var opened = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      bottomNavigationBar:
          MediaMiniPlayer(playback: playback, openPlayer: () => opened = true),
    )));
    await tester.tap(find.byTooltip('Phát'));
    await tester.tap(find.byTooltip('Mở trình phát'));
    await tester.tap(find.byTooltip('Dừng phát'));
    expect(opened, isTrue);
    expect(commands.map((call) => call.method), ['toggle', 'stop']);
  });
}
