import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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

import 'file_operations.dart';
import 'storage.dart';
import 'trash.dart';

const rootPath = '/storage/emulated/0';

// Phien ban ung dung. So ban dung do GitHub tu dien moi lan build.
const appVersion = '1.2.0';
const appBuild = String.fromEnvironment('BUILD', defaultValue: '?');
const blue = Color(0xFF3B82E8);
final trashDir = Directory('$rootPath/.FMTrash');
late SharedPreferences prefs;
final storage = Storage();
late FileOperations operations;
late Trash trash;
final volumeChanges = ValueNotifier<int>(0);

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
  final StorageEntry e;
  Item(this.e);
  bool get isDir => e.isDir;
  String get name => p.basename(e.path);
}

class FmClip {
  final List<String> paths;
  final bool cut;
  FmClip(this.paths, this.cut);
}

final clip = ValueNotifier<FmClip?>(null);

// ---------- helpers ----------
const _vnA = 'àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ';
const _vnB = 'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd';

/// Chu thuong, bo dau tieng Viet de tim "mua" ra "Mưa".
String noAccent(String s) {
  final l = s.toLowerCase();
  final b = StringBuffer();
  for (final ch in l.split('')) {
    final i = _vnA.indexOf(ch);
    b.write(i >= 0 ? _vnB[i] : ch);
  }
  return b.toString();
}

String extOf(String path) => p.extension(path).toLowerCase().replaceFirst('.', '');

Cat? catOf(String path) {
  final x = extOf(path);
  for (final c in cats) {
    if (c.exts.contains(x)) return c;
  }
  return null;
}

String fmtSize(num b) {
  if (b < 0) return 'Không rõ';
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

/// Trang thai cua mot tac vu dai (sao chep, nen...), dung cho hop thoai tien trinh.
class Job implements TransferProgress {
  final progress = ValueNotifier<double>(0);
  final label = ValueNotifier<String>('');
  final canCancel = ValueNotifier<bool>(true);
  bool cancelled = false;

  @override
  void check() {
    if (cancelled) throw TransferCancelled();
  }

  @override
  void describe(String text) => label.value = text;

  @override
  void finishing() {
    canCancel.value = false;
    if (total > done) add(total - done);
    describe('Đang hoàn tất…');
  }
  int total = 0, done = 0;
  void start(int t) {
    total = t;
    progress.value = t > 0 ? 1e-6 : 0;
  }

  @override
  void add(int n) {
    done += n;
    progress.value = total > 0 ? (done / total).clamp(1e-6, 1.0) : 0;
  }
}

Future<int> sizeOf(String path) async {
  try {
    return await storage.size(path);
  } catch (_) {
    return 0;
  }
}

final _scanCache = <bool, Future<List<StorageEntry>>>{};
DateTime scanAt = DateTime(2000);

void invalidateScan() => _scanCache.clear();

String sigOf(Iterable<String> paths) {
  var hash = 0, count = 0;
  for (final path in paths) {
    hash ^= path.hashCode;
    count++;
  }
  return '$count:$hash';
}

Future<List<StorageEntry>> scan({bool dirs = false, bool removable = false}) async {
  if (DateTime.now().difference(scanAt).inSeconds > 30) {
    invalidateScan();
    scanAt = DateTime.now();
  }
  final entries = await _scanCache.putIfAbsent(removable, () async {
    final out = <StorageEntry>[];
    Future<void> walk(String dir, {String? physicalRoot, Set<String>? seen}) async {
      try {
        await for (final entry in storage.children(dir)) {
          final name = p.basename(entry.path);
          if (name.startsWith('.')) continue;
          final physical = physicalRoot == null ? null : p.join(physicalRoot, name);
          final fresh = physical == null || seen!.add(physical);
          if (entry.isDir) {
            if (entry.path == '$rootPath/Android') continue;
            if (fresh) out.add(entry);
            await walk(entry.path, physicalRoot: physical, seen: seen);
          } else if (entry.isFile && fresh) {
            out.add(entry);
          }
        }
      } catch (_) {
        // Continue with the next readable directory or volume.
      }
    }

    await walk(rootPath);
    if (removable) {
      try {
        final seen = <String>{};
        for (final volume in await storage.volumes()) {
          final path = volume.path;
          if (path == null) continue;
          try {
            final real = await storage.identity(path);
            await walk(path, physicalRoot: real, seen: seen);
          } catch (_) {
            // A volume can disappear while the remaining volumes are scanned.
          }
        }
      } catch (_) {
        // Internal results remain available during a volume change.
      }
    }
    return out;
  });
  return dirs ? List.of(entries) : entries.where((entry) => entry.isFile).toList();
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
              LinearProgressIndicator(value: v > 0 ? v : null, minHeight: 6),
              const SizedBox(height: 6),
              Text(v > 0 ? '${(v * 100).floor()}%   ${fmtSize(job.done)} / ${fmtSize(job.total)}' : 'Đang chuẩn bị...', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ]),
          ),
        ]),
        actions: [
          if (cancellable)
            ValueListenableBuilder<bool>(
              valueListenable: job.canCancel,
              builder: (_, enabled, __) => TextButton(
                onPressed: enabled ? () {
                  job.cancelled = true;
                  job.canCancel.value = false;
                  job.describe('Đang huỷ…');
                } : null,
                child: const Text('Huỷ'),
              ),
            ),
        ],
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
  final files = <String>[];
  for (final path in paths) {
    if (isSaf(path)) {
      try {
        if ((await storage.stat(path))?.isFile == true) files.add(await storage.materialize(path));
      } catch (error) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(storageError(error))));
        return;
      }
    } else if (FileSystemEntity.isFileSync(path)) {
      files.add(path);
    }
  }
  if (!context.mounted) return;
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

/// Danh sach the nho va USB dang gan: moi phan tu la [duong dan, ten hien thi].
Future<List<int>> dfOf(String path) async {
  try {
    final r = await Process.run('df', ['-k', path]);
    final f = r.stdout.toString().trim().split('\n').last.trim().split(RegExp(r'\s+'));
    return [int.parse(f[1]) * 1024, int.parse(f[2]) * 1024];
  } catch (_) {
    return [0, 0];
  }
}

Map<String, String> getTrash() {
  try {
    final raw = jsonDecode(prefs.getString('trash') ?? '{}') as Map;
    return {for (final entry in raw.entries) if (entry.key is String && entry.value is String) entry.key as String: entry.value as String};
  } catch (_) {
    return {};
  }
}

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
  if (isSaf(it.e.path)) return Icon(c?.icon ?? Icons.insert_drive_file, size: size, color: c?.color ?? Colors.grey);
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

/// Nut ve thang trang chu tu bat ky man hinh nao.
Widget homeBtn(BuildContext context) => IconButton(tooltip: 'Trang chủ', icon: const Icon(Icons.home), onPressed: () => Navigator.popUntil(context, (r) => r.isFirst));

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
  if (isSaf(path)) return SizedBox(width: s, height: s, child: Icon(c?.icon ?? Icons.insert_drive_file, color: c?.color));
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
  if (isSaf(path)) {
    try {
      await storage.openDocument(path);
    } catch (error) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Không mở được: ${storageError(error)}')));
    }
    return;
  }
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
  if (isSaf(path)) {
    if (c != 'Video' && c != 'Âm thanh' && c != 'Hình') {
      await openExternal(context, path);
      return;
    }
    String? local;
    try {
      local = await storage.materialize(path);
      if (context.mounted) await openFile(context, local);
    } catch (error) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Không mở được: ${storageError(error)}')));
    } finally {
      if (local != null) {
        try {
          await Directory(p.dirname(local)).delete(recursive: true);
        } on FileSystemException {
          // Startup cleanup can retry after the viewer closes its handles.
        }
      }
    }
    return;
  }
  var list = siblings?.where((item) => !isSaf(item)).toList() ?? [path];
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
  final privatePath = Platform.isAndroid
      ? (await storageChannel.invokeMethod<String>('privateDir'))!
      : Directory.systemTemp.path;
  operations = FileOperations(storage, Directory(p.join(privatePath, 'fm-transactions')));
  trash = Trash(operations, Directory(p.join(privatePath, 'fm-trash')), trashDir, rootPath, getTrash, (path) async {
    final old = getTrash()..remove(path);
    if (!await prefs.setString('trash', jsonEncode(old))) {
      throw FileSystemException('Không thể cập nhật thông tin thùng rác', path);
    }
  });
  storageChannel.setMethodCallHandler((call) async {
    if (call.method == 'changed') {
      invalidateScan();
      volumeChanges.value++;
    }
  });
  unawaited(_cleanOpenedDocuments());
  runApp(const App());
}

Future<void> _cleanOpenedDocuments() async {
  try {
    await for (final entry in Directory.systemTemp.list(followLinks: false)) {
      if (entry is Directory && p.basename(entry.path).startsWith('fm-open-') &&
          DateTime.now().difference((await entry.stat()).modified) > const Duration(days: 1)) {
        await entry.delete(recursive: true);
      }
    }
  } on FileSystemException {
    // Cache cleanup is independent of the file manager's storage operations.
  }
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

class _HomeState extends State<HomePage> with WidgetsBindingObserver {
  bool? granted;
  int total = 0, used = 0;
  List<StorageVolume> vols = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    volumeChanges.addListener(_volumesChanged);
    _init();
  }

  Future<void> _init() async {
    final g = await ensurePerm();
    if (g) await _df();
    if (mounted) setState(() => granted = g);
    await _refreshVolumes();
    await _recover();
  }

  Future<void> _df() async {
    final r = await dfOf(rootPath);
    total = r[0];
    used = r[1];
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    volumeChanges.removeListener(_volumesChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && granted != null) _volumesChanged();
  }

  void _volumesChanged() {
    unawaited(_refreshVolumes());
    unawaited(_recover());
  }

  Future<void> _recover() async {
    try {
      final errors = await operations.recover();
      if (mounted && errors.isNotEmpty) _message('Chưa thể phục hồi thao tác: ${errors.first}');
    } catch (error) {
      if (mounted) _message('Không đọc được nhật ký thao tác: ${storageError(error)}');
    }
  }

  Future<void> _refreshVolumes() async {
    try {
      final found = await storage.volumes();
      if (mounted) setState(() => vols = found);
    } catch (error) {
      if (mounted) _message('Không đọc được danh sách SD/USB: ${storageError(error)}');
    }
  }

  void _message(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _grantVolume([String? id]) async {
    try {
      final path = await storage.grant(id);
      if (path == null || !mounted) return;
      await _refreshVolumes();
      if (mounted) _open(BrowserPage(mode: Mode.dir, path: path));
    } catch (error) {
      if (mounted) _message(storageError(error));
    }
  }

  Widget _storage(String title, int total, int used, VoidCallback onTap, {int? free, String? hint}) {
    final pct = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
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
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(total > 0 ? '${fmtSize(used)}/${fmtSize(total)}' : hint ?? 'Bấm để mở', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                if (free != null && total > 0) Text('Trống ${fmtSize(free)}', style: const TextStyle(fontSize: 12)),
                if (hint != null && total > 0) Text(hint, style: const TextStyle(fontSize: 12)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _volCard(StorageVolume volume) {
    final path = volume.path;
    return _storage(
      volume.label, volume.total, volume.total - volume.free,
      path == null ? () => _grantVolume(volume.id) : () => _open(BrowserPage(mode: Mode.dir, path: path)),
      free: volume.free,
      hint: path == null ? 'Chọn thư mục để cấp quyền' : (volume.writable ? null : 'Chỉ đọc'),
    );
  }

  Widget _analyzer() => Card(
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
                  Text('Trình phân tích', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600)),
                  Text('Xem thứ gì chiếm chỗ', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12)),
                ]),
              ),
            ]),
          ),
        ),
      );

  void _open(Widget w) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => w)).then((_) async {
      await _df();
      await _refreshVolumes();
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

  Widget _categoryTiles() => _card(_grid([
    for (final category in cats)
      _tile(category.icon, category.name, category.color, () => _open(
        category.name == 'Hình' || category.name == 'Video'
            ? MediaCatPage(cat: category)
            : BrowserPage(mode: Mode.cat, cat: category),
      )),
  ]));

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (granted == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (granted == false) {
      body = Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.lock, size: 56, color: Colors.grey),
              const SizedBox(height: 12),
              const Text('Ứng dụng cần quyền truy cập bộ nhớ để hiển thị tập tin.', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _init, child: const Text('Cấp quyền')),
              TextButton(onPressed: openAppSettings, child: const Text('Mở cài đặt ứng dụng')),
              for (final volume in vols) _volCard(volume),
              if (vols.any((volume) => volume.path != null)) ...[
                _categoryTiles(),
                TextButton(onPressed: () => _open(const BrowserPage(mode: Mode.trash)), child: const Text('Thùng rác')),
              ],
            ]),
          ),
        ),
      );
    } else {
      final bm = getBm().where((path) => isSaf(path) ? vols.any((v) => v.path != null && inDirectory(v.path!, path)) : existsPath(path)).toList();
      void soon() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tính năng mạng chưa được hỗ trợ')));
      body = ListView(padding: const EdgeInsets.all(10), children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _storage('Lưu trữ nội bộ', total, used, () => _open(const BrowserPage(mode: Mode.dir)))),
          const SizedBox(width: 8),
          Expanded(child: vols.isNotEmpty ? _volCard(vols[0]) : _analyzer()),
        ]),
        for (var i = 1; i < vols.length; i++) _volCard(vols[i]),
        if (vols.isNotEmpty) _analyzer(),
        _categoryTiles(),
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
              title: Text(storageDisplayName(b)),
              subtitle: Text(storageDisplayPath(b), maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => _open(BrowserPage(mode: Mode.dir, path: b)),
            ),
        ])),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Center(child: Text('Phiên bản $appVersion (bản dựng $appBuild)', style: TextStyle(fontSize: 12, color: Colors.grey))),
        ),
      ]);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trang chủ'),
        actions: [
          if (granted != null && vols.isNotEmpty)
            IconButton(tooltip: 'Cấp quyền thư mục SD/USB', icon: const Icon(Icons.sd_storage), onPressed: _grantVolume),
          if (granted == true || vols.any((volume) => volume.path != null)) IconButton(tooltip: 'Tìm kiếm', icon: const Icon(Icons.search), onPressed: () => _open(const BrowserPage(mode: Mode.search))),
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

class _BrowserState extends State<BrowserPage> with WidgetsBindingObserver {
  Timer? _poll;
  String _lastSig = '';
  bool _checking = false;

  late String cur = widget.path;
  List<Item> items = [];
  bool loading = true;
  final sel = <String>{};
  String q = '';
  Timer? _deb;
  int _gen = 0;
  bool get _media => widget.mode == Mode.cat && (widget.cat?.name == 'Hình' || widget.cat?.name == 'Video');
  late String sort = _media ? 'date' : (prefs.getString('sort') ?? 'name');
  bool grid = prefs.getBool('grid') ?? true;
  bool hidden = prefs.getBool('hidden') ?? false;

  bool get isDir => widget.mode == Mode.dir;
  bool get isTrash => widget.mode == Mode.trash;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    volumeChanges.addListener(_volumeChanged);
    _load();
    // Tu kiem tra thu muc dang mo moi 3 giay de hien tap tin moi.
    if (isDir) _poll = Timer.periodic(const Duration(seconds: 3), (_) => _check());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _deb?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    volumeChanges.removeListener(_volumeChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted && !loading) {
      invalidateScan();
      _load(silent: true);
    }
  }

  void _volumeChanged() {
    if (!mounted) return;
    if (!isDir || !inDirectory(rootPath, cur)) unawaited(_load(silent: true));
  }

  Future<void> _check() async {
    if (!mounted || loading || _checking) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    _checking = true;
    try {
      final at = cur;
      await storage.available(at);
      final paths = isSaf(at)
          ? await storage.children(at).map((entry) => entry.path).toList()
          : await Directory(at).list(followLinks: false).map((entry) => entry.path).toList();
      if (mounted && !loading && at == cur &&
          (_directoryUnavailable || sigOf(paths.where(_visible)) != _lastSig)) {
        await _load(silent: true);
      }
    } catch (_) {
      if (mounted && !_directoryUnavailable) await _load(silent: true);
    } finally {
      _checking = false;
    }
  }

  void _msg(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  bool _directoryUnavailable = false;

  bool _visible(String path) {
    final name = p.basename(path);
    return !privateStorageName(name) && (hidden || !name.startsWith('.'));
  }

  Future<List<StorageEntry>> _visibleChildren(String path) async {
    await storage.available(path);
    return storage.children(path).where((entry) => _visible(entry.path)).toList();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => loading = true);
    final gen = ++_gen;
    var entries = <StorageEntry>[];
    var unavailable = false;
    try {
      switch (widget.mode) {
        case Mode.dir:
          entries = await _visibleChildren(cur);
        case Mode.cat:
          entries = (await scan(removable: true)).where((e) => widget.cat!.exts.contains(extOf(e.path)) && (widget.only == null || p.dirname(e.path) == widget.only)).toList();
        case Mode.recent:
          entries = await scan();
        case Mode.search:
          final term = noAccent(q.trim());
          entries = term.isEmpty ? [] : (await scan(dirs: true, removable: true)).where((e) => noAccent(p.basename(e.path)).contains(term)).toList();
        case Mode.trash:
          entries = await trash.list();
      }
    } catch (error) {
      unavailable = isDir;
      if (gen == _gen && (!_directoryUnavailable || !silent)) _msg('Không đọc được thư mục: ${storageError(error)}');
    }
    var out = entries.map(Item.new).toList();
    if (widget.mode == Mode.recent) {
      out.sort((a, b) => b.e.modified.compareTo(a.e.modified));
      out = out.take(50).toList();
    } else {
      _sort(out);
    }
    if (!mounted) return;
    if (gen != _gen) return;
    setState(() {
      _directoryUnavailable = unavailable;
      if (isDir) _lastSig = sigOf(entries.map((entry) => entry.path));
      items = out;
      loading = false;
      if (silent) {
        final have = out.map((i) => i.e.path).toSet();
        sel.removeWhere((x) => !have.contains(x));
      } else {
        sel.clear();
      }
    });
  }

  void _sort(List<Item> l) {
    int byName(Item a, Item b) => a.name.toLowerCase().compareTo(b.name.toLowerCase());
    int c(Item a, Item b) {
      switch (sort) {
        case 'date':
          return b.e.modified.compareTo(a.e.modified);
        case 'size':
          return b.e.size.compareTo(a.e.size);
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
      _msg('Lỗi: ${storageError(e)}');
    }
    invalidateScan();
    if (mounted) {
      sel.clear();
      await _load(silent: true);
    }
  }

  bool _badName(String? s) {
    if (s == null) return true;
    if (s.isEmpty || s == '.' || s == '..' || s.contains('/') || s.contains('\u0000') || privateStorageName(s)) {
      _msg('Tên không hợp lệ');
      return true;
    }
    return false;
  }

  Future<void> _newFolder() async {
    final s = await prompt(context, 'Thư mục mới', 'Thư mục mới');
    if (_badName(s)) return;
    await _run(() => operations.exclusive(() async {
      await storage.available(cur);
      await storage.createDirectory(await storage.unique(cur, s!));
    }), 'Đã tạo thư mục');
  }

  Future<void> _newFile() async {
    final s = await prompt(context, 'Tập tin văn bản mới', 'Ghi chú mới.txt');
    if (_badName(s)) return;
    await _run(() => operations.exclusive(() async {
      await storage.available(cur);
      final stream = await storage.open(await storage.unique(cur, s!), write: true);
      await stream.close();
    }), 'Đã tạo tập tin');
  }

  Future<void> _rename(String path) async {
    final s = await prompt(context, 'Đổi tên', p.basename(path));
    if (_badName(s) || s == p.basename(path)) return;
    final dest = p.join(p.dirname(path), s!);
    await _run(() async { await operations.move(path, dest, fast: true); }, 'Đã đổi tên');
  }

  Future<void> _trashBatch(
    List<String> paths, String title, String success, Future<void> Function(String) apply,
  ) async {
    final job = Job();
    final errors = <String>[];
    var completed = 0;
    await runJob(context, title, job, () async {
      job.start(paths.length);
      for (final path in paths) {
        if (job.cancelled) break;
        job.describe(p.basename(path));
        try {
          await apply(path);
          completed++;
        } catch (error) {
          errors.add('${p.basename(path)}: ${storageError(error)}');
        }
        job.add(1);
      }
    });
    final result = '$success $completed/${paths.length} mục';
    if (errors.isNotEmpty && mounted) {
      await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(result),
          content: SingleChildScrollView(child: Text(errors.join('\n'))),
          actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Đóng'))],
        ),
      );
    } else {
      _msg(job.cancelled ? '$result. Đã huỷ phần còn lại' : result);
    }
    invalidateScan();
    if (mounted) await _load();
  }

  Future<void> _delete(List<String> paths) async {
    final selected = FileOperations.selection(paths);
    if (!await confirm(context, 'Xoá ${selected.length} mục?', 'Các mục sẽ vào Thùng rác và có thể khôi phục.', 'Xoá') || !mounted) return;
    await _trashBatch(selected, 'Đang chuyển vào Thùng rác', 'Đã chuyển vào Thùng rác', trash.put);
  }

  Future<void> _restore(List<String> paths) =>
      _trashBatch(paths, 'Đang khôi phục', 'Đã khôi phục', trash.restore);

  Future<void> _purge(List<String> paths) async {
    if (!await confirm(context, 'Xoá hẳn ${paths.length} mục?', 'Không thể khôi phục sau khi xoá hẳn.', 'Xoá hẳn') || !mounted) return;
    await _trashBatch(paths, 'Đang xoá hẳn', 'Đã xoá hẳn', trash.purge);
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
    final directory = cur;
    var conflicts = 0;
    try {
      await storage.available(directory);
      for (final source in c.paths) {
        if (p.dirname(source) != directory &&
            await storage.stat(p.join(directory, p.basename(source))) != null) conflicts++;
      }
    } catch (error) {
      _msg('Lỗi: ${storageError(error)}');
      return;
    }
    if (!mounted || cur != directory || clip.value != c) return;
    var mode = Conflict.keep;
    if (conflicts > 0) {
      final choice = await showDialog<Conflict>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text('$conflicts mục trùng tên'),
          content: const Text('Ghi đè thư mục sẽ gộp nội dung và giữ lại các mục chỉ có ở đích.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, Conflict.skip), child: const Text('Bỏ qua')),
            TextButton(onPressed: () => Navigator.pop(d, Conflict.keep), child: const Text('Giữ cả hai')),
            FilledButton(onPressed: () => Navigator.pop(d, Conflict.overwrite), child: const Text('Ghi đè')),
          ],
        ),
      );
      if (choice == null || !mounted || cur != directory || clip.value != c) return;
      mode = choice;
    }
    final job = Job();
    var result = '';
    await runJob(context, c.cut ? 'Đang di chuyển' : 'Đang sao chép', job, () async {
      try {
        var total = 0;
        for (final source in FileOperations.selection(c.paths)) {
          await storage.available(source);
          total += await storage.size(source, check: job.check);
        }
        job.start(total);
        final count = await operations.paste(c.paths, directory, move: c.cut, conflict: mode, progress: job);
        if (clip.value == c) clip.value = null;
        result = c.cut ? 'Đã di chuyển $count mục' : 'Đã sao chép $count mục';
      } on TransferCancelled {
        result = 'Đã huỷ';
      } catch (error) {
        result = 'Lỗi: ${storageError(error)}';
      }
    });
    _msg(result);
    invalidateScan();
    if (mounted) {
      sel.clear();
      await _load(silent: true);
    }
  }

  Future<void> _extract(String path) async {
    if (isSaf(path)) {
      await openExternal(context, path);
      return;
    }
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
    invalidateScan();
    if (mounted) {
      sel.clear();
      await _load(silent: true);
    }
  }

  Future<void> _zip(List<String> paths) async {
    if (paths.isEmpty) return;
    if (paths.any(isSaf) || (isDir && isSaf(cur))) {
      _msg('Hãy sao chép các mục vào bộ nhớ trong để nén ZIP');
      return;
    }
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
    invalidateScan();
    if (mounted) {
      sel.clear();
      await _load(silent: true);
    }
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
          row('Vị trí', Text(storageDisplayPath(p.dirname(it.e.path)))),
          row('Kích thước', FutureBuilder<int>(future: sizeOf(it.e.path), builder: (_, s) => Text(s.hasData ? fmtSize(s.data!) : 'Đang tính...'))),
          row('Sửa đổi', Text(fmtDate(it.e.modified))),
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
    if (!isSaf(path) && isArchive(path)) {
      if (await confirm(context, 'Giải nén?', 'Giải nén "${it.name}" vào một thư mục mới cùng chỗ.', 'Giải nén')) await _extract(path);
      return;
    }
    final c = catOf(path);
    final sib = c == null ? null : items.where((i) => !i.isDir && catOf(i.e.path) == c).map((i) => i.e.path).toList();
    await openFile(context, path, siblings: sib);
    if (mounted && textExts.contains(extOf(path))) _load(silent: true);
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
              if (!isSaf(path) && isArchive(path)) o(Icons.unarchive, 'Giải nén', () => _extract(path)),
              if (!isSaf(path)) o(Icons.archive, 'Nén thành zip', () => _zip([path])),
              o(Icons.edit, 'Đổi tên', () => _rename(path)),
              if (clip.value == null) o(Icons.copy, 'Sao chép', () => _toClip([path], false)),
              if (clip.value == null) o(Icons.drive_file_move, 'Di chuyển', () => _toClip([path], true)),
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
    final a = it.isDir ? 'Thư mục' : fmtSize(it.e.size);
    return isDir ? '$a | ${fmtDate(it.e.modified)}' : '$a | ${storageDisplayPath(p.dirname(it.e.path))}';
  }

  String get _title {
    switch (widget.mode) {
      case Mode.dir:
        return cur == rootPath ? 'Bộ nhớ trong' : storageDisplayName(cur);
      case Mode.cat:
        return widget.only != null ? storageDisplayName(widget.only!) : widget.cat!.name;
      case Mode.recent:
        return 'Gần đây';
      case Mode.trash:
        return 'Thùng rác';
      case Mode.search:
        return 'Tìm kiếm';
    }
  }

  PreferredSizeWidget? _crumbs() {
    final base = inDirectory(rootPath, cur) ? rootPath : widget.path;
    if (!isDir || sel.isNotEmpty || !p.isWithin(base, cur)) return null;
    final parts = p.split(p.relative(cur, from: base));
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
            b(base == rootPath ? 'Bộ nhớ trong' : storageDisplayName(base), base),
            for (var i = 0; i < parts.length; i++) ...[
              const Icon(Icons.chevron_right, color: Colors.white70, size: 18),
              b(parts[i], p.joinAll([base, ...parts.sublist(0, i + 1)])),
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
        Mode.dir: _directoryUnavailable ? 'Không truy cập được thư mục. Hãy kiểm tra kết nối và quyền SD/USB.' : 'Thư mục trống. Nhấn + để thêm.',
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
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, childAspectRatio: 0.7),
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
                  if (!it.isDir) Text(fmtSize(it.e.size), maxLines: 1, style: const TextStyle(fontSize: 11, color: Colors.grey)),
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
                      onChanged: (s) {
                        q = s;
                        _deb?.cancel();
                        _deb = Timer(const Duration(milliseconds: 500), _load);
                      },
                      onSubmitted: (s) {
                        q = s;
                        _deb?.cancel();
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
                    if (clip.value == null) IconButton(tooltip: 'Sao chép', icon: const Icon(Icons.copy), onPressed: () => _toClip(picked, false)),
                    if (clip.value == null) IconButton(tooltip: 'Di chuyển', icon: const Icon(Icons.drive_file_move), onPressed: () => _toClip(picked, true)),
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
                  homeBtn(context),
                  if (widget.mode != Mode.search) IconButton(tooltip: 'Tìm kiếm', icon: const Icon(Icons.search), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BrowserPage(mode: Mode.search)))),
                  PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'grid') {
                        setState(() => grid = !grid);
                        prefs.setBool('grid', grid);
                      } else if (v == 'empty') {
                        _purge(items.map((i) => i.e.path).toList());
                      } else if (v == 'refresh') {
                        invalidateScan();
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
        floatingActionButton: isDir && !selecting && !_directoryUnavailable
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
        bottomNavigationBar: isDir && !_directoryUnavailable
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
                            OutlinedButton(
                                onPressed: () {
                                  clip.value = null;
                                  setState(() {});
                                },
                                child: const Text('Huỷ')),
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
  late final Future<List<Item>> future = scan().then((entries) => entries.map(Item.new).toList());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Trình phân tích'), actions: [homeBtn(context)]),
      body: FutureBuilder<List<Item>>(
        future: future,
        builder: (_, s) {
          if (!s.hasData) return const Center(child: CircularProgressIndicator());
          final fs = s.data!;
          final tot = fs.fold<int>(0, (a, i) => a + i.e.size);
          final by = <String, int>{for (final c in cats) c.name: 0, 'Khác': 0};
          for (final i in fs) {
            final k = catOf(i.e.path)?.name ?? 'Khác';
            by[k] = by[k]! + i.e.size;
          }
          fs.sort((a, b) => b.e.size.compareTo(a.e.size));
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
                subtitle: Text('${fmtSize(it.e.size)} | ${storageDisplayPath(p.dirname(it.e.path))}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
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
  bool _awake = false;

  /// Giu man hinh sang trong luc dang phat, tat khi tam dung hoac thoat.
  void _keepOn(bool on) {
    if (on == _awake) return;
    _awake = on;
    nativeCh.invokeMethod('keepOn', {'src': on ? '1' : '0', 'dest': ''}).catchError((_) => null);
  }
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
    _keepOn(v.isPlaying);
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
    _keepOn(false);
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

class _MediaCatState extends State<MediaCatPage> with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      invalidateScan();
      _load();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    volumeChanges.removeListener(_volumeChanged);
    super.dispose();
  }

  bool loading = true, folders = true;
  List<String> all = [];
  List<MapEntry<String, List<String>>> groups = [];

  bool get isVideo => widget.cat.name == 'Video';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    volumeChanges.addListener(_volumeChanged);
    _load();
  }

  int _loadGeneration = 0;

  void _volumeChanged() => unawaited(_load());

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final its = (await scan(removable: true)).where((e) => widget.cat.exts.contains(extOf(e.path))).map(Item.new).toList();
    its.sort((a, b) => b.e.modified.compareTo(a.e.modified));
    final fs = its.map((i) => i.e.path).toList();
    final m = <String, List<String>>{};
    for (final x in fs) {
      m.putIfAbsent(p.dirname(x), () => []).add(x);
    }
    final g = m.entries.toList();
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      all = fs;
      groups = g;
      loading = false;
    });
  }

  Widget _thumb(String path, double s) {
    if (isSaf(path)) return mediaThumb(path, s);
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
          final name = g.key == rootPath ? 'Bộ nhớ trong' : storageDisplayName(g.key);
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
          homeBtn(context),
          IconButton(tooltip: 'Tìm kiếm', icon: const Icon(Icons.search), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BrowserPage(mode: Mode.search)))),
          IconButton(
              tooltip: 'Làm mới',
              icon: const Icon(Icons.refresh),
              onPressed: () {
                invalidateScan();
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
