import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

const mediaCommands = MethodChannel('fm/media');
const mediaEvents = EventChannel('fm/media-events');

class PlaybackState {
  final Map<Object?, Object?> _data;
  const PlaybackState([this._data = const {}]);

  String? _text(String key) => _data[key] as String?;
  int _int(String key) => (_data[key] as num?)?.toInt() ?? 0;
  bool _flag(String key) => _data[key] == true;

  String? get path => _text('path');
  String? get lastMusic => _text('lastMusic');
  String get title =>
      _text('title') ?? (path == null ? lastMusic ?? '' : p.basename(path!));
  String? get artist => _text('artist');
  String? get album => _text('album');
  String? get artwork => _text('artwork');
  String? get error => _text('error');
  int get position => _int('position');
  int get duration => _int('duration');
  int get index => _int('index');
  int get width => _int('width');
  int get height => _int('height');
  int get repeat => _int('repeat');
  int get resume => _int('resume');
  double get speed => (_data['speed'] as num?)?.toDouble() ?? 1.0;
  bool get video => _flag('video');
  bool get playing => _flag('playing');
  bool get wantsPlay => _flag('wantsPlay');
  bool get ready => _flag('ready');
  bool get background => _flag('background');
  bool get pip => _flag('pip');
  bool get supportsPip => _flag('supportsPip');
  bool get previous => _flag('previous');
  bool get next => _flag('next');
  bool get shuffle => _flag('shuffle');
  bool get hasMedia => path != null || lastMusic != null;

  String get subtitle => [
        if (artist case final value? when value.isNotEmpty) value,
        if (album case final value? when value.isNotEmpty) value,
      ].join(' · ');
}

class MediaPlayback extends ChangeNotifier {
  PlaybackState state = const PlaybackState();
  StreamSubscription<dynamic>? _subscription;
  int _nextPage = 0;
  int? _page;
  String? commandError;

  bool get fullPlayerVisible => _page != null;

  void connect(VoidCallback requestFullPlayer) {
    _subscription ??= mediaEvents.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        if (event['openPlayer'] == true) {
          requestFullPlayer();
          return;
        }
        state = PlaybackState(event);
        notifyListeners();
      },
      onError: (Object error) {
        commandError = 'Không kết nối được phiên phát Android.';
        notifyListeners();
      },
    );
  }

  int showPage() {
    final token = ++_nextPage;
    _page = token;
    unawaited(command('show', {'view': token}));
    _notifyAfterFrame();
    return token;
  }

  void hidePage(int token) {
    if (_page != token) return;
    _page = null;
    unawaited(command('hide', {'view': token}));
    _notifyAfterFrame();
  }

  void _notifyAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) => notifyListeners());
  }

  Future<T?> command<T>(String name, [Map<String, Object?>? args]) async {
    try {
      final result = await mediaCommands.invokeMethod<T>(name, args);
      if (commandError != null) {
        commandError = null;
        notifyListeners();
      }
      return result;
    } on PlatformException catch (error) {
      commandError = error.message ?? 'Không thực hiện được thao tác phát.';
    } on MissingPluginException {
      commandError = 'Trình phát nền chỉ có trong bản Android của ứng dụng.';
    }
    notifyListeners();
    return null;
  }

  Future<void> open(
      List<String> paths, int index, bool video, Map<String, int> oldPositions,
      {int? page, bool? shuffle}) {
    commandError = null;
    return command<void>('open', {
      'paths': paths,
      'index': index,
      'video': video,
      if (page != null) 'view': page,
      if (shuffle != null) 'shuffle': shuffle,
      if (video) 'legacy': oldPositions,
    });
  }

  Future<List<String>> queue() async =>
      (await command<List<dynamic>>('queue'))?.cast<String>() ?? const [];

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}

final mediaPlayback = MediaPlayback();

String _time(int ms) {
  final seconds = Duration(milliseconds: ms).inSeconds;
  String two(int n) => n.toString().padLeft(2, '0');
  final h = seconds ~/ 3600;
  final m = two(seconds ~/ 60 % 60);
  final s = two(seconds % 60);
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

Widget _art(String? path, double size, {required bool video}) {
  final fallback = Icon(
    video ? Icons.videocam : Icons.music_note,
    size: size * 0.52,
  );
  if (path == null)
    return SizedBox.square(
      dimension: size,
      child: Center(child: fallback),
    );
  return Image.file(
    File(path),
    width: size,
    height: size,
    fit: BoxFit.cover,
    cacheWidth: size > 80 ? 360 : 100,
    errorBuilder: (_, __, ___) => SizedBox.square(
      dimension: size,
      child: Center(child: fallback),
    ),
  );
}

class MediaMiniPlayer extends StatelessWidget {
  final MediaPlayback playback;
  final VoidCallback openPlayer;
  const MediaMiniPlayer({
    super.key,
    required this.playback,
    required this.openPlayer,
  });

  @override
  Widget build(BuildContext context) {
    final state = playback.state;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      elevation: 3,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              const SizedBox(width: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: _art(state.artwork, 42, video: state.video),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: InkWell(
                  onTap: openPlayer,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        state.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (state.lastMusic != null ||
                          state.subtitle.isNotEmpty ||
                          state.video && state.background)
                        Text(
                          state.lastMusic != null
                              ? 'Tiếp tục nghe'
                              : (state.video && state.background
                                  ? 'Phát âm thanh nền'
                                  : state.subtitle),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: state.wantsPlay ? 'Tạm dừng' : 'Phát',
                icon: Icon(state.wantsPlay ? Icons.pause : Icons.play_arrow),
                onPressed: () => playback.command<void>('toggle'),
              ),
              IconButton(
                tooltip: 'Mở trình phát',
                icon: const Icon(Icons.open_in_full),
                onPressed: openPlayer,
              ),
              IconButton(
                tooltip: 'Dừng phát',
                icon: const Icon(Icons.stop),
                onPressed: () => playback.command<void>('stop'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

typedef OpenMediaExternally = Future<void> Function(
  BuildContext context,
  String path,
);
typedef ShareMedia = Future<void> Function(
  BuildContext context,
  List<String> paths,
);

class AndroidMediaPage extends StatefulWidget {
  final MediaPlayback playback;
  final List<String>? paths;
  final int index;
  final bool video;
  final Map<String, int> oldPositions;
  final OpenMediaExternally openExternal;
  final ShareMedia share;
  final Widget? testVideoSurface;
  final bool? shuffle;

  const AndroidMediaPage({
    super.key,
    required this.playback,
    this.paths,
    this.index = 0,
    this.video = false,
    this.oldPositions = const {},
    this.shuffle,
    required this.openExternal,
    required this.share,
    this.testVideoSurface,
  });

  @override
  State<AndroidMediaPage> createState() => _AndroidMediaPageState();
}

class _AndroidMediaPageState extends State<AndroidMediaPage> {
  MediaPlayback get playback => widget.playback;
  late final int _token;
  bool _controls = true;
  bool _requested = false;
  bool _resumeDialog = false;
  bool _rotationLocked = false;
  bool? _landscape;
  String? _orientationPath;
  double? _dragPosition;

  @override
  void initState() {
    super.initState();
    playback.addListener(_stateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _token = playback.showPage();
      _requested = true;
      final paths = widget.paths;
      if (paths != null) {
        unawaited(
          playback.open(paths, widget.index, widget.video, widget.oldPositions,
              page: _token, shuffle: widget.shuffle),
        );
      } else if (playback.state.path == null &&
          playback.state.lastMusic != null) {
        unawaited(playback.command<void>('restore'));
      }
      _stateChanged();
    });
  }

  @override
  void dispose() {
    playback.removeListener(_stateChanged);
    if (_requested) playback.hidePage(_token);
    if (_landscape != null) {
      unawaited(playback.command<void>('fullscreen', {'enabled': false}));
      unawaited(
        SystemChrome.setPreferredOrientations(DeviceOrientation.values),
      );
    }
    super.dispose();
  }

  void _stateChanged() {
    if (!mounted || !_requested) return;
    final state = playback.state;
    if (state.video &&
        state.width > 0 &&
        state.height > 0 &&
        !state.pip &&
        !_rotationLocked &&
        _orientationPath != state.path) {
      _orientationPath = state.path;
      _rotate(state.width > state.height);
    }
    if (_dragPosition != null && state.path != _dragPath) _dragPosition = null;
    if (state.resume > 0 && !_resumeDialog && !state.pip) {
      _resumeDialog = true;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_askResume(state)),
      );
    }
    setState(() {});
  }

  String? _dragPath;

  Future<void> _askResume(PlaybackState state) async {
    if (!mounted ||
        playback.state.path != state.path ||
        playback.state.resume != state.resume) {
      _resumeDialog = false;
      return;
    }
    final keep = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialog) => AlertDialog(
        title: const Text('Xem tiếp?'),
        content: Text('Lần trước bạn dừng ở ${_time(state.resume)}.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Xem từ đầu'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Xem tiếp'),
          ),
        ],
      ),
    );
    if (mounted &&
        playback.state.path == state.path &&
        playback.state.resume == state.resume) {
      await playback.command<void>('resume', {'keep': keep ?? true});
    }
    _resumeDialog = false;
  }

  void _rotate(bool landscape) {
    _landscape = landscape;
    unawaited(
      SystemChrome.setPreferredOrientations(
        landscape
            ? [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown],
      ),
    );
    unawaited(playback.command<void>('fullscreen', {'enabled': true}));
  }

  Future<void> _queue() async {
    final tracks = await playback.queue();
    if (!mounted || tracks.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheet).height * 0.65,
          child: Column(
            children: [
              Text(
                'Danh sách phát',
                style: Theme.of(sheet).textTheme.titleLarge,
              ),
              Expanded(
                child: ListenableBuilder(
                  listenable: playback,
                  builder: (_, __) => ListView.builder(
                    itemCount: tracks.length,
                    itemBuilder: (_, index) => ListTile(
                      leading: Icon(
                        index == playback.state.index
                            ? Icons.equalizer
                            : Icons.audiotrack,
                      ),
                      selected: index == playback.state.index,
                      title: Text(
                        p.basename(tracks[index]),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        Navigator.pop(sheet);
                        playback.command<void>('select', {'index': index});
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pip() async {
    if (await playback.command<bool>('pip') != true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Android chưa cho phép mở cửa sổ nổi.')),
      );
    }
  }

  Future<void> _stop() async {
    await playback.command<void>('stop');
    if (mounted) Navigator.maybePop(context);
  }

  @override
  Widget build(BuildContext context) {
    final state = playback.state;
    final path = state.path;
    final error = state.error ?? playback.commandError;
    final video = path != null ? state.video : widget.video;
    final title = state.title.isNotEmpty
        ? state.title
        : (widget.paths == null
            ? 'Trình phát'
            : p.basename(widget.paths![widget.index]));
    final bars = !state.pip && (!video || _controls || error != null);
    final ratio = state.width > 0 && state.height > 0
        ? state.width / state.height
        : 16 / 9;
    Widget center;
    if (error != null) {
      center = Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.white70, size: 48),
            const SizedBox(height: 12),
            Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
            if (path != null) ...[
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => widget.openExternal(context, path),
                child: const Text('Mở bằng ứng dụng khác'),
              ),
            ],
          ],
        ),
      );
    } else if (path == null || !state.ready && video) {
      center = const CircularProgressIndicator(color: Colors.white);
    } else if (video) {
      center = AspectRatio(
        aspectRatio: ratio,
        child: widget.testVideoSurface ??
            const AndroidView(
              viewType: 'fm/media-video',
              hitTestBehavior: PlatformViewHitTestBehavior.transparent,
            ),
      );
    } else {
      center = LayoutBuilder(
        builder: (_, constraints) {
          final artSize = (constraints.maxHeight * 0.42).clamp(80.0, 250.0);
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: ColoredBox(
                  color: const Color(0xFF7A52E8),
                  child: _art(state.artwork, artSize, video: false),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 18),
                ),
              ),
              if (state.subtitle.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    state.subtitle,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
            ],
          );
        },
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: video
                  ? EdgeInsets.zero
                  : const EdgeInsets.only(top: 55, bottom: 122),
              child: Center(child: center),
            ),
          ),
          if (video && !state.pip && error == null)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => setState(() => _controls = !_controls),
                onVerticalDragEnd: (_) =>
                    setState(() => _controls = !_controls),
              ),
            ),
          if (bars)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: ColoredBox(
                color: Colors.black54,
                child: SafeArea(
                  bottom: false,
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Quay lại',
                        color: Colors.white,
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => Navigator.maybePop(context),
                      ),
                      Expanded(
                        child: Text(
                          title,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      if (path != null)
                        IconButton(
                          tooltip: 'Chia sẻ',
                          color: Colors.white,
                          icon: const Icon(Icons.share),
                          onPressed: () => widget.share(context, [path]),
                        ),
                      if (video && state.supportsPip)
                        IconButton(
                          tooltip: 'Cửa sổ nổi (PiP)',
                          color: Colors.white,
                          icon: const Icon(Icons.picture_in_picture_alt),
                          onPressed: state.ready ? _pip : null,
                        ),
                      if (video)
                        IconButton(
                          tooltip:
                              _landscape == true ? 'Xoay dọc' : 'Xoay ngang',
                          color: Colors.white,
                          icon: const Icon(Icons.screen_rotation),
                          onPressed: () {
                            _rotationLocked = true;
                            setState(() => _rotate(_landscape != true));
                          },
                        ),
                      PopupMenuButton<String>(
                        tooltip: 'Tuỳ chọn phát',
                        iconColor: Colors.white,
                        onSelected: (value) {
                          if (value == 'stop') {
                            _stop();
                          } else {
                            playback.command<void>('background');
                          }
                        },
                        itemBuilder: (_) => [
                          if (video)
                            CheckedPopupMenuItem(
                              value: 'background',
                              checked: state.background,
                              child: const Text('Phát âm thanh nền'),
                            ),
                          const PopupMenuItem(
                            value: 'stop',
                            child: Text('Dừng phát'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (bars && path != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: ColoredBox(
                color: Colors.black54,
                child: SafeArea(top: false, child: _playbackControls(state)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _playbackControls(PlaybackState state) {
    final max = state.duration > 0 ? state.duration.toDouble() : 1.0;
    final position = (_dragPosition ?? state.position.toDouble()).clamp(
      0.0,
      max,
    );
    void seek(int ms) =>
        unawaited(playback.command<void>('seek', {'position': ms}));
    Widget control(
      String tip,
      IconData icon,
      VoidCallback? action, {
      double size = 30,
    }) =>
        IconButton(
          tooltip: tip,
          color: Colors.white,
          iconSize: size,
          icon: Icon(icon),
          onPressed: action,
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Text(
                _time(position.round()),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              Expanded(
                child: Slider(
                  value: position,
                  max: max,
                  activeColor: Colors.white,
                  inactiveColor: Colors.white30,
                  onChanged: state.ready && state.resume == 0
                      ? (value) => setState(() {
                            _dragPath = state.path;
                            _dragPosition = value;
                          })
                      : null,
                  onChangeEnd: (value) {
                    setState(() => _dragPosition = null);
                    seek(value.round());
                  },
                ),
              ),
              Text(
                _time(state.duration),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            control(
              'Bài trước',
              Icons.skip_previous,
              state.previous ? () => playback.command<void>('previous') : null,
            ),
            control(
              'Lùi 10 giây',
              Icons.replay_10,
              state.ready ? () => seek(state.position - 10000) : null,
            ),
            control(
              state.wantsPlay ? 'Tạm dừng' : 'Phát',
              state.wantsPlay
                  ? Icons.pause_circle_filled
                  : Icons.play_circle_filled,
              state.resume == 0 ? () => playback.command<void>('toggle') : null,
              size: 54,
            ),
            control(
              'Tới 10 giây',
              Icons.forward_10,
              state.ready ? () => seek(state.position + 10000) : null,
            ),
            control(
              'Bài sau',
              Icons.skip_next,
              state.next ? () => playback.command<void>('next') : null,
            ),
          ],
        ),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (!state.video) ...[
              IconButton(
                tooltip: 'Phát ngẫu nhiên',
                color: state.shuffle ? Colors.lightBlueAccent : Colors.white,
                icon: const Icon(Icons.shuffle),
                onPressed: () => playback.command<void>('shuffle'),
              ),
              IconButton(
                tooltip: const [
                  'Tắt lặp',
                  'Lặp một bài',
                  'Lặp danh sách',
                ][state.repeat.clamp(0, 2)],
                color:
                    state.repeat == 0 ? Colors.white : Colors.lightBlueAccent,
                icon: Icon(state.repeat == 1 ? Icons.repeat_one : Icons.repeat),
                onPressed: () => playback.command<void>('repeat'),
              ),
              control('Danh sách phát', Icons.queue_music, _queue, size: 24),
            ],
            PopupMenuButton<double>(
              tooltip: 'Tốc độ phát',
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 12,
                ),
                child: Text(
                  '${state.speed}×',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
              onSelected: (speed) =>
                  playback.command<void>('speed', {'speed': speed}),
              itemBuilder: (_) => [
                for (final speed in const [
                  0.5,
                  0.75,
                  1.0,
                  1.25,
                  1.5,
                  1.75,
                  2.0,
                ])
                  CheckedPopupMenuItem(
                    value: speed,
                    checked: state.speed == speed,
                    child: Text('${speed}×'),
                  ),
              ],
            ),
            if (state.video && state.background)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  'Âm thanh nền',
                  style: TextStyle(color: Colors.lightBlueAccent, fontSize: 12),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
