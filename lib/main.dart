import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart' as ar;
import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart' as sp;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

const rootPath = '/storage/emulated/0';
const blue = Color(0xFF3B82E8);
final trashDir = Directory('$rootPath/.FMTrash');
late SharedPreferences prefs;

class Cat {
  final String name;
  final IconData icon;
  final Color color;
  final Set<String> exts;
  const Cat(this.name, this.icon, this.color, this.exts);
}

const cats = <Cat>[
  Cat('Hình', Icons.image, Color(0xFFF09A45), {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'}),
  Cat('Video', Icons.videocam, Color(0xFF3FBFB4), {'mp4', 'mkv', 'mov', 'webm', 'avi', '3gp'}),
  Cat('Âm thanh', Icons.music_note, Color(0xFF7A52E8), {'mp3', 'flac', 'wav', 'm4a', 'ogg', 'aac'}),
  Cat('APP', Icons.android, Color(0xFF4CAE6C), {'apk'}),
  Cat('Sách', Icons.menu_book, Color(0xFFE0A520), {'pdf', 'txt', 'doc', 'docx', 'epub', 'xls', 'xlsx', 'ppt', 'pptx'}),
  Cat('Đã nén', Icons.folder_zip, Color(0xFF4B8FE8), {'zip', 'rar', '7z', 'tar', 'gz'}),
];

class Item {
  final FileSystemEntity e;
  final FileStat s;
  Item(this.e, this.s);
  bool get isDir => e is Directory;
  String get name => p.basename(e.path);
}

class FmClip {
  final List<String> paths;
  final bool cut;
  FmClip(this.paths, this.cut);
}

final clip = ValueNotifier<FmClip?>(null);

// ---------- helpers ----------
String extOf(String path) => p.extension(path).toLowerCase().replaceFirst('.', '');

Cat? catOf(String path) {
  final x = extOf(path);
  for (final c in cats) {
    if (c.exts.contains(x)) return c;
  }
  return null;
}

String fmtSize(num b) {
  if (b < 1024) return '${b.toInt()} B';
  const u = ['KB', 'MB', 'GB', 'TB'];
  var i = -1;
  var v = b.toDouble();
  do {
    v /= 1024;
    i++;
  } while (v >= 1024 && i < u.length - 1);
  return '${v.toStringAsFixed(v < 10 ? 2 : 1)} ${u[i]}';
}

String two(int n) => n.toString().padLeft(2, '0');
String fmtDate(DateTime d) => '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';

bool existsPath(String path) => FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;

String uniquePath(String dir, String name) {
  var c = p.join(dir, name);
  if (!existsPath(c)) return c;
  final b = p.basenameWithoutExtension(name), e = p.extension(name);
  var i = 1;
  while (existsPath(p.join(dir, '$b ($i)$e'))) {
    i++;
  }
  return p.join(dir, '$b ($i)$e');
}

class CancelledException implements Exception {}

/// Trang thai cua mot tac vu dai (sao chep, nen...), dung cho hop thoai tien trinh.
class Job {
  final progress = ValueNotifier<double>(0);
  final label = ValueNotifier<String>('');
  bool cancelled = false;
  int total = 0, done = 0;
  void add(int n) {
    done += n;
    progress.value = total > 0 ? (done / total).clamp(0.0, 1.0) : 0;
  }
}

Future<void> copyEntity(String src, String dest, [Job? job]) async {
  if (job?.cancelled ?? false) throw CancelledException();
  if (FileSystemEntity.isDirectorySync(src)) {
    await Directory(dest).create(recursive: true);
    await for (final e in Directory(src).list(followLinks: false)) {
      await copyEntity(e.path, p.join(dest, p.basename(e.path)), job);
    }
    return;
  }
  if (job == null) {
    await File(src).copy(dest);
    return;
  }
  job.label.value = p.basename(src);
  final inp = await File(src).open();
  final out = await File(dest).open(mode: FileMode.write);
  var ok = false;
  try {
    final buf = Uint8List(1 << 20);
    while (true) {
      if (job.cancelled) throw CancelledException();
      final n = await inp.readInto(buf);
      if (n <= 0) break;
      await out.writeFrom(buf, 0, n);
      job.add(n);
    }
    ok = true;
  } finally {
    await inp.close();
    await out.close();
    if (!ok) {
      try {
        await File(dest).delete();
      } catch (_) {}
    }
  }
}

Future<void> deleteEntity(String src) async {
  if (FileSystemEntity.isDirectorySync(src)) {
    await Directory(src).delete(recursive: true);
  } else {
    await File(src).delete();
  }
}

Future<void> moveEntity(String src, String dest, [Job? job]) async {
  try {
    if (FileSystemEntity.isDirectorySync(src)) {
      await Directory(src).rename(dest);
    } else {
      await File(src).rename(dest);
    }
  } catch (_) {
    await copyEntity(src, dest, job);
    await deleteEntity(src);
  }
}

Future<int> sizeOf(String path) async {
  try {
    if (!FileSystemEntity.isDirectorySync(path)) return await File(path).length();
    var t = 0;
    await for (final e in Directory(path).list(followLinks: false)) {
      t += await sizeOf(e.path);
    }
    return t;
  } catch (_) {
    return 0;
  }
}

List<FileSystemEntity>? scanCache;

Future<List<FileSystemEntity>> scan({bool dirs = false}) async {
  if (scanCache == null) {
    final out = <FileSystemEntity>[];
    Future<void> walk(Directory d) async {
      try {
        await for (final e in d.list(followLinks: false)) {
          if (p.basename(e.path).startsWith('.')) continue;
          if (e is Directory) {
            if (e.path == '$rootPath/Android') continue;
            out.add(e);
            await walk(e);
          } else if (e is File) {
            out.add(e);
          }
        }
      } catch (_) {}
    }

    await walk(Directory(rootPath));
    scanCache = out;
  }
  return dirs ? List.of(scanCache!) : scanCache!.whereType<File>().toList();
}

const textExts = {'txt', 'md', 'json', 'csv', 'log', 'xml', 'html', 'htm', 'js', 'css', 'dart', 'py', 'java', 'kt', 'yaml', 'yml', 'ini', 'cfg', 'lrc', 'srt'};

bool isArchive(String path) {
  final l = path.toLowerCase();
  return l.endsWith('.zip') || l.endsWith('.tar') || l.endsWith('.tar.gz') || l.endsWith('.tgz');
}

String archiveBase(String path) {
  var n = p.basename(path);
  for (final e in ['.tar.gz', '.tgz', '.tar', '.zip']) {
    if (n.toLowerCase().endsWith(e)) {
      n = n.substring(0, n.length - e.length);
      break;
    }
  }
  return n.isEmpty ? 'Giải nén' : n;
}

Future<void> unzipTo(String src, String out) => Isolate.run(() async {
      await (ar.extractFileToDisk as dynamic)(src, out);
    });

Future<void> zipPaths(List<String> srcs, String dest) => Isolate.run(() async {
      final dynamic enc = ar.ZipFileEncoder();
      enc.create(dest);
      for (final s in srcs) {
        if (FileSystemEntity.isDirectorySync(s)) {
          await enc.addDirectory(Directory(s));
        } else {
          await enc.addFile(File(s));
        }
      }
      await enc.close();
    });

Future<void> runJob(BuildContext context, String title, Job job, Future<void> Function() body, {bool cancellable = true}) async {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          ValueListenableBuilder<String>(valueListenable: job.label, builder: (_, v, __) => Text(v, maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(height: 12),
          ValueListenableBuilder<double>(
            valueListenable: job.progress,
            builder: (_, v, __) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              LinearProgressIndicator(value: v > 0 ? v : null),
              const SizedBox(height: 6),
              Text(v > 0 ? '${(v * 100).round()}% | ${fmtSize(job.done)}/${fmtSize(job.total)}' : 'Đang xử lý...', style: const TextStyle(fontSize: 12)),
            ]),
          ),
        ]),
        actions: [if (cancellable) TextButton(onPressed: () => job.cancelled = true, child: const Text('Huỷ'))],
      ),
    ),
  );
  try {
    await body();
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

Future<void> shareFiles(BuildContext context, List<String> paths) async {
  final files = paths.where((x) => FileSystemEntity.isFileSync(x)).toList();
  if (files.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Chỉ chia sẻ được tập tin, không chia sẻ được thư mục')));
    return;
  }
  try {
    await sp.Share.shareXFiles([for (final x in files) sp.XFile(x)]);
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Không chia sẻ được: $e')));
  }
}

List<String> extVolumes() {
  try {
    return Directory('/storage').listSync().whereType<Directory>().map((d) => d.path).where((x) => !x.endsWith('/emulated') && !x.endsWith('/self')).toList();
  } catch (_) {
    return [];
  }
}

Future<List<Item>> withStats(List<FileSystemEntity> es) async {
  final out = <Item>[];
  for (final e in es) {
    try {
      out.add(Item(e, await e.stat()));
    } catch (_) {}
  }
  return out;
}

Map<String, String> getTrash() => Map<String, String>.from(jsonDecode(prefs.getString('trash') ?? '{}') as Map);
List<String> getBm() => prefs.getStringList('bm') ?? [];

/// Vi tri dang xem do cua tung video (mili giay).
Map<String, int> getResume() {
  try {
    return (jsonDecode(prefs.getString('resume') ?? '{}') as Map).map((k, v) => MapEntry(k as String, (v as num).toInt()));
  } catch (_) {
    return {};
  }
}

Future<bool> ensurePerm() async {
  if (await Permission.manageExternalStorage.isGranted) return true;
  if (await Permission.storage.isGranted) return true;
  if ((await Permission.manageExternalStorage.request()).isGranted) return true;
  return (await Permission.storage.request()).isGranted;
}

Future<String?> prompt(BuildContext context, String title, String init) {
  final t = TextEditingController(text: init);
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(controller: t, autofocus: true),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Huỷ')),
        FilledButton(onPressed: () => Navigator.pop(c, t.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, String title, String msg, String ok) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(msg),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(ok)),
      ],
    ),
  );
  return r ?? false;
}

Widget fileIcon(Item it, {double size = 42}) {
  if (it.isDir) return Icon(Icons.folder, size: size, color: blue);
  final c = catOf(it.e.path);
  if (c != null && c.name == 'Hình') {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.file(File(it.e.path),
          width: size, height: size, fit: BoxFit.cover, cacheWidth: 160,
          errorBuilder: (_, __, ___) => Icon(c.icon, size: size, color: c.color)),
    );
  }
  if (c != null && c.name == 'Video') return VideoThumb(key: ValueKey(it.e.path), path: it.e.path, size: size);
  if (c != null && c.name == 'APP') return VideoThumb(key: ValueKey(it.e.path), path: it.e.path, size: size, kind: 'apk');
  if (c != null && c.name == 'Âm thanh') return VideoThumb(key: ValueKey(it.e.path), path: it.e.path, size: size, kind: 'audio');
  if (extOf(it.e.path) == 'pdf') return VideoThumb(key: ValueKey(it.e.path), path: it.e.path, size: size, kind: 'pdf');
  return Icon(c?.icon ?? Icons.insert_drive_file, size: size, color: c?.color ?? Colors.grey);
}

const nativeCh = MethodChannel('fm/native');

/// Dau chon nho o goc o hinh.
Widget tickMark(bool on) => Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(shape: BoxShape.circle, color: on ? const Color(0xFF43B649) : Colors.black26, border: Border.all(color: Colors.white, width: 1.5)),
      child: on ? const Icon(Icons.check, size: 15, color: Colors.white) : null,
    );

/// Anh vuong lap day o, dung cho luoi hinh va video.
Widget mediaThumb(String path, double s) {
  final c = catOf(path);
  if (c?.name == 'Video') return VideoThumb(key: ValueKey(path), path: path, size: s, square: true);
  return Image.file(File(path), width: s, height: s, fit: BoxFit.cover, cacheWidth: 300, errorBuilder: (_, __, ___) => SizedBox(width: s, height: s, child: Icon(c?.icon ?? Icons.image, size: s * 0.5, color: c?.color ?? Colors.grey)));
}

final durCache = <String, int>{};

String fmtDur(int ms) {
  final d = Duration(milliseconds: ms);
  final h = d.inHours, m = d.inMinutes % 60, x = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(x)}' : '${two(m)}:${two(x)}';
}

/// Anh thu nho tao bang ma Android goc: khung hinh video, bia nhac, trang dau PDF, icon APK.
class VideoThumb extends StatefulWidget {
  final String path;
  final double size;
  final String kind; // video | audio | pdf | apk
  final bool square;
  const VideoThumb({super.key, required this.path, required this.size, this.kind = 'video', this.square = false});
  @override
  State<VideoThumb> createState() => _VideoThumbState();
}

class _VideoThumbState extends State<VideoThumb> {
  late final Future<String?> future = _make();
  int dur = 0;

  bool get timed => widget.kind == 'video' || widget.kind == 'audio';

  Future<void> _loadDur() async {
    var d = durCache[widget.path];
    if (d == null) {
      try {
        d = await nativeCh.invokeMethod<int>('duration', {'src': widget.path, 'dest': ''}) ?? 0;
      } catch (_) {
        d = 0;
      }
    }
    final int v = d ?? 0;
    durCache[widget.path] = v;
    if (mounted && v > 0) setState(() => dur = v);
  }

  Future<String?> _make() async {
    final src = widget.path;
    final kind = widget.kind;
    if (timed) _loadDur();
    try {
      final dir = Directory('${Directory.systemTemp.path}/thumbs');
      await dir.create(recursive: true);
      final st = await File(src).stat();
      final dest = '${dir.path}/${kind}_${src.hashCode}_${st.size}.${kind == 'apk' ? 'png' : 'jpg'}';
      if (await File(dest).exists()) return dest;
      final none = File('$dest.none');
      if (await none.exists()) return null;
      final method = const {'apk': 'apkIcon', 'video': 'videoThumb', 'pdf': 'pdfThumb', 'audio': 'audioArt'}[kind] ?? 'videoThumb';
      try {
        final ok = await nativeCh.invokeMethod<bool>(method, {'src': src, 'dest': dest});
        if (ok == true) return dest;
      } catch (_) {}
      if (kind == 'video') {
        final dynamic pl = FcNativeVideoThumbnail();
        final tries = <dynamic Function()>[
          () => pl.saveThumbnailToFile(srcFile: src, destFile: dest, width: 256, height: 256, quality: 80),
          () => pl.saveThumbnailToFile(srcFile: src, destFile: dest, width: 256, height: 256, format: 'jpeg', quality: 80),
          () => pl.getVideoThumbnail(srcFile: src, destFile: dest, width: 256, height: 256, format: 'jpeg', quality: 80),
        ];
        for (final t in tries) {
          try {
            final r = await t();
            if (r == true || await File(dest).exists()) return dest;
          } catch (_) {}
        }
      }
      try {
        await none.create();
      } catch (_) {}
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final k = widget.kind;
    Widget fallback() {
      if (k == 'apk') return Icon(Icons.android, size: s, color: const Color(0xFF4CAE6C));
      if (k == 'pdf') return Icon(Icons.picture_as_pdf, size: s, color: const Color(0xFFE5532D));
      if (k == 'audio') return Container(width: s, height: s, color: const Color(0xFFD9D9D9), child: Icon(Icons.album, size: s * 0.75, color: const Color(0xFFBDBDBD)));
      return Container(width: s, height: s, color: const Color(0xFF3FBFB4), child: Icon(Icons.movie, size: s * 0.55, color: Colors.white));
    }

    return FutureBuilder<String?>(
      future: future,
      builder: (_, snap) {
        final has = snap.data != null;
        final Widget base = has ? Image.file(File(snap.data!), width: s, height: s, fit: (k == 'apk' || k == 'pdf') ? BoxFit.contain : BoxFit.cover, cacheWidth: 300, errorBuilder: (_, __, ___) => fallback()) : fallback();
        if (k == 'apk') return base;
        if (k == 'pdf') {
          return SizedBox(
            width: s,
            height: s,
            child: Stack(children: [
              Positioned.fill(child: base),
              if (has && s >= 56)
                Positioned(
                  right: s * 0.1,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(color: const Color(0xFFF07B2E), borderRadius: BorderRadius.circular(3)),
                    child: Text('PDF', style: TextStyle(color: Colors.white, fontSize: s * 0.15, fontWeight: FontWeight.bold)),
                  ),
                ),
            ]),
          );
        }
        const sh = [Shadow(blurRadius: 4, color: Colors.black)];
        return ClipRRect(
          borderRadius: BorderRadius.circular(widget.square ? 0 : 6),
          child: SizedBox(
            width: s,
            height: s,
            child: Stack(children: [
              Positioned.fill(child: base),
              if (s >= 56)
                Positioned(
                  left: 3,
                  right: 2,
                  bottom: 2,
                  child: Row(children: [
                    Icon(k == 'video' ? Icons.play_arrow : Icons.music_note, color: Colors.white, size: s * 0.22, shadows: sh),
                    if (dur > 0) Flexible(child: Text(fmtDur(dur), maxLines: 1, overflow: TextOverflow.clip, softWrap: false, style: TextStyle(color: Colors.white, fontSize: (s * 0.17).clamp(10.0, 15.0), shadows: sh))),
                  ]),
                )
              else if (k == 'video' && has)
                Center(child: Icon(Icons.play_arrow, color: Colors.white, size: s * 0.6, shadows: sh)),
            ]),
          ),
        );
      },
    );
  }
}

Future<void> openExternal(BuildContext context, String path) async {
  if (extOf(path) == 'apk' && !await Permission.requestInstallPackages.isGranted) {
    if (!(await Permission.requestInstallPackages.request()).isGranted) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Hãy bật "Cho phép từ nguồn này" rồi bấm lại vào tập tin APK')));
      }
      return;
    }
  }
  final r = await OpenFilex.open(path);
  if (r.type != ResultType.done && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Không mở được: ${r.message}')));
  }
}

Future<void> openFile(BuildContext context, String path, {List<String>? siblings}) async {
  final c = catOf(path)?.name;
  var list = siblings ?? [path];
  var idx = list.indexOf(path);
  if (idx < 0) {
    list = [path];
    idx = 0;
  }
  Widget? page;
  if (c == 'Video' || c == 'Âm thanh') {
    page = PlayerPage(paths: list, index: idx, video: c == 'Video');
  } else if (c == 'Hình') {
    page = ImageViewerPage(paths: list, index: idx);
  } else if (textExts.contains(extOf(path))) {
    var small = false;
    try {
      small = await File(path).length() <= 2 * 1024 * 1024;
    } catch (_) {}
    if (small) page = TextEditorPage(path: path);
  }
  if (!context.mounted) return;
  if (page != null) {
    final w = page;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => w));
  } else {
    await openExternal(context, path);
  }
}

// ---------- app ----------
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  prefs = await SharedPreferences.getInstance();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    ThemeData th(Brightness b) => ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: blue, brightness: b),
          appBarTheme: const AppBarTheme(backgroundColor: blue, foregroundColor: Colors.white),
        );
    return MaterialApp(
      title: 'Quản lý tập tin',
      debugShowCheckedModeBanner: false,
      theme: th(Brightness.light),
      darkTheme: th(Brightness.dark),
      home: const HomePage(),
    );
  }
}

// ---------- home ----------
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomeState();
}

class _HomeState extends State<HomePage> {
  bool? granted;
  int total = 0, used = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final g = await ensurePerm();
    if (g) await _df();
    if (mounted) setState(() => granted = g);
  }

  Future<void> _df() async {
    try {
      final r = await Process.run('df', ['-k', rootPath]);
      final lines = r.stdout.toString().trim().split('\n');
      final f = lines.last.trim().split(RegExp(r'\s+'));
      total = int.parse(f[1]) * 1024;
      used = int.parse(f[2]) * 1024;
    } catch (_) {}
  }

  void _open(Widget w) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => w)).then((_) async {
      await _df();
      if (mounted) setState(() {});
    });
  }

  Widget _card(Widget child) => Card(margin: const EdgeInsets.only(bottom: 10), child: Padding(padding: const EdgeInsets.all(12), child: child));

  Widget _tile(IconData icon, String label, Color color, VoidCallback onTap, {bool small = false}) => InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircleAvatar(radius: small ? 22 : 30, backgroundColor: small ? color.withAlpha(50) : color, child: Icon(icon, color: small ? color : Colors.white, size: small ? 22 : 30)),
            const SizedBox(height: 6),
            Text(label, textAlign: TextAlign.center, style: TextStyle(fontSize: small ? 13 : 15)),
          ]),
        ),
      );

  Widget _grid(List<Widget> c) => GridView.count(crossAxisCount: 3, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), childAspectRatio: 1.15, children: c);

  Widget _sec(String t) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Align(alignment: Alignment.centerLeft, child: Text(t, style: const TextStyle(color: blue, fontWeight: FontWeight.w600))));

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (granted == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (granted == false) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.lock, size: 56, color: Colors.grey),
            const SizedBox(height: 12),
            const Text('Ứng dụng cần quyền truy cập bộ nhớ để hiển thị tập tin.', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: _init, child: const Text('Cấp quyền')),
            TextButton(onPressed: openAppSettings, child: const Text('Mở cài đặt ứng dụng')),
          ]),
        ),
      );
    } else {
      final pct = total > 0 ? used / total : 0.0;
      final bm = getBm().where(existsPath).toList();
      void soon() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tính năng mạng chưa được hỗ trợ')));
      body = ListView(padding: const EdgeInsets.all(10), children: [
        Row(children: [
          Expanded(
            child: Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _open(const BrowserPage(mode: Mode.dir)),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    Stack(alignment: Alignment.center, children: [
                      CircularProgressIndicator(value: pct, backgroundColor: Colors.grey.withAlpha(60)),
                      Text('${(pct * 100).round()}%', style: const TextStyle(fontSize: 11)),
                    ]),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('Lưu trữ nội bộ', style: TextStyle(fontWeight: FontWeight.w600)),
                        Text(total > 0 ? '${fmtSize(used)}/${fmtSize(total)}' : 'Mở bộ nhớ', style: const TextStyle(fontSize: 12)),
                      ]),
                    ),
                  ]),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _open(const StatsPage()),
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Row(children: [
                    Icon(Icons.pie_chart, color: blue, size: 36),
                    SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Trình phân tích', style: TextStyle(fontWeight: FontWeight.w600)),
                        Text('Xem thứ gì chiếm chỗ', style: TextStyle(fontSize: 12)),
                      ]),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ]),
        _card(_grid([for (final c in cats) _tile(c.icon, c.name, c.color, () => _open(c.name == 'Hình' || c.name == 'Video' ? MediaCatPage(cat: c) : BrowserPage(mode: Mode.cat, cat: c)))])),
        _card(Column(children: [
          _sec('Mạng'),
          _grid([
            _tile(Icons.cloud, 'Lưu trữ đám mây', blue, soon, small: true),
            _tile(Icons.lan, 'LAN', blue, soon, small: true),
            _tile(Icons.swap_vert, 'FTP', blue, soon, small: true),
            _tile(Icons.computer, 'Quản lý từ xa', blue, soon, small: true),
            _tile(Icons.bluetooth, 'Bluetooth', blue, soon, small: true),
            _tile(Icons.public, 'WebDAV', blue, soon, small: true),
          ]),
        ])),
        if (extVolumes().isNotEmpty)
          _card(Column(children: [
            _sec('Thẻ nhớ và USB'),
            for (final v in extVolumes())
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.sd_card, color: blue),
                title: Text(p.basename(v)),
                subtitle: Text(v),
                onTap: () => _open(BrowserPage(mode: Mode.dir, path: v)),
              ),
          ])),
        _card(Column(children: [
          _sec('Công cụ'),
          _grid([
            _tile(Icons.history, 'Gần đây', blue, () => _open(const BrowserPage(mode: Mode.recent)), small: true),
            _tile(Icons.delete, 'Thùng rác', blue, () => _open(const BrowserPage(mode: Mode.trash)), small: true),
            _tile(Icons.download, 'Download', blue, () => _open(const BrowserPage(mode: Mode.dir, path: '$rootPath/Download')), small: true),
          ]),
        ])),
        _card(Column(children: [
          _sec('Dấu trang'),
          if (bm.isEmpty) const Align(alignment: Alignment.centerLeft, child: Text('Chưa có dấu trang. Mở menu của một thư mục để thêm.', style: TextStyle(fontSize: 13))),
          for (final b in bm)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.star, color: Color(0xFFF2B63C)),
              title: Text(p.basename(b)),
              subtitle: Text(b, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => _open(BrowserPage(mode: Mode.dir, path: b)),
            ),
        ])),
      ]);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trang chủ'),
        actions: [
          if (granted == true) IconButton(tooltip: 'Tìm kiếm', icon: const Icon(Icons.search), onPressed: () => _open(const BrowserPage(mode: Mode.search))),
        ],
      ),
      body: body,
    );
  }
}

// ---------- browser ----------
enum Mode { dir, cat, recent, trash, search }

class BrowserPage extends StatefulWidget {
  final Mode mode;
  final String path;
  final Cat? cat;
  final String? only;
  const BrowserPage({super.key, required this.mode, this.path = rootPath, this.cat, this.only});
  @override
  State<BrowserPage> createState() => _BrowserState();
}

class _BrowserState extends State<BrowserPage> {
  late String cur = widget.path;
  List<Item> items = [];
  bool loading = true;
  final sel = <String>{};
  String q = '';
  bool get _media => widget.mode == Mode.cat && (widget.cat?.name == 'Hình' || widget.cat?.name == 'Video');
  late String sort = _media ? 'date' : (prefs.getString('sort') ?? 'name');
  bool grid = prefs.getBool('grid') ?? true;
  bool hidden = prefs.getBool('hidden') ?? false;

  bool get isDir => widget.mode == Mode.dir;
  bool get isTrash => widget.mode == Mode.trash;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _msg(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _load() async {
    setState(() => loading = true);
    var es = <FileSystemEntity>[];
    try {
      switch (widget.mode) {
        case Mode.dir:
          es = (await Directory(cur).list(followLinks: false).toList()).where((e) {
            final n = p.basename(e.path);
            return n != '.FMTrash' && (hidden || !n.startsWith('.'));
          }).toList();
        case Mode.cat:
          es = (await scan()).where((e) => widget.cat!.exts.contains(extOf(e.path)) && (widget.only == null || p.dirname(e.path) == widget.only)).toList();
        case Mode.recent:
          es = await scan();
        case Mode.search:
          final s = q.trim().toLowerCase();
          es = s.isEmpty ? [] : (await scan(dirs: true)).where((e) => p.basename(e.path).toLowerCase().contains(s)).toList();
        case Mode.trash:
          if (await trashDir.exists()) es = await trashDir.list(followLinks: false).toList();
      }
    } catch (e) {
      _msg('Không đọc được thư mục: $e');
    }
    var out = await withStats(es);
    if (widget.mode == Mode.recent) {
      out.sort((a, b) => b.s.modified.compareTo(a.s.modified));
      out = out.take(50).toList();
    } else {
      _sort(out);
    }
    if (!mounted) return;
    setState(() {
      items = out;
      loading = false;
      sel.clear();
    });
  }

  void _sort(List<Item> l) {
    int byName(Item a, Item b) => a.name.toLowerCase().compareTo(b.name.toLowerCase());
    int c(Item a, Item b) {
      switch (sort) {
        case 'date':
          return b.s.modified.compareTo(a.s.modified);
        case 'size':
          return b.s.size.compareTo(a.s.size);
        case 'type':
          final r = extOf(a.e.path).compareTo(extOf(b.e.path));
          return r != 0 ? r : byName(a, b);
        default:
          return byName(a, b);
      }
    }

    l.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return c(a, b);
    });
  }

  Future<void> _run(Future<void> Function() f, String ok) async {
    try {
      await f();
      _msg(ok);
    } catch (e) {
      _msg('Lỗi: $e');
    }
    scanCache = null;
    if (mounted) await _load();
  }

  bool _badName(String? s) {
    if (s == null) return true;
    if (s.isEmpty || s.contains('/')) {
      _msg('Tên không hợp lệ');
      return true;
    }
    return false;
  }

  Future<void> _newFolder() async {
    final s = await prompt(context, 'Thư mục mới', 'Thư mục mới');
    if (_badName(s)) return;
    await _run(() async => Directory(uniquePath(cur, s!)).create(), 'Đã tạo thư mục');
  }

  Future<void> _newFile() async {
    final s = await prompt(context, 'Tập tin văn bản mới', 'Ghi chú mới.txt');
    if (_badName(s)) return;
    await _run(() async => File(uniquePath(cur, s!)).create(), 'Đã tạo tập tin');
  }

  Future<void> _rename(String path) async {
    final s = await prompt(context, 'Đổi tên', p.basename(path));
    if (_badName(s) || s == p.basename(path)) return;
    final dest = p.join(p.dirname(path), s!);
    if (existsPath(dest)) {
      _msg('Tên này đã tồn tại');
      return;
    }
    await _run(() => moveEntity(path, dest), 'Đã đổi tên');
  }

  Future<void> _delete(List<String> paths) async {
    if (!await confirm(context, 'Xoá ${paths.length} mục?', 'Các mục sẽ vào Thùng rác và có thể khôi phục.', 'Xoá')) return;
    await _run(() async {
      await trashDir.create(recursive: true);
      final m = getTrash();
      for (final s in paths) {
        final d = uniquePath(trashDir.path, p.basename(s));
        await moveEntity(s, d);
        m[d] = s;
      }
      await prefs.setString('trash', jsonEncode(m));
    }, 'Đã chuyển vào Thùng rác');
  }

  Future<void> _restore(List<String> paths) async {
    await _run(() async {
      final m = getTrash();
      for (final s in paths) {
        final orig = m[s] ?? p.join(rootPath, p.basename(s));
        await Directory(p.dirname(orig)).create(recursive: true);
        await moveEntity(s, uniquePath(p.dirname(orig), p.basename(orig)));
        m.remove(s);
      }
      await prefs.setString('trash', jsonEncode(m));
    }, 'Đã khôi phục');
  }

  Future<void> _purge(List<String> paths) async {
    if (!await confirm(context, 'Xoá hẳn ${paths.length} mục?', 'Không thể khôi phục sau khi xoá hẳn.', 'Xoá hẳn')) return;
    await _run(() async {
      final m = getTrash();
      for (final s in paths) {
        await deleteEntity(s);
        m.remove(s);
      }
      await prefs.setString('trash', jsonEncode(m));
    }, 'Đã xoá hẳn');
  }

  void _toClip(List<String> paths, bool cut) {
    clip.value = FmClip(paths, cut);
    if (isDir) {
      setState(sel.clear);
      _msg('Mở thư mục đích rồi nhấn Dán');
    } else {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const BrowserPage(mode: Mode.dir)));
    }
  }

  Future<void> _paste() async {
    final c = clip.value;
    if (c == null) return;
    for (final s in c.paths) {
      if (s == cur || p.isWithin(s, cur)) {
        _msg('Không thể dán thư mục vào chính nó');
        return;
      }
    }
    final srcs = c.paths.where(existsPath).toList();
    final conflicts = srcs.where((s) => p.dirname(s) != cur && existsPath(p.join(cur, p.basename(s)))).length;
    var mode = 'keep';
    if (conflicts > 0) {
      final r = await showDialog<String>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text('$conflicts mục trùng tên'),
          content: const Text('Thư mục này đã có mục cùng tên. Bạn muốn xử lý thế nào?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, 'skip'), child: const Text('Bỏ qua')),
            TextButton(onPressed: () => Navigator.pop(d, 'keep'), child: const Text('Giữ cả hai')),
            FilledButton(onPressed: () => Navigator.pop(d, 'overwrite'), child: const Text('Ghi đè')),
          ],
        ),
      );
      if (r == null || !mounted) return;
      mode = r;
    }
    clip.value = null;
    final job = Job();
    String result = '';
    await runJob(context, c.cut ? 'Đang di chuyển' : 'Đang sao chép', job, () async {
      try {
        var total = 0;
        for (final s in srcs) {
          total += await sizeOf(s);
        }
        job.total = total;
        var n = 0;
        for (final s in srcs) {
          final same = p.dirname(s) == cur;
          if (c.cut && same) continue;
          var dest = p.join(cur, p.basename(s));
          if (existsPath(dest)) {
            if (same || mode == 'keep' || p.isWithin(dest, s)) {
              dest = uniquePath(cur, p.basename(s));
            } else if (mode == 'skip') {
              continue;
            } else {
              await deleteEntity(dest);
            }
          }
          if (c.cut) {
            await moveEntity(s, dest, job);
          } else {
            await copyEntity(s, dest, job);
          }
          n++;
        }
        result = c.cut ? 'Đã di chuyển $n mục' : 'Đã sao chép $n mục';
      } on CancelledException {
        result = 'Đã huỷ';
      } catch (e) {
        result = 'Lỗi: $e';
      }
    });
    _msg(result);
    scanCache = null;
    if (mounted) await _load();
  }

  Future<void> _extract(String path) async {
    final out = uniquePath(p.dirname(path), archiveBase(path));
    final job = Job()..label.value = p.basename(path);
    String result = '';
    await runJob(context, 'Đang giải nén', job, () async {
      try {
        await unzipTo(path, out);
        result = 'Đã giải nén vào "${p.basename(out)}"';
      } catch (e) {
        result = 'Không giải nén được: $e';
      }
    }, cancellable: false);
    _msg(result);
    scanCache = null;
    if (mounted) await _load();
  }

  Future<void> _zip(List<String> paths) async {
    if (paths.isEmpty) return;
    final dir = isDir ? cur : p.dirname(paths.first);
    final def = paths.length == 1 ? '${p.basenameWithoutExtension(paths.first)}.zip' : 'Tập tin nén.zip';
    var s = await prompt(context, 'Nén thành zip', def);
    if (_badName(s) || !mounted) return;
    if (!s!.toLowerCase().endsWith('.zip')) s = '$s.zip';
    final dest = uniquePath(dir, s);
    final job = Job()..label.value = p.basename(dest);
    String result = '';
    await runJob(context, 'Đang nén', job, () async {
      try {
        await zipPaths(paths, dest);
        result = 'Đã nén thành "${p.basename(dest)}"';
      } catch (e) {
        result = 'Không nén được: $e';
        try {
          await File(dest).delete();
        } catch (_) {}
      }
    }, cancellable: false);
    _msg(result);
    scanCache = null;
    if (mounted) await _load();
  }

  void _info(Item it) {
    Widget row(String a, Widget b) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: 90, child: Text(a, style: const TextStyle(color: Colors.grey))), Expanded(child: b)]),
        );
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Chi tiết'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          row('Tên', Text(it.name)),
          row('Loại', Text(it.isDir ? 'Thư mục' : (catOf(it.e.path)?.name ?? 'Tập tin'))),
          row('Vị trí', Text(p.dirname(it.e.path))),
          row('Kích thước', FutureBuilder<int>(future: sizeOf(it.e.path), builder: (_, s) => Text(s.hasData ? fmtSize(s.data!) : 'Đang tính...'))),
          row('Sửa đổi', Text(fmtDate(it.s.modified))),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Đóng'))],
      ),
    );
  }

  Future<void> _openItem(Item it) async {
    if (it.isDir) {
      if (isDir) {
        cur = it.e.path;
        _load();
      } else {
        Navigator.push(context, MaterialPageRoute(builder: (_) => BrowserPage(mode: Mode.dir, path: it.e.path)));
      }
      return;
    }
    final path = it.e.path;
    if (isArchive(path)) {
      if (await confirm(context, 'Giải nén?', 'Giải nén "${it.name}" vào một thư mục mới cùng chỗ.', 'Giải nén')) await _extract(path);
      return;
    }
    final c = catOf(path);
    final sib = c == null ? null : items.where((i) => !i.isDir && catOf(i.e.path) == c).map((i) => i.e.path).toList();
    await openFile(context, path, siblings: sib);
    if (mounted && textExts.contains(extOf(path))) _load();
  }

  void _sheet(Item it) {
    final path = it.e.path;
    Widget o(IconData i, String t, VoidCallback f, {Color? color}) => ListTile(
        leading: Icon(i, color: color),
        title: Text(t, style: TextStyle(color: color)),
        onTap: () {
          Navigator.pop(context);
          f();
        });
    final bm = getBm();
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(title: Text(it.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
            if (isTrash) ...[
              o(Icons.restore, 'Khôi phục', () => _restore([path])),
              o(Icons.delete_forever, 'Xoá hẳn', () => _purge([path]), color: Colors.red),
            ] else ...[
              o(Icons.open_in_new, 'Mở', () => _openItem(it)),
              if (!it.isDir) o(Icons.apps, 'Mở bằng ứng dụng khác', () => openExternal(context, path)),
              if (!it.isDir) o(Icons.share, 'Chia sẻ', () => shareFiles(context, [path])),
              if (isArchive(path)) o(Icons.unarchive, 'Giải nén', () => _extract(path)),
              o(Icons.archive, 'Nén thành zip', () => _zip([path])),
              o(Icons.edit, 'Đổi tên', () => _rename(path)),
              o(Icons.copy, 'Sao chép', () => _toClip([path], false)),
              o(Icons.drive_file_move, 'Di chuyển', () => _toClip([path], true)),
              if (it.isDir)
                o(Icons.star, bm.contains(path) ? 'Bỏ dấu trang' : 'Thêm dấu trang', () async {
                  bm.contains(path) ? bm.remove(path) : bm.add(path);
                  await prefs.setStringList('bm', bm);
                  _msg(bm.contains(path) ? 'Đã thêm dấu trang' : 'Đã bỏ dấu trang');
                }),
              if (!isDir) o(Icons.folder_open, 'Mở vị trí tập tin', () => Navigator.push(context, MaterialPageRoute(builder: (_) => BrowserPage(mode: Mode.dir, path: p.dirname(path))))),
              o(Icons.info_outline, 'Chi tiết', () => _info(it)),
              o(Icons.delete, 'Xoá', () => _delete([path]), color: Colors.red),
            ],
          ]),
        ),
      ),
    );
  }

  void _tap(Item it) {
    if (sel.isNotEmpty) {
      setState(() => sel.contains(it.e.path) ? sel.remove(it.e.path) : sel.add(it.e.path));
    } else if (isTrash) {
      _sheet(it);
    } else {
      _openItem(it);
    }
  }

  String _sub(Item it) {
    final a = it.isDir ? 'Thư mục' : fmtSize(it.s.size);
    return isDir ? '$a | ${fmtDate(it.s.modified)}' : '$a | ${p.dirname(it.e.path).replaceFirst(rootPath, 'Bộ nhớ trong')}';
  }

  String get _title {
    switch (widget.mode) {
      case Mode.dir:
        return cur == rootPath ? 'Bộ nhớ trong' : p.basename(cur);
      case Mode.cat:
        return widget.only != null ? p.basename(widget.only!) : widget.cat!.name;
      case Mode.recent:
        return 'Gần đây';
      case Mode.trash:
        return 'Thùng rác';
      case Mode.search:
        return 'Tìm kiếm';
    }
  }

  PreferredSizeWidget? _crumbs() {
    if (!isDir || sel.isNotEmpty || !p.isWithin(rootPath, cur)) return null;
    final parts = p.split(p.relative(cur, from: rootPath));
    Widget b(String t, String path) => TextButton(
        onPressed: path == cur
            ? null
            : () {
                cur = path;
                _load();
              },
        child: Text(t, style: const TextStyle(color: Colors.white)));
    return PreferredSize(
      preferredSize: const Size.fromHeight(40),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: true,
          child: Row(children: [
            b('Bộ nhớ trong', rootPath),
            for (var i = 0; i < parts.length; i++) ...[
              const Icon(Icons.chevron_right, color: Colors.white70, size: 18),
              b(parts[i], p.joinAll([rootPath, ...parts.sublist(0, i + 1)])),
            ],
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selecting = sel.isNotEmpty;
    final atTop = !isDir || cur == widget.path || cur == rootPath;
    final picked = sel.toList();
    Item one() => items.firstWhere((i) => i.e.path == picked.first);

    Widget body;
    if (loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (items.isEmpty) {
      final t = {
        Mode.dir: 'Thư mục trống. Nhấn + để thêm.',
        Mode.cat: 'Chưa có tập tin nào thuộc loại này.',
        Mode.recent: 'Chưa có tập tin nào.',
        Mode.trash: 'Thùng rác trống.',
        Mode.search: q.isEmpty ? 'Nhập tên rồi nhấn tìm.' : 'Không tìm thấy kết quả nào.',
      }[widget.mode]!;
      body = Center(child: Text(t, style: const TextStyle(color: Colors.grey)));
    } else if (grid && _media) {
      body = GridView.builder(
        padding: const EdgeInsets.only(bottom: 90),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, crossAxisSpacing: 2, mainAxisSpacing: 2),
        itemCount: items.length,
        itemBuilder: (_, i) {
          final it = items[i], on = sel.contains(it.e.path);
          return InkWell(
            onTap: () => _tap(it),
            onLongPress: () => setState(() => sel.add(it.e.path)),
            child: LayoutBuilder(
              builder: (_, c) => Stack(fit: StackFit.expand, children: [
                mediaThumb(it.e.path, c.maxWidth),
                if (on) Container(color: Colors.black26),
                if (selecting) Positioned(right: 6, bottom: 6, child: tickMark(on)),
              ]),
            ),
          );
        },
      );
    } else if (grid) {
      body = GridView.builder(
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 90),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, childAspectRatio: 0.8),
        itemCount: items.length,
        itemBuilder: (_, i) {
          final it = items[i], on = sel.contains(it.e.path);
          return InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _tap(it),
            onLongPress: () => setState(() => sel.add(it.e.path)),
            child: Container(
              decoration: BoxDecoration(color: on ? blue.withAlpha(50) : null, borderRadius: BorderRadius.circular(10)),
              child: LayoutBuilder(builder: (_, c) {
                // Hinh thu muc co le trong san nen ve to hon o roi cho tran ra.
                final w = c.maxWidth * 0.94, h = w * 0.78;
                return Column(children: [
                  SizedBox(
                    width: w,
                    height: h,
                    child: Stack(clipBehavior: Clip.none, children: [
                      Positioned.fill(
                        child: it.isDir ? OverflowBox(maxWidth: w, maxHeight: w, child: fileIcon(it, size: w)) : Center(child: fileIcon(it, size: h * 0.92)),
                      ),
                      if (selecting) Positioned(right: 2, bottom: 0, child: tickMark(on)),
                    ]),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Text(it.name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, height: 1.15)),
                  ),
                ]);
              }),
            ),
          );
        },
      );
    } else {
      body = ListView.builder(
        padding: const EdgeInsets.only(bottom: 90),
        itemCount: items.length,
        itemBuilder: (_, i) {
          final it = items[i], on = sel.contains(it.e.path);
          return ListTile(
            selected: on,
            selectedTileColor: blue.withAlpha(40),
            leading: SizedBox(width: 42, height: 42, child: on ? const Icon(Icons.check_circle, size: 36, color: blue) : fileIcon(it)),
            title: Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(_sub(it), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
            trailing: selecting ? null : IconButton(tooltip: 'Thao tác', icon: const Icon(Icons.more_vert), onPressed: () => _sheet(it)),
            onTap: () => _tap(it),
            onLongPress: () => setState(() => sel.add(it.e.path)),
          );
        },
      );
    }

    return PopScope(
      canPop: !selecting && atTop,
      onPopInvokedWithResult: (did, _) {
        if (did) return;
        if (selecting) {
          setState(sel.clear);
        } else {
          cur = p.dirname(cur);
          _load();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: selecting ? IconButton(tooltip: 'Huỷ chọn', icon: const Icon(Icons.close), onPressed: () => setState(sel.clear)) : null,
          title: selecting
              ? Text('Đã chọn ${sel.length}')
              : widget.mode == Mode.search
                  ? TextField(
                      autofocus: true,
                      style: const TextStyle(color: Colors.white),
                      cursorColor: Colors.white,
                      textInputAction: TextInputAction.search,
                      decoration: const InputDecoration(hintText: 'Tìm tập tin, thư mục', hintStyle: TextStyle(color: Colors.white70), border: InputBorder.none),
                      onSubmitted: (s) {
                        q = s;
                        _load();
                      },
                    )
                  : Text(_title),
          bottom: _crumbs(),
          actions: selecting
              ? [
                  IconButton(tooltip: 'Chọn tất cả', icon: const Icon(Icons.select_all), onPressed: () => setState(() => sel.addAll(items.map((i) => i.e.path)))),
                  if (isTrash) ...[
                    IconButton(tooltip: 'Khôi phục', icon: const Icon(Icons.restore), onPressed: () => _restore(picked)),
                    IconButton(tooltip: 'Xoá hẳn', icon: const Icon(Icons.delete_forever), onPressed: () => _purge(picked)),
                  ] else ...[
                    IconButton(tooltip: 'Sao chép', icon: const Icon(Icons.copy), onPressed: () => _toClip(picked, false)),
                    IconButton(tooltip: 'Di chuyển', icon: const Icon(Icons.drive_file_move), onPressed: () => _toClip(picked, true)),
                    IconButton(tooltip: 'Xoá', icon: const Icon(Icons.delete), onPressed: () => _delete(picked)),
                    PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'ren') {
                          _rename(picked.first);
                        } else if (v == 'info') {
                          _info(one());
                        } else if (v == 'share') {
                          shareFiles(context, picked);
                        } else {
                          _zip(picked);
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'share', child: Text('Chia sẻ')),
                        const PopupMenuItem(value: 'zip', child: Text('Nén thành zip')),
                        if (sel.length == 1) const PopupMenuItem(value: 'ren', child: Text('Đổi tên')),
                        if (sel.length == 1) const PopupMenuItem(value: 'info', child: Text('Chi tiết')),
                      ],
                    ),
                  ],
                ]
              : [
                  if (widget.mode != Mode.search) IconButton(tooltip: 'Tìm kiếm', icon: const Icon(Icons.search), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BrowserPage(mode: Mode.search)))),
                  PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'grid') {
                        setState(() => grid = !grid);
                        prefs.setBool('grid', grid);
                      } else if (v == 'empty') {
                        _purge(items.map((i) => i.e.path).toList());
                      } else if (v == 'refresh') {
                        scanCache = null;
                        _load();
                      } else if (v == 'hidden') {
                        hidden = !hidden;
                        prefs.setBool('hidden', hidden);
                        _load();
                      } else {
                        sort = v;
                        if (!_media) prefs.setString('sort', v);
                        _load();
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'grid', child: Text(grid ? 'Xem dạng danh sách' : 'Xem dạng lưới')),
                      const PopupMenuItem(value: 'refresh', child: Text('Làm mới')),
                      if (isDir) PopupMenuItem(value: 'hidden', child: Text(hidden ? 'Ẩn tập tin ẩn' : 'Hiện tập tin ẩn')),
                      if (isTrash && items.isNotEmpty) const PopupMenuItem(value: 'empty', child: Text('Dọn sạch thùng rác')),
                      if (widget.mode != Mode.recent && !isTrash) ...[
                        const PopupMenuDivider(),
                        for (final e in const {'name': 'Tên', 'date': 'Ngày sửa', 'size': 'Kích thước', 'type': 'Loại'}.entries)
                          CheckedPopupMenuItem(value: e.key, checked: sort == e.key, child: Text('Sắp xếp: ${e.value}')),
                      ],
                    ],
                  ),
                ],
        ),
        body: body,
        floatingActionButton: isDir && !selecting
            ? ValueListenableBuilder<FmClip?>(
                valueListenable: clip,
                builder: (_, c, __) => c != null
                    ? const SizedBox.shrink()
                    : FloatingActionButton(
                        tooltip: 'Thêm mới',
                        onPressed: () => showModalBottomSheet(
                          context: context,
                          showDragHandle: true,
                          builder: (_) => SafeArea(
                            child: Column(mainAxisSize: MainAxisSize.min, children: [
                              ListTile(
                                  leading: const Icon(Icons.create_new_folder),
                                  title: const Text('Thư mục mới'),
                                  onTap: () {
                                    Navigator.pop(context);
                                    _newFolder();
                                  }),
                              ListTile(
                                  leading: const Icon(Icons.note_add),
                                  title: const Text('Tập tin văn bản mới'),
                                  onTap: () {
                                    Navigator.pop(context);
                                    _newFile();
                                  }),
                            ]),
                          ),
                        ),
                        child: const Icon(Icons.add),
                      ),
              )
            : null,
        bottomNavigationBar: isDir && !selecting
            ? ValueListenableBuilder<FmClip?>(
                valueListenable: clip,
                builder: (_, c, __) => c == null
                    ? const SizedBox.shrink()
                    : SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Row(children: [
                            Expanded(child: FilledButton.icon(onPressed: _paste, icon: const Icon(Icons.paste), label: Text('Dán ${c.paths.length} mục vào đây'))),
                            const SizedBox(width: 8),
                            OutlinedButton(onPressed: () => clip.value = null, child: const Text('Huỷ')),
                          ]),
                        ),
                      ),
              )
            : null,
      ),
    );
  }
}

// ---------- analyzer ----------
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});
  @override
  State<StatsPage> createState() => _StatsState();
}

class _StatsState extends State<StatsPage> {
  late final Future<List<Item>> future = scan().then(withStats);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Trình phân tích')),
      body: FutureBuilder<List<Item>>(
        future: future,
        builder: (_, s) {
          if (!s.hasData) return const Center(child: CircularProgressIndicator());
          final fs = s.data!;
          final tot = fs.fold<int>(0, (a, i) => a + i.s.size);
          final by = <String, int>{for (final c in cats) c.name: 0, 'Khác': 0};
          for (final i in fs) {
            final k = catOf(i.e.path)?.name ?? 'Khác';
            by[k] = by[k]! + i.s.size;
          }
          fs.sort((a, b) => b.s.size.compareTo(a.s.size));
          Color col(String k) => cats.where((c) => c.name == k).map((c) => c.color).firstWhere((_) => true, orElse: () => Colors.grey);
          return ListView(padding: const EdgeInsets.all(12), children: [
            const Text('Dung lượng theo loại', style: TextStyle(color: blue, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            for (final e in by.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(e.key), Text(fmtSize(e.value))]),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(value: tot > 0 ? e.value / tot : 0, color: col(e.key), minHeight: 8, borderRadius: BorderRadius.circular(4)),
                ]),
              ),
            const SizedBox(height: 8),
            const Text('Tập tin lớn nhất', style: TextStyle(color: blue, fontWeight: FontWeight.w600)),
            for (final it in fs.take(15))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: SizedBox(width: 42, height: 42, child: fileIcon(it)),
                title: Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${fmtSize(it.s.size)} | ${p.dirname(it.e.path).replaceFirst(rootPath, 'Bộ nhớ trong')}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                onTap: () => openFile(context, it.e.path),
              ),
          ]);
        },
      ),
    );
  }
}

// ---------- player ----------
class PlayerPage extends StatefulWidget {
  final List<String> paths;
  final int index;
  final bool video;
  const PlayerPage({super.key, required this.paths, required this.index, required this.video});
  String get path => paths[index];
  @override
  State<PlayerPage> createState() => _PlayerState();
}

class _PlayerState extends State<PlayerPage> {
  late final VideoPlayerController c;
  bool ready = false, show = true, landscape = false;
  String? err;

  @override
  void initState() {
    super.initState();
    c = VideoPlayerController.file(File(widget.path));
    c.addListener(_tick);
    c.initialize().then((_) async {
      if (!mounted) return;
      setState(() => ready = true);
      final saved = widget.video ? (getResume()[widget.path] ?? 0) : 0;
      final total = c.value.duration.inMilliseconds;
      if (saved > 5000 && saved < total - 5000) {
        final go = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (d) => AlertDialog(
            title: const Text('Xem tiếp?'),
            content: Text('Lần trước bạn dừng ở ${fmtDur(saved)}. Bạn muốn xem tiếp đoạn còn lại hay xem lại từ đầu?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Xem từ đầu')),
              FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Xem tiếp')),
            ],
          ),
        );
        if (!mounted) return;
        if (go == true) await c.seekTo(Duration(milliseconds: saved));
      }
      c.play();
    }).catchError((Object e) {
      if (mounted) setState(() => err = '$e');
    });
  }

  bool _ended = false;
  DateTime _lastSave = DateTime.now();

  void _savePos() {
    if (!widget.video || !ready) return;
    final m = getResume();
    final pos = c.value.position.inMilliseconds, total = c.value.duration.inMilliseconds;
    m.remove(widget.path);
    if (pos > 5000 && pos < total - 5000) m[widget.path] = pos;
    while (m.length > 100) {
      m.remove(m.keys.first);
    }
    prefs.setString('resume', jsonEncode(m));
  }

  void _tick() {
    if (!mounted) return;
    final v = c.value;
    if (v.isPlaying && DateTime.now().difference(_lastSave).inSeconds >= 5) {
      _lastSave = DateTime.now();
      _savePos();
    }
    if (ready && !_ended && !widget.video && v.duration > Duration.zero && v.position >= v.duration && widget.index < widget.paths.length - 1) {
      _ended = true;
      _go(widget.index + 1);
      return;
    }
    setState(() {});
  }

  void _go(int i) {
    if (i < 0 || i >= widget.paths.length) return;
    Navigator.pushReplacement(context, PageRouteBuilder(pageBuilder: (_, __, ___) => PlayerPage(paths: widget.paths, index: i, video: widget.video)));
  }

  @override
  void dispose() {
    c.removeListener(_tick);
    _savePos();
    c.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _rotate() {
    landscape = !landscape;
    SystemChrome.setPreferredOrientations(landscape ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight] : [DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(landscape ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
    setState(() {});
  }

  String _t(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  void _seek(Duration d) {
    final max = c.value.duration;
    c.seekTo(d < Duration.zero ? Duration.zero : (d > max ? max : d));
  }

  Future<void> _toggle() async {
    final v = c.value;
    if (v.isPlaying) {
      await c.pause();
    } else {
      if (v.duration > Duration.zero && v.position >= v.duration) await c.seekTo(Duration.zero);
      await c.play();
    }
  }

  Widget _controls() {
    final v = c.value;
    final dur = v.duration.inMilliseconds.toDouble();
    final pos = v.position.inMilliseconds.toDouble().clamp(0.0, dur > 0 ? dur : 0.0);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        const SizedBox(width: 12),
        Text(_t(v.position), style: const TextStyle(color: Colors.white, fontSize: 12)),
        Expanded(
          child: Slider(
            value: pos,
            max: dur > 0 ? dur : 1,
            activeColor: Colors.white,
            inactiveColor: Colors.white30,
            onChanged: ready ? (x) => c.seekTo(Duration(milliseconds: x.round())) : null,
          ),
        ),
        Text(_t(v.duration), style: const TextStyle(color: Colors.white, fontSize: 12)),
        const SizedBox(width: 12),
      ]),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconButton(tooltip: 'Bài trước', iconSize: 30, color: Colors.white, icon: const Icon(Icons.skip_previous), onPressed: widget.index > 0 ? () => _go(widget.index - 1) : null),
        IconButton(tooltip: 'Lùi 10 giây', iconSize: 34, color: Colors.white, icon: const Icon(Icons.replay_10), onPressed: ready ? () => _seek(v.position - const Duration(seconds: 10)) : null),
        const SizedBox(width: 8),
        IconButton(tooltip: v.isPlaying ? 'Tạm dừng' : 'Phát', iconSize: 56, color: Colors.white, icon: Icon(v.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled), onPressed: ready ? _toggle : null),
        const SizedBox(width: 8),
        IconButton(tooltip: 'Tới 10 giây', iconSize: 34, color: Colors.white, icon: const Icon(Icons.forward_10), onPressed: ready ? () => _seek(v.position + const Duration(seconds: 10)) : null),
        IconButton(tooltip: 'Bài sau', iconSize: 30, color: Colors.white, icon: const Icon(Icons.skip_next), onPressed: widget.index < widget.paths.length - 1 ? () => _go(widget.index + 1) : null),
      ]),
      const SizedBox(height: 8),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final name = p.basename(widget.path);
    Widget center;
    if (err != null) {
      center = Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, color: Colors.white70, size: 48),
          const SizedBox(height: 12),
          const Text('Không phát được tập tin này. Định dạng có thể chưa được hỗ trợ.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white)),
          const SizedBox(height: 12),
          FilledButton(onPressed: () => openExternal(context, widget.path), child: const Text('Mở bằng ứng dụng khác')),
        ]),
      );
    } else if (!ready) {
      center = const CircularProgressIndicator(color: Colors.white);
    } else if (widget.video) {
      center = AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c));
    } else {
      center = Column(mainAxisSize: MainAxisSize.min, children: [
        const CircleAvatar(radius: 70, backgroundColor: Color(0xFF7A52E8), child: Icon(Icons.music_note, size: 80, color: Colors.white)),
        const SizedBox(height: 20),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Text(name, textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 18))),
      ]);
    }
    final bars = !widget.video || show || err != null;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.video ? () => setState(() => show = !show) : null,
            child: Center(child: center),
          ),
        ),
        if (bars)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              color: Colors.black54,
              child: SafeArea(
                bottom: false,
                child: Row(children: [
                  IconButton(tooltip: 'Quay lại', color: Colors.white, icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context)),
                  Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 16))),
                  IconButton(tooltip: 'Chia sẻ', color: Colors.white, icon: const Icon(Icons.share), onPressed: () => shareFiles(context, [widget.path])),
                  if (widget.video) IconButton(tooltip: landscape ? 'Xoay dọc' : 'Xoay ngang', color: Colors.white, icon: const Icon(Icons.screen_rotation), onPressed: _rotate),
                ]),
              ),
            ),
          ),
        if (bars && err == null)
          Positioned(left: 0, right: 0, bottom: 0, child: Container(color: Colors.black54, child: SafeArea(top: false, child: _controls()))),
      ]),
    );
  }
}

// ---------- image viewer ----------
class ImageViewerPage extends StatefulWidget {
  final List<String> paths;
  final int index;
  const ImageViewerPage({super.key, required this.paths, required this.index});
  @override
  State<ImageViewerPage> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewerPage> {
  late int i = widget.index;
  late final PageController pc = PageController(initialPage: widget.index);
  bool bars = true;

  @override
  void dispose() {
    pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: bars
          ? AppBar(
              backgroundColor: Colors.black54,
              foregroundColor: Colors.white,
              title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.basename(widget.paths[i]), style: const TextStyle(fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis),
                Text('${i + 1}/${widget.paths.length}', style: const TextStyle(fontSize: 12)),
              ]),
              actions: [
                IconButton(tooltip: 'Chia sẻ', icon: const Icon(Icons.share), onPressed: () => shareFiles(context, [widget.paths[i]])),
                IconButton(tooltip: 'Mở bằng ứng dụng khác', icon: const Icon(Icons.apps), onPressed: () => openExternal(context, widget.paths[i])),
              ],
            )
          : null,
      body: PageView.builder(
        controller: pc,
        itemCount: widget.paths.length,
        onPageChanged: (n) => setState(() => i = n),
        itemBuilder: (_, n) => GestureDetector(
          onTap: () => setState(() => bars = !bars),
          child: InteractiveViewer(
            minScale: 1,
            maxScale: 5,
            child: Center(
              child: Image.file(
                File(widget.paths[n]),
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Padding(padding: EdgeInsets.all(24), child: Text('Không hiển thị được ảnh này.', style: TextStyle(color: Colors.white))),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------- text editor ----------
class TextEditorPage extends StatefulWidget {
  final String path;
  const TextEditorPage({super.key, required this.path});
  @override
  State<TextEditorPage> createState() => _TextEditorState();
}

class _TextEditorState extends State<TextEditorPage> {
  final t = TextEditingController();
  bool loading = true, dirty = false;
  String? err;

  @override
  void initState() {
    super.initState();
    File(widget.path).readAsString().then((v) {
      if (!mounted) return;
      t.text = v;
      setState(() => loading = false);
    }).catchError((Object e) {
      if (mounted) {
        setState(() {
          loading = false;
          err = 'Không đọc được tập tin dưới dạng văn bản.';
        });
      }
    });
  }

  @override
  void dispose() {
    t.dispose();
    super.dispose();
  }

  Future<bool> _save() async {
    try {
      await File(widget.path).writeAsString(t.text);
      if (!mounted) return true;
      setState(() => dirty = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã lưu')));
      return true;
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Không lưu được: $e')));
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !dirty,
      onPopInvokedWithResult: (did, _) async {
        if (did) return;
        final r = await showDialog<String>(
          context: context,
          builder: (d) => AlertDialog(
            title: const Text('Lưu thay đổi?'),
            content: const Text('Tập tin có thay đổi chưa lưu.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d, 'no'), child: const Text('Không lưu')),
              TextButton(onPressed: () => Navigator.pop(d), child: const Text('Huỷ')),
              FilledButton(onPressed: () => Navigator.pop(d, 'yes'), child: const Text('Lưu')),
            ],
          ),
        );
        if (r == null || !context.mounted) return;
        if (r == 'yes' && !await _save()) return;
        if (!context.mounted) return;
        setState(() => dirty = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) Navigator.pop(context);
        });
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(p.basename(widget.path), style: const TextStyle(fontSize: 17)),
          actions: [
            if (err == null && !loading) IconButton(tooltip: 'Lưu', icon: const Icon(Icons.save), onPressed: dirty ? _save : null),
            IconButton(tooltip: 'Mở bằng ứng dụng khác', icon: const Icon(Icons.apps), onPressed: () => openExternal(context, widget.path)),
          ],
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : err != null
                ? Center(child: Text(err!))
                : TextField(
                    controller: t,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    keyboardType: TextInputType.multiline,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                    decoration: const InputDecoration(border: InputBorder.none, contentPadding: EdgeInsets.all(12)),
                    onChanged: (_) {
                      if (!dirty) setState(() => dirty = true);
                    },
                  ),
      ),
    );
  }
}

// ---------- media category (grouped by folder) ----------
class MediaCatPage extends StatefulWidget {
  final Cat cat;
  const MediaCatPage({super.key, required this.cat});
  @override
  State<MediaCatPage> createState() => _MediaCatState();
}

class _MediaCatState extends State<MediaCatPage> {
  bool loading = true, folders = true;
  List<String> all = [];
  List<MapEntry<String, List<String>>> groups = [];

  bool get isVideo => widget.cat.name == 'Video';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final its = await withStats((await scan()).where((e) => widget.cat.exts.contains(extOf(e.path))).toList());
    its.sort((a, b) => b.s.modified.compareTo(a.s.modified));
    final fs = its.map((i) => i.e.path).toList();
    final m = <String, List<String>>{};
    for (final x in fs) {
      m.putIfAbsent(p.dirname(x), () => []).add(x);
    }
    final g = m.entries.toList();
    if (!mounted) return;
    setState(() {
      all = fs;
      groups = g;
      loading = false;
    });
  }

  Widget _thumb(String path, double s) {
    if (isVideo) return VideoThumb(key: ValueKey(path), path: path, size: s);
    return Image.file(File(path), width: s, height: s, fit: BoxFit.cover, cacheWidth: 360, errorBuilder: (_, __, ___) => SizedBox(width: s, height: s, child: Icon(widget.cat.icon, size: s * 0.5, color: widget.cat.color)));
  }

  Widget _chip(String label, IconData icon, bool on, VoidCallback tap) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(avatar: Icon(icon, size: 18), label: Text(label), selected: on, showCheckmark: false, onSelected: (_) => tap()),
      );

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (all.isEmpty) {
      body = const Center(child: Text('Chưa có tập tin nào thuộc loại này.', style: TextStyle(color: Colors.grey)));
    } else if (folders) {
      body = GridView.builder(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 24),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 10, mainAxisSpacing: 10),
        itemCount: groups.length,
        itemBuilder: (_, i) {
          final g = groups[i];
          final name = g.key == rootPath ? 'Bộ nhớ trong' : p.basename(g.key);
          return InkWell(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BrowserPage(mode: Mode.cat, cat: widget.cat, only: g.key))).then((_) => _load()),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: LayoutBuilder(
                builder: (_, c) => Stack(children: [
                  _thumb(g.value.first, c.maxWidth),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      color: Colors.black54,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: Row(children: [
                        const Icon(Icons.folder, color: Colors.white, size: 18),
                        const SizedBox(width: 6),
                        Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 15))),
                        Text('(${g.value.length})', style: const TextStyle(color: Colors.white70, fontSize: 13)),
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
          );
        },
      );
    } else {
      body = GridView.builder(
        padding: const EdgeInsets.only(bottom: 24),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, crossAxisSpacing: 2, mainAxisSpacing: 2),
        itemCount: all.length,
        itemBuilder: (_, i) => InkWell(
          onTap: () => openFile(context, all[i], siblings: all),
          child: LayoutBuilder(builder: (_, c) => mediaThumb(all[i], c.maxWidth)),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.cat.name),
        actions: [
          IconButton(tooltip: 'Tìm kiếm', icon: const Icon(Icons.search), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BrowserPage(mode: Mode.search)))),
          IconButton(
              tooltip: 'Làm mới',
              icon: const Icon(Icons.refresh),
              onPressed: () {
                scanCache = null;
                setState(() => loading = true);
                _load();
              }),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
          child: Row(children: [
            _chip('Thư mục', Icons.folder, folders, () => setState(() => folders = true)),
            _chip(widget.cat.name, widget.cat.icon, !folders, () => setState(() => folders = false)),
          ]),
        ),
        Expanded(child: body),
      ]),
    );
  }
}
