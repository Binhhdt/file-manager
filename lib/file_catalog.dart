import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'storage.dart';

class CatalogRoot {
  final String path, identity;
  const CatalogRoot(this.path, [String? identity])
      : identity = identity ?? path;
}

class _Folder {
  final Map<String, StorageEntry> entries;
  final int stamp;
  const _Folder(this.entries, this.stamp);
}

class _Changes {
  bool list = false, audit = false;
  final paths = <String>{};
  bool get empty => !list && paths.isEmpty;
}

class _LocalRead {
  final String path;
  final Set<String> known, dirty;
  final bool list, audit;

  const _LocalRead(this.path, this.known, this.dirty, this.list, this.audit);

  _FolderDelta read() {
    final changed = <String, StorageEntry>{};
    final missing = <String>{};
    void add(String path, FileSystemEntityType type) {
      if (type == FileSystemEntityType.link) {
        changed[path] =
            StorageEntry(path, type, 0, DateTime.fromMillisecondsSinceEpoch(0));
      } else if (type != FileSystemEntityType.notFound) {
        final stat = FileStat.statSync(path);
        if (stat.type != FileSystemEntityType.notFound) {
          changed[path] = StorageEntry.local(path, stat);
        }
      }
    }

    if (list) {
      missing.addAll(known);
      for (final entry in Directory(path).listSync(followLinks: false)) {
        final name = p.basename(entry.path);
        if (privateStorageName(name)) continue;
        missing.remove(entry.path);
        if (!audit && known.contains(entry.path) && !dirty.contains(entry.path))
          continue;
        final type = entry is Link
            ? FileSystemEntityType.link
            : (entry is Directory
                ? FileSystemEntityType.directory
                : FileSystemEntityType.file);
        add(entry.path, type);
        if (!changed.containsKey(entry.path)) missing.add(entry.path);
      }
    } else {
      for (final child in dirty) {
        if (p.dirname(child) != path || privateStorageName(p.basename(child)))
          continue;
        add(child, FileSystemEntity.typeSync(child, followLinks: false));
        if (!changed.containsKey(child)) missing.add(child);
      }
    }
    return _FolderDelta(changed, missing);
  }
}

class _FolderDelta {
  final Map<String, StorageEntry> entries;
  final Set<String> removed;
  const _FolderDelta(this.entries, this.removed);
}

int _stamp(FileStat stat) =>
    stat.modified.microsecondsSinceEpoch ^
    (stat.changed.microsecondsSinceEpoch << 1);

bool _same(StorageEntry? a, StorageEntry b) =>
    a != null &&
    a.type == b.type &&
    a.size == b.size &&
    a.modified == b.modified &&
    a.version == b.version &&
    a.identity == b.identity;

class FileCatalog {
  final Storage storage;
  final String internalRoot;
  final Directory? directory;
  final bool watch;
  final _folders = <String, _Folder>{};
  final _views = <bool, (String, List<StorageEntry>)>{};
  final _pending = <String, Future<List<StorageEntry>>>{};
  final _dirty = <String, _Changes>{};
  final _watches = <String, StreamSubscription<FileSystemEvent>>{};
  final _auditedAt = <String, DateTime>{};
  final _listedAt = <String, DateTime>{};
  final _updates = StreamController<String>.broadcast();
  late final Future<void> ready = _readCache();
  Timer? _saveTimer;
  Future<void>? _saving;
  Future<void>? _treeRequest;
  String? _checkedRoots;
  DateTime? _checkedTreeAt;
  int _auditCursor = 0;
  bool foreground = true;

  FileCatalog(this.storage, this.internalRoot,
      {this.directory, this.watch = true});

  Stream<String> get changes => _updates.stream;

  List<StorageEntry>? cached(String path) =>
      _folders[path]?.entries.values.toList();

  void markPath(String path) => markPaths([path]);

  void markPaths(Iterable<String> paths) {
    final affected = <String>{};
    for (final path in paths) {
      if (privateStorageName(p.basename(path))) continue;
      final folder = p.dirname(path);
      if (!_folders.containsKey(folder) && !_pending.containsKey(folder))
        continue;
      (_dirty[folder] ??= _Changes()).paths.add(path);
      affected.add(folder);
    }
    for (final folder in affected) {
      _updates.add(folder);
    }
  }

  void markDirectory(String path) {
    final change = _dirty[path] ??= _Changes();
    if (!change.list) {
      change.list = true;
      _updates.add(path);
    }
    markPath(path);
  }

  void markSubtrees(Set<String> roots) {
    if (roots.isEmpty) return;
    for (final path in _folders.keys) {
      var parent = path;
      while (!roots.contains(parent) && parent != p.dirname(parent)) {
        parent = p.dirname(parent);
      }
      if (roots.contains(parent)) {
        final change = _dirty[path] ??= _Changes();
        change.audit = true;
        if (!change.list) {
          change.list = true;
          _updates.add(path);
        }
      }
    }
    markPaths(roots);
  }

  void recheckTree() {
    _checkedTreeAt = null;
    _listedAt.clear();
  }

  void _watch(String path, {required bool priority}) {
    if (!watch ||
        !foreground ||
        isSaf(path) ||
        _watches.containsKey(path) ||
        !FileSystemEntity.isWatchSupported) return;
    if (_watches.length >= 256) {
      if (!priority) return;
      unawaited(_watches.remove(_watches.keys.first)!.cancel());
    }
    try {
      _watches[path] = Directory(path).watch().listen((event) {
        if (event.path == path) {
          (_dirty[path] ??= _Changes()).list = true;
          _updates.add(path);
        } else {
          markPath(event.path);
          if (event is FileSystemMoveEvent && event.destination != null) {
            markPath(event.destination!);
          }
        }
      },
          onError: (Object error) => _watchEnded(path),
          onDone: () => _watchEnded(path));
    } on FileSystemException {
      // Some Android mounts expose directory timestamps without inotify.
    }
  }

  void _watchEnded(String path) {
    final subscription = _watches.remove(path);
    if (subscription != null) unawaited(subscription.cancel());
    _auditedAt.remove(path);
  }

  void setForeground(bool value) {
    if (foreground == value) return;
    foreground = value;
    if (value) {
      recheckTree();
    } else {
      for (final listener in _watches.values) {
        unawaited(listener.cancel());
      }
      _watches.clear();
      if (_saveTimer != null) unawaited(save());
    }
  }

  Future<List<StorageEntry>> refresh(String path,
      {bool audit = false, bool priority = false, bool force = false}) {
    final active = _pending[path];
    if (active != null) return active;
    final work = _refresh(path, audit: audit, priority: priority, force: force);
    _pending[path] = work;
    return work.whenComplete(() => _pending.remove(path));
  }

  Future<List<StorageEntry>> _refresh(String path,
      {required bool audit,
      required bool priority,
      required bool force}) async {
    await ready;
    final old = _folders[path];
    final pending = _dirty.remove(path) ?? _Changes();
    final now = DateTime.now();
    int stamp = 0;
    try {
      if (priority || isSaf(path)) await storage.available(path);
      _watch(path, priority: priority);
      _FolderDelta delta;
      if (isSaf(path)) {
        final last = _listedAt[path];
        if (!audit &&
            !force &&
            pending.empty &&
            old != null &&
            last != null &&
            now.difference(last) < Duration(seconds: priority ? 3 : 30)) {
          return old.entries.values.toList();
        }
        final entries = {
          await for (final row in storage.children(path))
            if (!privateStorageName(p.basename(row.path))) row.path: row,
        };
        delta = _FolderDelta(
            entries, {...?old?.entries.keys}..removeAll(entries.keys));
        _listedAt[path] = now;
      } else {
        final stat = await FileStat.stat(path);
        if (stat.type != FileSystemEntityType.directory) {
          throw FileSystemException('Không đọc được thư mục', path);
        }
        stamp = _stamp(stat);
        final lastAudit = _auditedAt[path];
        final periodicAudit = priority &&
            (lastAudit == null ||
                now.difference(lastAudit) >= const Duration(seconds: 30));
        final verify = audit || periodicAudit || old == null || pending.audit;
        final list = verify || force || pending.list || old.stamp != stamp;
        if (!list && pending.paths.isEmpty) {
          return old.entries.values.toList();
        }
        final request = _LocalRead(
            path,
            list ? {...?old?.entries.keys} : const {},
            pending.paths,
            list,
            verify);
        delta = await Isolate.run(request.read);
        if (request.audit) _auditedAt[path] = now;
      }

      final entries = old?.entries ?? <String, StorageEntry>{};
      var changed = old == null;
      for (final gone in delta.removed) {
        if (entries.remove(gone) case final previous?) {
          changed = true;
          if (previous.isDir) _dropFolder(gone);
        }
      }
      for (final entry in delta.entries.values) {
        final previous = entries[entry.path];
        if (_same(previous, entry)) continue;
        if (previous?.isDir == true && !entry.isDir) _dropFolder(entry.path);
        entries[entry.path] = entry;
        changed = true;
      }
      _folders[path] = _Folder(entries, stamp);
      if (changed) {
        _views.clear();
        _scheduleSave();
      }
      return entries.values.toList();
    } catch (_) {
      _dropFolder(path);
      rethrow;
    }
  }

  void _dropFolder(String path) {
    final folder = _folders.remove(path);
    if (folder == null) return;
    _views.clear();
    for (final entry in folder.entries.values) {
      if (entry.isDir) _dropFolder(entry.path);
    }
    _watchEnded(path);
    _dirty.remove(path);
    _listedAt.remove(path);
    _auditedAt.remove(path);
    _scheduleSave();
  }

  bool _walkable(StorageEntry entry) =>
      !p.basename(entry.path).startsWith('.') &&
      entry.path != p.join(internalRoot, 'Android') &&
      (entry.isDir || entry.isFile);

  List<StorageEntry>? cachedTree(List<CatalogRoot> roots, {bool dirs = false}) {
    if (!roots.any((root) => _folders.containsKey(root.path))) return null;
    final key = jsonEncode([
      for (final root in roots) [root.path, root.identity]
    ]);
    final previous = _views[dirs];
    if (previous != null && previous.$1 == key) return previous.$2;
    final seen = <String>{};
    final result = <StorageEntry>[];
    void collect(String path, String identity) {
      for (final entry
          in _folders[path]?.entries.values ?? const <StorageEntry>[]) {
        if (!_walkable(entry)) continue;
        final real = p.join(identity, p.basename(entry.path));
        final fresh = seen.add(real);
        if (fresh && (dirs || entry.isFile)) result.add(entry);
        if (entry.isDir) collect(entry.path, real);
      }
    }

    for (final root in roots) {
      collect(root.path, root.identity);
    }
    final view = List<StorageEntry>.unmodifiable(result);
    _views[dirs] = (key, view);
    return view;
  }

  Future<void> refreshTree(List<CatalogRoot> roots,
      {bool force = false}) async {
    await ready;
    final key = jsonEncode(roots.map((root) => root.path).toList());
    while (_treeRequest != null) {
      await _treeRequest!;
      if (_checkedRoots == key && !force && _dirty.isEmpty) return;
    }
    if (!foreground) return;
    final last = _checkedTreeAt;
    final checkTree = force ||
        _checkedRoots != key ||
        last == null ||
        DateTime.now().difference(last) >= const Duration(seconds: 20);
    final paths = checkTree
        ? roots.map((root) => root.path).toList()
        : _dirty.keys
            .where((path) => roots.any((root) => inDirectory(root.path, path)))
            .toList();
    if (paths.isEmpty) return;
    final task = () async {
      await _walk(paths, force: force, knownTree: !checkTree);
      if (checkTree && foreground) {
        final existing = _folders.keys
            .where((path) =>
                !isSaf(path) &&
                roots.any((root) => inDirectory(root.path, path)))
            .toList();
        if (existing.isNotEmpty) {
          // Permit a bounded audit for in-place edits made while unwatched.
          for (var i = 0; foreground && i < 4 && i < existing.length; i++) {
            final path = existing[_auditCursor++ % existing.length];
            final last = _auditedAt[path];
            if (last == null ||
                DateTime.now().difference(last) >= const Duration(minutes: 2)) {
              try {
                await refresh(path, audit: true);
              } catch (_) {}
            }
          }
        }
      }
    }();
    _treeRequest = task;
    try {
      await task;
      if (foreground && checkTree) {
        _checkedRoots = key;
        _checkedTreeAt = DateTime.now();
      }
    } finally {
      _treeRequest = null;
    }
  }

  Future<void> _walk(List<String> paths,
      {required bool force, required bool knownTree}) async {
    final visited = <String>{};
    var level = paths;
    while (foreground && level.isNotEmpty) {
      final next = <String>[];
      for (var offset = 0; foreground && offset < level.length; offset += 4) {
        await Future.wait(
            level.skip(offset).take(4).where(visited.add).map((path) async {
          try {
            final entries = await refresh(path, force: force);
            for (final entry in entries) {
              if (entry.isDir &&
                  _walkable(entry) &&
                  (!knownTree || !_folders.containsKey(entry.path))) {
                next.add(entry.path);
              }
            }
          } catch (_) {
            // Keep the contents of other readable folders and volumes.
          }
        }));
      }
      level = next;
    }
  }

  void _scheduleSave() {
    if (directory == null || _saveTimer != null) return;
    _saveTimer = Timer(const Duration(seconds: 2), () {
      _saveTimer = null;
      if (_treeRequest != null && foreground) {
        _scheduleSave();
      } else {
        unawaited(save());
      }
    });
  }

  Future<void> save() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    final path = directory?.path;
    if (path == null) return;
    final task = (_saving ?? Future<void>.value()).then((_) async {
      final folders = Map<String, _Folder>.of(_folders);
      try {
        await _saveOnWorker(path, folders);
      } on FileSystemException {
        // Browsing still works when the private cache cannot be saved.
      }
    });
    _saving = task;
    await task;
    if (identical(_saving, task)) _saving = null;
  }

  Future<void> _readCache() async {
    final path = directory?.path;
    if (path == null) return;
    try {
      _folders.addAll(await _loadOnWorker(path));
    } on FormatException {
      // A stale or incomplete snapshot is rebuilt on demand.
    } on FileSystemException {
      // There is no snapshot on a fresh install.
    } on TypeError {
      // A snapshot from an incompatible schema is also rebuilt.
    } on RangeError {
      // An incomplete record is rebuilt on demand.
    }
  }
}

const _cacheFile = 'file-catalog-v1.json';

Future<Map<String, _Folder>> _loadOnWorker(String path) =>
    Isolate.run(() => _readFolders(path));

Future<void> _saveOnWorker(String path, Map<String, _Folder> folders) =>
    Isolate.run(() => _writeFolders(path, folders));

Map<String, _Folder> _readFolders(String path) {
  final file = File(p.join(path, _cacheFile));
  if (file.lengthSync() > 64 * 1024 * 1024) return {};
  final data = jsonDecode(file.readAsStringSync());
  if (data is! Map<String, dynamic>) return {};
  return data.map((path, value) {
    final row = value as List;
    final entries = <String, StorageEntry>{};
    for (final item in row[1] as List) {
      final name = item[0] as String;
      if (name == '.' ||
          name == '..' ||
          p.basename(name) != name ||
          name.isEmpty) continue;
      final fullPath = p.join(path, name);
      entries[fullPath] = StorageEntry(
        fullPath,
        switch (item[1]) {
          'd' => FileSystemEntityType.directory,
          'l' => FileSystemEntityType.link,
          _ => FileSystemEntityType.file,
        },
        item[2] as int,
        DateTime.fromMicrosecondsSinceEpoch(item[3] as int),
        version: item[4] as int,
        identity: item[5] as String?,
      );
    }
    return MapEntry(path, _Folder(entries, row[0] as int));
  });
}

void _writeFolders(String path, Map<String, _Folder> folders) {
  final content = <String, Object>{};
  var count = 0;
  for (final folder in folders.entries) {
    if (count >= 120000) break;
    count += folder.value.entries.length + 1;
    content[folder.key] = [
      folder.value.stamp,
      [
        for (final entry in folder.value.entries.values)
          [
            p.basename(entry.path),
            entry.isDir ? 'd' : (entry.isFile ? 'f' : 'l'),
            entry.size,
            entry.modified.microsecondsSinceEpoch,
            entry.version,
            entry.identity
          ],
      ]
    ];
  }
  Directory(path).createSync(recursive: true);
  final out = File(p.join(path, _cacheFile));
  final next = File('${out.path}.new');
  next.writeAsStringSync(jsonEncode(content), flush: true);
  next.renameSync(out.path);
}
