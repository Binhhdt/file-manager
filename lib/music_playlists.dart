import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'archive_browser.dart';
import 'file_operations.dart';
import 'main.dart' as app;
import 'media_player.dart';
import 'storage.dart';
import 'storage_tools.dart';

const playlistBackupExtension = '.fmplaylist';
const _backupLimit = 4 * 1024 * 1024;

class SavedPlaylist {
  final String id, name;
  final List<String> songs;
  final String? last;
  SavedPlaylist(this.id, this.name, Iterable<String> songs, [this.last])
      : songs = List.unmodifiable(songs);

  Map<String, Object?> toJson() =>
      {'id': id, 'name': name, 'songs': songs, 'last': last};
}

class PlaylistStore extends ChangeNotifier {
  final SharedPreferences preferences;
  final MediaPlayback playback;
  List<SavedPlaylist> _lists = const [];
  String? _appliedRename, _active;
  Future<void> _pending = Future.value();
  static const _key = 'savedPlaylists.v1';

  PlaylistStore(this.preferences, this.playback) {
    final raw = preferences.getString(_key);
    if (raw != null) {
      final decoded = jsonDecode(raw) as Map;
      _appliedRename = decoded['rename'] as String?;
      _active = decoded['active'] as String?;
      _lists = [
        for (final row in decoded['playlists'] as List)
          SavedPlaylist(row['id'] as String, row['name'] as String,
              (row['songs'] as List).cast<String>(), row['last'] as String?),
      ];
    }
    playback.addListener(_trackChanged);
  }

  List<SavedPlaylist> get lists => List.unmodifiable(_lists);
  SavedPlaylist? find(String id) {
    for (final item in _lists) {
      if (item.id == id) return item;
    }
    return null;
  }

  Future<void> _change(Future<void> Function() change) {
    final task = _pending.then((_) => change());
    _pending = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }

  Future<void> _save(List<SavedPlaylist> items,
      {String? active, String? rename}) async {
    final value = jsonEncode({
      'active': active,
      'rename': rename,
      'playlists': items,
    });
    if (!await preferences.setString(_key, value)) {
      throw const FileSystemException('Không lưu được playlist');
    }
    _lists = items;
    _appliedRename = rename;
    _active = active;
    notifyListeners();
  }

  Future<String> create(String name) async {
    final item = SavedPlaylist(storageId(), name.trim(), const []);
    await _change(() =>
        _save([..._lists, item], active: _active, rename: _appliedRename));
    return item.id;
  }

  Future<void> edit(String id, SavedPlaylist Function(SavedPlaylist) update) =>
      _change(() => _save([
            for (final item in _lists) item.id == id ? update(item) : item,
          ], active: _active, rename: _appliedRename));

  Future<void> add(String id, Iterable<String> songs) => edit(
      id,
      (item) =>
          SavedPlaylist(id, item.name, {...item.songs, ...songs}, item.last));

  Future<void> delete(String id) => _change(() => _save(
        _lists.where((item) => item.id != id).toList(),
        active: _active == id ? null : _active,
        rename: _appliedRename,
      ));

  Future<void> setActive(String id) =>
      _change(() => _save(_lists, active: id, rename: _appliedRename));

  String backup() {
    final data = jsonEncode({
      'format': 'file-manager-playlists',
      'version': 1,
      'playlists': _lists,
    });
    if (utf8.encode(data).length > _backupLimit) {
      throw const FormatException('Bản sao playlist vượt quá 4 MiB');
    }
    return data;
  }

  Future<int> restore(String data) async {
    if (utf8.encode(data).length > _backupLimit) {
      throw const FormatException('Bản sao playlist vượt quá 4 MiB');
    }
    final decoded = jsonDecode(data);
    if (decoded is! Map ||
        decoded['format'] != 'file-manager-playlists' ||
        decoded['version'] != 1 ||
        decoded['playlists'] is! List) {
      throw const FormatException('Bản sao playlist không hợp lệ');
    }
    final imported = <SavedPlaylist>[];
    for (final row in decoded['playlists'] as List) {
      if (row is! Map || row['name'] is! String || row['songs'] is! List) {
        throw const FormatException('Mục playlist không hợp lệ');
      }
      final name = (row['name'] as String).trim();
      final songs = <String>{};
      for (final path in row['songs'] as List) {
        if (path is! String ||
            !p.isAbsolute(path) ||
            p.normalize(path) != path ||
            path.contains('\u0000') ||
            excludedFromTools(path) ||
            p.split(path).contains('fm-vault') ||
            app.catOf(path)?.name != 'Âm thanh') {
          throw const FormatException('Đường dẫn bài hát không hợp lệ');
        }
        if (isSaf(path)) storageDisplayPath(path);
        songs.add(path);
      }
      if (name.isEmpty || name.contains('\u0000')) {
        throw const FormatException('Tên playlist không hợp lệ');
      }
      final last = row['last'];
      imported.add(SavedPlaylist(storageId(), name, songs,
          last is String && songs.contains(last) ? last : null));
    }
    await _change(() => _save([..._lists, ...imported],
        active: _active, rename: _appliedRename));
    return imported.length;
  }

  Future<void> replaceTrack(String id, String oldPath, String newPath) =>
      edit(id, (item) {
        if (!item.songs.contains(oldPath)) return item;
        return SavedPlaylist(
            id,
            item.name,
            {
              for (final song in item.songs)
                if (song != newPath || song == oldPath)
                  song == oldPath ? newPath : song,
            },
            item.last == oldPath ? newPath : item.last);
      });

  Future<void> applyRenames(String transaction, Map<String, String> oldToNew) =>
      _change(() async {
        if (_appliedRename == transaction) return;
        await _save([
          for (final item in _lists)
            SavedPlaylist(
                item.id,
                item.name,
                {
                  for (final song in item.songs) oldToNew[song] ?? song,
                },
                oldToNew[item.last] ?? item.last),
        ], active: _active, rename: transaction);
      });

  void _trackChanged() {
    final id = _active;
    final path = playback.state.path;
    if (id == null || path == null || playback.state.video) return;
    final item = find(id);
    if (item == null || item.last == path || !item.songs.contains(path)) return;
    unawaited(_change(() async {
      final current = find(id);
      if (_active != id ||
          current == null ||
          current.last == path ||
          !current.songs.contains(path)) return;
      await _save([
        for (final list in _lists)
          list.id == id ? SavedPlaylist(id, list.name, list.songs, path) : list,
      ], active: id, rename: _appliedRename);
    }).catchError(
        (Object _) {})); // Playback position is also saved by MediaSession.
  }

  @override
  void dispose() {
    playback.removeListener(_trackChanged);
    super.dispose();
  }
}

Future<void> addToPlaylist(BuildContext context, List<String> paths) async {
  final songs =
      paths.where((path) => app.catOf(path)?.name == 'Âm thanh').toList();
  if (songs.isEmpty) return;
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Thêm vào playlist'),
      children: [
        for (final item in app.playlists.lists)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, item.id),
            child: Text(item.name),
          ),
        SimpleDialogOption(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Tạo playlist mới')),
      ],
    ),
  );
  if (choice == null || !context.mounted) return;
  try {
    var id = choice;
    if (id.isEmpty) {
      final name = await app.prompt(context, 'Tên playlist', '');
      if (name == null || name.isEmpty || !context.mounted) return;
      id = await app.playlists.create(name);
    }
    await app.playlists.add(id, songs);
    if (context.mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã cập nhật playlist.')),
      );
  } catch (error) {
    if (context.mounted)
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(storageError(error))));
  }
}

class PlaylistLibraryPage extends StatelessWidget {
  const PlaylistLibraryPage({super.key});

  Future<void> _backup(BuildContext context, {required bool restore}) async {
    final path = await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (_) => StorageDestination(
            action: restore
                ? 'Chọn bản sao playlist'
                : 'Lưu bản sao playlist tại đây',
            fileFilter: restore
                ? (entry) =>
                    entry.isFile && entry.path.endsWith(playlistBackupExtension)
                : null,
          ),
        ));
    if (path == null || !context.mounted) return;
    if (!await app.confirm(
            context,
            restore ? 'Nhập playlist?' : 'Sao lưu playlist?',
            restore
                ? 'Các playlist trong bản sao sẽ được thêm vào danh sách hiện tại.'
                : 'Bản sao chứa tên playlist và đường dẫn bài hát.',
            restore ? 'Nhập' : 'Sao lưu') ||
        !context.mounted) return;
    final job = app.Job();
    var message = '';
    try {
      await app.runJob(
          context,
          restore ? 'Đang nhập playlist' : 'Đang sao lưu playlist',
          job, () async {
        if (restore) {
          final input = await app.storage.open(path);
          final data = <int>[];
          try {
            for (;;) {
              job.check();
              final chunk = await input.read();
              if (chunk.isEmpty) break;
              if (data.length + chunk.length > _backupLimit) {
                throw const FormatException('Bản sao playlist vượt quá 4 MiB');
              }
              data.addAll(chunk);
            }
          } finally {
            await input.close();
          }
          job.check();
          final count = await app.playlists.restore(utf8.decode(data));
          message = 'Đã nhập $count playlist.';
        } else {
          final staging = await Directory.systemTemp.createTemp('fm-open-');
          try {
            final data = utf8.encode(app.playlists.backup());
            final file =
                File(p.join(staging.path, 'playlists$playlistBackupExtension'));
            await file.writeAsBytes(data, flush: true);
            final target =
                await app.storage.unique(path, p.basename(file.path));
            job.start(data.length);
            await app.operations.exclusive(() => app.operations.execute([
                  TransferItem(
                      file.path, target, false, false, false, storageId()),
                ], progress: job));
            app.catalog.markPath(target);
            message = 'Đã sao lưu vào ${storageDisplayPath(target)}';
          } finally {
            await staging.delete(recursive: true);
          }
        }
      });
    } on TransferCancelled {
      message = 'Đã hủy.';
    } catch (error) {
      message = storageError(error);
    }
    if (context.mounted && message.isNotEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _create(BuildContext context) async {
    final name = await app.prompt(context, 'Tên playlist', '');
    if (name == null || name.isEmpty || !context.mounted) return;
    try {
      await app.playlists.create(name);
    } catch (error) {
      if (context.mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(storageError(error))));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Playlist nhạc'), actions: [
          PopupMenuButton<bool>(
            onSelected: (restore) => _backup(context, restore: restore),
            itemBuilder: (_) => const [
              PopupMenuItem(value: false, child: Text('Sao lưu playlist')),
              PopupMenuItem(value: true, child: Text('Nhập bản sao playlist')),
            ],
          ),
          IconButton(
              tooltip: 'Tạo playlist mới',
              icon: const Icon(Icons.add),
              onPressed: () => _create(context)),
        ]),
        body: ListenableBuilder(
          listenable: app.playlists,
          builder: (context, _) {
            final lists = app.playlists.lists;
            if (lists.isEmpty) {
              return const Center(
                  child: Text(
                      'Tạo playlist hoặc chọn bài hát từ trình quản lý tệp.'));
            }
            return ListView.builder(
              itemCount: lists.length,
              itemBuilder: (_, index) {
                final item = lists[index];
                return ListTile(
                  leading: const Icon(Icons.queue_music),
                  title: Text(item.name),
                  subtitle: Text('${item.songs.length} bài'),
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => _PlaylistPage(id: item.id),
                      )),
                );
              },
            );
          },
        ),
      );
}

class _PlaylistPage extends StatefulWidget {
  final String id;
  const _PlaylistPage({required this.id});
  @override
  State<_PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<_PlaylistPage> {
  final _durations = <String, int>{};
  final _missing = <String>{};
  bool _busy = false;

  Future<void> _locate(SavedPlaylist item, String oldPath) async {
    final path = await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (_) => StorageDestination(
            action: 'Tìm lại bài hát',
            fileFilter: (entry) =>
                entry.isFile && app.catOf(entry.path)?.name == 'Âm thanh',
          ),
        ));
    if (path == null || !mounted) return;
    try {
      if ((await app.storage.stat(path))?.isFile != true) {
        throw const FileSystemException('Không đọc được bài hát đã chọn');
      }
      await app.playlists.replaceTrack(item.id, oldPath, path);
      if (mounted) setState(() => _missing.remove(oldPath));
      if (mounted) unawaited(_metadata());
    } catch (error) {
      _error(error);
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_metadata());
  }

  Future<void> _metadata() async {
    final items = app.playlists.find(widget.id)?.songs ?? const <String>[];
    for (final path in items) {
      if (!mounted) return;
      var duration = 0;
      bool missing = false;
      try {
        final stat = await app.storage.stat(path);
        if (stat?.isFile == true) {
          final request = app.thumbnails.request(stat!, 'audio');
          try {
            duration = (await request.result).duration;
          } finally {
            request.cancel();
          }
        } else {
          missing = true;
        }
      } catch (_) {
        missing = true;
      }
      if (mounted)
        setState(() {
          _durations[path] = duration;
          missing ? _missing.add(path) : _missing.remove(path);
        });
    }
  }

  void _error(Object error) {
    if (mounted)
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(storageError(error))));
  }

  Future<void> _play(SavedPlaylist item,
      {String? start, required bool shuffle}) async {
    if (_busy || item.songs.isEmpty) return;
    setState(() => _busy = true);
    try {
      final playable = <String>[];
      final job = app.Job();
      await app.runJob(context, 'Đang kiểm tra playlist', job, () async {
        for (final path in item.songs) {
          job.check();
          job.describe(storageDisplayPath(path));
          try {
            if ((await app.storage.stat(path))?.isFile == true)
              playable.add(path);
          } on Exception {
            // An offline mount is skipped for this playback only.
          }
        }
      });
      job.check();
      if (!mounted) return;
      if (playable.isEmpty)
        throw const FileSystemException('Không có bài nào đọc được');
      if (playable.length < item.songs.length)
        _error(
            '${item.songs.length - playable.length} bài không truy cập được.');
      final resume = playable.indexOf(start ?? item.last ?? '');
      await app.playlists.setActive(item.id);
      if (mounted)
        await Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => app.PlayerPage(
                paths: playable,
                index: resume < 0 ? 0 : resume,
                video: false,
                shuffle: shuffle,
              ),
            ));
    } on TransferCancelled {
      // No playback changes before confirmation and validation.
    } catch (error) {
      _error(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _menu(String action, SavedPlaylist item) async {
    try {
      if (action == 'rename') {
        final name = await app.prompt(context, 'Đổi tên playlist', item.name);
        if (name != null && name.isNotEmpty) {
          await app.playlists.edit(item.id,
              (old) => SavedPlaylist(old.id, name, old.songs, old.last));
        }
      } else if (action == 'delete' &&
          await app.confirm(context, 'Xoá playlist?',
              'Các bài hát gốc vẫn nằm ở vị trí hiện tại.', 'Xoá playlist')) {
        await app.playlists.delete(item.id);
        if (mounted) Navigator.pop(context);
      }
    } catch (error) {
      _error(error);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app.playlists,
        builder: (context, _) {
          final item = app.playlists.find(widget.id);
          final songs = item?.songs ?? const <String>[];
          final duration =
              songs.fold(0, (sum, path) => sum + (_durations[path] ?? 0));
          final unknown =
              songs.where((path) => (_durations[path] ?? 0) <= 0).length;
          return Scaffold(
            appBar: AppBar(title: Text(item?.name ?? 'Playlist'), actions: [
              if (item != null)
                PopupMenuButton<String>(
                    onSelected: (action) => _menu(action, item),
                    itemBuilder: (_) => const [
                          PopupMenuItem(
                              value: 'rename', child: Text('Đổi tên playlist')),
                          PopupMenuItem(
                              value: 'delete', child: Text('Xoá playlist')),
                        ]),
            ]),
            body: item == null
                ? const SizedBox.shrink()
                : Column(children: [
                    Text('${songs.length} bài · ${app.fmtDur(duration)}'
                        '${unknown == 0 ? '' : ' · $unknown bài chưa rõ thời lượng'}'),
                    Wrap(spacing: 10, children: [
                      FilledButton(
                          onPressed: _busy || songs.isEmpty
                              ? null
                              : () => _play(item, shuffle: false),
                          child: const Text('Phát')),
                      TextButton(
                          onPressed: _busy || songs.isEmpty
                              ? null
                              : () => _play(item, shuffle: true),
                          child: const Text('Phát ngẫu nhiên')),
                    ]),
                    Expanded(
                        child: ReorderableListView.builder(
                      itemCount: songs.length,
                      onReorderItem: (from, to) async {
                        try {
                          await app.playlists.edit(item.id, (old) {
                            final items = old.songs.toList();
                            if (from < items.length && to < items.length) {
                              items.insert(to, items.removeAt(from));
                            }
                            return SavedPlaylist(
                                old.id, old.name, items, old.last);
                          });
                        } catch (error) {
                          _error(error);
                        }
                      },
                      itemBuilder: (context, index) {
                        final path = songs[index];
                        return ListTile(
                          key: ValueKey(path),
                          leading: Icon(path == item.last
                              ? Icons.play_arrow
                              : Icons.music_note),
                          title: Text(p.basename(path)),
                          subtitle: Text(
                              '${storageDisplayPath(p.dirname(path))}'
                              '${_missing.contains(path) ? ' · Không truy cập được' : ''}'),
                          onTap: _busy
                              ? null
                              : _missing.contains(path)
                                  ? () => _locate(item, path)
                                  : () =>
                                      _play(item, start: path, shuffle: false),
                          trailing:
                              Row(mainAxisSize: MainAxisSize.min, children: [
                            if (_missing.contains(path))
                              IconButton(
                                tooltip: 'Tìm lại bài hát',
                                onPressed:
                                    _busy ? null : () => _locate(item, path),
                                icon: const Icon(Icons.search),
                              ),
                            IconButton(
                                tooltip: 'Bỏ khỏi playlist',
                                icon: const Icon(Icons.remove_circle_outline),
                                onPressed: () async {
                                  try {
                                    await app.playlists.edit(
                                        item.id,
                                        (old) => SavedPlaylist(
                                              old.id,
                                              old.name,
                                              old.songs.where(
                                                  (song) => song != path),
                                              old.last == path
                                                  ? null
                                                  : old.last,
                                            ));
                                  } catch (error) {
                                    _error(error);
                                  }
                                }),
                          ]),
                        );
                      },
                    )),
                  ]),
          );
        },
      );
}
