import 'dart:convert';
import 'dart:io';

import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
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

class Clip {
  final List<String> paths;
  final bool cut;
  Clip(this.paths, this.cut);
}

final clip = ValueNotifier<Clip?>(null);

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

Future<void> copyEntity(String src, String dest) async {
  if (FileSystemEntity.isDirectorySync(src)) {
    await Directory(dest).create(recursive: true);
    await for (final e in Directory(src).list(followLinks: false)) {
      await copyEntity(e.path, p.join(dest, p.basename(e.path)));
    }
  } else {
    await File(src).copy(dest);
  }
}

Future<void> deleteEntity(String src) async {
  if (FileSystemEntity.isDirectorySync(src)) {
    await Directory(src).delete(recursive: true);
  } else {
    await File(src).delete();
  }
}

Future<void> moveEntity(String src, String dest) async {
  try {
    if (FileSystemEntity.isDirectorySync(src)) {
      await Directory(src).rename(dest);
    } else {
      await File(src).rename(dest);
    }
  } catch (_) {
    await copyEntity(src, dest);
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

Future<List<FileSystemEntity>> scan({bool dirs = false}) async {
  final out = <FileSystemEntity>[];
  Future<void> walk(Directory d) async {
    try {
      await for (final e in d.list(followLinks: false)) {
        if (p.basename(e.path).startsWith('.')) continue;
        if (e is Directory) {
          if (e.path == '$rootPath/Android') continue;
          if (dirs) out.add(e);
          await walk(e);
        } else if (e is File) {
          out.add(e);
        }
      }
    } catch (_) {}
  }

  await walk(Directory(rootPath));
  return out;
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
  if (it.isDir) return Icon(Icons.folder, size: size, color: const Color(0xFFF2B63C));
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
  if (c != null && c.name == 'APP') return VideoThumb(key: ValueKey(it.e.path), path: it.e.path, size: size, apk: true);
  return Icon(c?.icon ?? Icons.insert_drive_file, size: size, color: c?.color ?? Colors.grey);
}

const nativeCh = MethodChannel('fm/native');

/// Anh thu nho cho video hoac icon cua tap tin APK, tao bang ma Android goc.
class VideoThumb extends StatefulWidget {
  final String path;
  final double size;
  final bool apk;
  const VideoThumb({super.key, required this.path, required this.size, this.apk = false});
  @override
  State<VideoThumb> createState() => _VideoThumbState();
}

class _VideoThumbState extends State<VideoThumb> {
  late final Future<String?> future = _make();

  Future<String?> _make() async {
    try {
      final dir = Directory('${Directory.systemTemp.path}/thumbs');
      await dir.create(recursive: true);
      final src = widget.path;
      final st = await File(src).stat();
      final dest = '${dir.path}/${src.hashCode}_${st.size}.${widget.apk ? 'png' : 'jpg'}';
      if (await File(dest).exists()) return dest;
      try {
        final ok = await nativeCh.invokeMethod<bool>(widget.apk ? 'apkIcon' : 'videoThumb', {'src': src, 'dest': dest});
        if (ok == true) return dest;
      } catch (_) {}
      if (widget.apk) return null;
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
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final fallback = widget.apk ? Icon(Icons.android, size: s, color: const Color(0xFF4CAE6C)) : Icon(Icons.videocam, size: s, color: const Color(0xFF3FBFB4));
    return FutureBuilder<String?>(
      future: future,
      builder: (_, snap) {
        if (snap.data == null) return fallback;
        final img = Image.file(File(snap.data!), width: s, height: s, fit: widget.apk ? BoxFit.contain : BoxFit.cover, errorBuilder: (_, __, ___) => fallback);
        if (widget.apk) return img;
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(alignment: Alignment.center, children: [
            img,
            Container(decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle), child: Icon(Icons.play_arrow, color: Colors.white, size: s * 0.45)),
          ]),
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

Future<void> openFile(BuildContext context, String path) async {
  final c = catOf(path)?.name;
  if (c == 'Video' || c == 'Âm thanh') {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerPage(path: path, video: c == 'Video')));
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
        _card(_grid([for (final c in cats) _tile(c.icon, c.name, c.color, () => _open(BrowserPage(mode: Mode.cat, cat: c)))])),
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
  const BrowserPage({super.key, required this.mode, this.path = rootPath, this.cat});
  @override
  State<BrowserPage> createState() => _BrowserState();
}

class _BrowserState extends State<BrowserPage> {
  late String cur = widget.path;
  List<Item> items = [];
  bool loading = true;
  final sel = <String>{};
  String q = '';
  String sort = prefs.getString('sort') ?? 'name';
  bool grid = prefs.getBool('grid') ?? false;

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
          es = (await Directory(cur).list(followLinks: false).toList()).where((e) => !p.basename(e.path).startsWith('.')).toList();
        case Mode.cat:
          es = (await scan()).where((e) => widget.cat!.exts.contains(extOf(e.path))).toList();
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
    clip.value = Clip(paths, cut);
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
    clip.value = null;
    await _run(() async {
      for (final s in c.paths) {
        if (!existsPath(s)) continue;
        if (c.cut) {
          if (p.dirname(s) == cur) continue;
          await moveEntity(s, uniquePath(cur, p.basename(s)));
        } else {
          await copyEntity(s, uniquePath(cur, p.basename(s)));
        }
      }
    }, c.cut ? 'Đã di chuyển ${c.paths.length} mục' : 'Đã sao chép ${c.paths.length} mục');
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
    await openFile(context, it.e.path);
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
        return widget.cat!.name;
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
    final sp = sel.toList();
    Item one() => items.firstWhere((i) => i.e.path == sp.first);

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
    } else if (grid) {
      body = GridView.builder(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 90),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, childAspectRatio: 0.85),
        itemCount: items.length,
        itemBuilder: (_, i) {
          final it = items[i], on = sel.contains(it.e.path);
          return InkWell(
            onTap: () => _tap(it),
            onLongPress: () => setState(() => sel.add(it.e.path)),
            child: Container(
              decoration: BoxDecoration(color: on ? blue.withAlpha(50) : null, borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.all(6),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                on ? const Icon(Icons.check_circle, size: 60, color: blue) : fileIcon(it, size: 60),
                const SizedBox(height: 6),
                Text(it.name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13)),
              ]),
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
                    IconButton(tooltip: 'Khôi phục', icon: const Icon(Icons.restore), onPressed: () => _restore(sp)),
                    IconButton(tooltip: 'Xoá hẳn', icon: const Icon(Icons.delete_forever), onPressed: () => _purge(sp)),
                  ] else ...[
                    IconButton(tooltip: 'Sao chép', icon: const Icon(Icons.copy), onPressed: () => _toClip(sp, false)),
                    IconButton(tooltip: 'Di chuyển', icon: const Icon(Icons.drive_file_move), onPressed: () => _toClip(sp, true)),
                    IconButton(tooltip: 'Xoá', icon: const Icon(Icons.delete), onPressed: () => _delete(sp)),
                    if (sel.length == 1)
                      PopupMenuButton<String>(
                        onSelected: (v) => v == 'ren' ? _rename(sp.first) : _info(one()),
                        itemBuilder: (_) => const [PopupMenuItem(value: 'ren', child: Text('Đổi tên')), PopupMenuItem(value: 'info', child: Text('Chi tiết'))],
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
                        _load();
                      } else {
                        sort = v;
                        prefs.setString('sort', v);
                        _load();
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'grid', child: Text(grid ? 'Xem dạng danh sách' : 'Xem dạng lưới')),
                      const PopupMenuItem(value: 'refresh', child: Text('Làm mới')),
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
            ? ValueListenableBuilder<Clip?>(
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
            ? ValueListenableBuilder<Clip?>(
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
  final String path;
  final bool video;
  const PlayerPage({super.key, required this.path, required this.video});
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
    c.initialize().then((_) {
      if (!mounted) return;
      setState(() => ready = true);
      c.play();
    }).catchError((Object e) {
      if (mounted) setState(() => err = '$e');
    });
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(_tick);
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
        IconButton(tooltip: 'Lùi 10 giây', iconSize: 34, color: Colors.white, icon: const Icon(Icons.replay_10), onPressed: ready ? () => _seek(v.position - const Duration(seconds: 10)) : null),
        const SizedBox(width: 16),
        IconButton(tooltip: v.isPlaying ? 'Tạm dừng' : 'Phát', iconSize: 56, color: Colors.white, icon: Icon(v.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled), onPressed: ready ? _toggle : null),
        const SizedBox(width: 16),
        IconButton(tooltip: 'Tới 10 giây', iconSize: 34, color: Colors.white, icon: const Icon(Icons.forward_10), onPressed: ready ? () => _seek(v.position + const Duration(seconds: 10)) : null),
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
