import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'file_operations.dart';
import 'main.dart' as app;
import 'storage.dart';
import 'storage_tools.dart';

const _archives = MethodChannel('fm/archive');

class _Entry {
  final int index, bytes;
  final String path;
  final bool directory, encrypted;
  _Entry(Map value)
      : index = value['index'] as int,
        bytes = value['size'] as int,
        path = value['name'] as String,
        directory = value['directory'] as bool,
        encrypted = value['encrypted'] as bool;
}

Future<void> openArchive(BuildContext context, String path) async {
  Directory? staging;
  try {
    staging = await Directory.systemTemp.createTemp('fm-open-archive-');
    var local = path;
    if (isSaf(path)) {
      local = p.join(staging.path, p.basename(path));
      if (!context.mounted) return;
      final job = app.Job();
      await app.runJob(context, 'Đang chuẩn bị tập tin nén', job, () async {
        job.start((await app.storage.stat(path))?.size ?? 0);
        await app.storage.copyFile(path, local, progress: job);
      });
      job.check();
    }
    if (!context.mounted) return;
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) =>
          _ArchivePage(source: path, local: local, staging: staging!),
    ));
  } on TransferCancelled {
    // The staging directory is removed below.
  } catch (error) {
    if (context.mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(storageError(error))),
      );
  } finally {
    if (staging != null) {
      try {
        await staging.delete(recursive: true);
      } on FileSystemException {
        // Startup cleanup retries stale materializations.
      }
    }
  }
}

class _ArchivePage extends StatefulWidget {
  final String source, local;
  final Directory staging;
  const _ArchivePage(
      {required this.source, required this.local, required this.staging});

  @override
  State<_ArchivePage> createState() => _ArchivePageState();
}

class _ArchivePageState extends State<_ArchivePage> {
  final _selected = <int>{};
  List<_Entry> _entries = const [];
  String? _password, _error;
  StorageEntry? _archiveSnapshot;
  bool _busy = false;
  int _level = 0;
  String _folder = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  Future<Object?> _invoke(
    String method,
    app.Job job, {
    Directory? output,
    List<_Entry>? entries,
  }) async {
    final id = storageId();
    final watch = Stopwatch()..start();
    var done = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 160), (_) {
      if (job.cancelled)
        unawaited(_archives.invokeMethod<void>('cancel', {'id': id}));
    });
    _archives.setMethodCallHandler((call) async {
      final values = call.arguments as Map;
      if (call.method == 'progress' && values['id'] == id && !job.cancelled) {
        final processed = values['bytes'] as int;
        job.add(processed - done);
        done = processed;
        final seconds = watch.elapsedMilliseconds / 1000;
        if (seconds > 0) {
          job.describe(
              '${app.fmtSize(done)} · ${app.fmtSize(done / seconds)}/giây');
        }
      }
    });
    try {
      job.check();
      return await _archives.invokeMethod<Object?>(method, {
        'id': id,
        'path': widget.local,
        'password': _password,
        if (output != null) 'destination': output.path,
        if (entries != null)
          'indices': entries.map((entry) => entry.index).toList(),
      });
    } on PlatformException catch (error) {
      if (error.code == 'cancel') throw TransferCancelled();
      rethrow;
    } finally {
      timer.cancel();
      _archives.setMethodCallHandler(null);
    }
  }

  Future<bool> _askPassword() async {
    if (!mounted) return false;
    final result = await showDialog<String>(
      context: context,
      builder: (_) => const _ArchivePassword(),
    );
    if (result == null || !mounted) return false;
    _password = result;
    return true;
  }

  String _errorText(Object error) {
    if (error is PlatformException) {
      final detail = error.message?.trim();
      if (error.code == 'unsupported') {
        return 'Biến thể hoặc phương thức mã hóa này chưa được thư viện hỗ trợ.'
            '${detail == null || detail.isEmpty ? '' : ' $detail'}';
      }
      if (error.code == 'password') return 'Cần mật khẩu hợp lệ.';
      if (detail?.contains('Checksum verification failed') == true) {
        return 'Không xác minh được nội dung giải nén. Kiểm tra tập tin hoặc mật khẩu.';
      }
    }
    return storageError(error);
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      while (mounted) {
        final stamp = await app.storage.stat(widget.local);
        if (!mounted) return;
        try {
          final job = app.Job()..describe(p.basename(widget.source));
          late final List<_Entry> result;
          await app.runJob(context, 'Đang đọc mục lục', job, () async {
            final values = await _invoke('list', job) as List;
            result = values.map((value) => _Entry(value as Map)).toList();
          });
          job.check();
          if (!mounted) return;
          _archiveSnapshot = stamp;
          setState(() {
            _entries = result;
            _selected.clear();
            _folder = '';
            _level = 0;
          });
          return;
        } on PlatformException catch (error) {
          if (error.code != 'password' || !await _askPassword()) rethrow;
        }
      }
    } on TransferCancelled {
      if (mounted) setState(() => _error = 'Đã huỷ đọc tập tin nén.');
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _extract(bool all) async {
    if (_busy || _entries.isEmpty) return;
    final selected = all
        ? _entries
        : _entries.where((entry) => _selected.contains(entry.index)).toList();
    if (selected.isEmpty) return;
    final known = selected
        .where((entry) => !entry.directory && entry.bytes >= 0)
        .fold(0, (sum, entry) => sum + entry.bytes);
    final compressed = _archiveSnapshot?.size ?? 0;
    final unknown =
        selected.any((entry) => !entry.directory && entry.bytes < 0);
    if (unknown || (compressed > 0 && known > 200 * compressed)) {
      if (!await app.confirm(
              context,
              'Kiểm tra dung lượng giải nén',
              unknown
                  ? 'Không xác định được toàn bộ kích thước giải nén.'
                  : 'Dung lượng dự kiến ${app.fmtSize(known)} lớn hơn 200 lần dung lượng tập tin nén.',
              'Tiếp tục') ||
          !mounted) return;
    }
    final parent = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => StorageDestination(
          origin: p.dirname(widget.source),
          action: 'Giải nén vào thư mục cùng tên tại đây'),
    ));
    if (parent == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      while (mounted) {
        if (_password == null &&
            selected.any((entry) => entry.encrypted) &&
            !await _askPassword()) return;
        if (!DuplicateScan.unchanged(
            _archiveSnapshot!, await app.storage.stat(widget.local))) {
          throw FileSystemException(
              'Tập tin nén đã thay đổi. Hãy tải lại mục lục.');
        }
        final attempt = await widget.staging.createTemp('extract-');
        final output = await Directory(p.join(attempt.path, 'output')).create();
        try {
          if (!mounted) return;
          final job = app.Job()..start(known);
          await app.runJob(context, 'Đang giải nén', job, () async {
            await _invoke('extract', job, output: output, entries: selected);
            job.check();
            job.describe('Đang công bố kết quả…');
            final destination = await app.storage
                .unique(parent, app.archiveBase(widget.source));
            job.check();
            // FileOperations verifies the staged directory and makes publication atomic.
            final result = await app.operations.exclusive(() async {
              final item = TransferItem(
                  output.path, destination, false, true, false, storageId());
              job.start(known);
              return app.operations.execute([item], progress: job);
            });
            if (result == 1) {
              app.catalog.markPath(destination);
              if (mounted)
                setState(() => _error =
                    'Đã giải nén vào ${storageDisplayPath(destination)}');
            }
          });
          return;
        } on PlatformException catch (error) {
          if (error.code != 'password') rethrow;
          if (!await _askPassword()) return;
        } finally {
          await attempt.delete(recursive: true);
        }
      }
    } on TransferCancelled {
      if (mounted) setState(() => _error = 'Đã huỷ giải nén.');
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final complete = _entries.where((entry) => !entry.directory);
    final populated = complete.every((entry) => entry.bytes >= 0);
    final bytes = complete
        .where((entry) => entry.bytes >= 0)
        .fold(0, (sum, entry) => sum + entry.bytes);
    final folders = <String, List<_Entry>>{};
    final files = <_Entry>[];
    for (final entry in _entries) {
      if (!entry.path.startsWith(_folder) ||
          entry.path.length <= _folder.length) continue;
      final parts = entry.path.substring(_folder.length).split('/');
      if (parts.length > 1 || entry.directory) {
        (folders[parts.first] ??= []).add(entry);
      } else {
        files.add(entry);
      }
    }
    final folderNames = folders.keys.toList()..sort();
    return Scaffold(
      appBar: AppBar(
        title: Text(p.basename(widget.source), overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
              tooltip: 'Đọc lại mục lục',
              onPressed: _busy ? null : _load,
              icon: const Icon(Icons.refresh)),
          IconButton(
              tooltip: 'Mở bằng ứng dụng khác',
              onPressed:
                  _busy ? null : () => app.openExternal(context, widget.source),
              icon: const Icon(Icons.open_in_new)),
        ],
      ),
      body: Column(children: [
        ListTile(
          dense: true,
          leading: _level == 0
              ? null
              : IconButton(
                  tooltip: 'Thư mục cha',
                  onPressed: () => setState(() {
                    final parent =
                        p.dirname(_folder.substring(0, _folder.length - 1));
                    _folder = parent == '.' ? '' : '$parent/';
                    _level--;
                  }),
                  icon: const Icon(Icons.arrow_upward),
                ),
          title: Text(_folder.isEmpty ? 'Mục lục' : _folder),
          subtitle: Text('${complete.length} tập tin · '
              '${populated ? app.fmtSize(bytes) : 'Kích thước chưa xác định'}'),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(_error!, textAlign: TextAlign.center),
          ),
        Expanded(
            child: ListView.builder(
          itemCount: folderNames.length + files.length,
          itemBuilder: (_, index) {
            if (index < folderNames.length) {
              final name = folderNames[index];
              final children = folders[name]!;
              final checked = children
                  .where((entry) => _selected.contains(entry.index))
                  .length;
              return ListTile(
                leading: const Icon(Icons.folder),
                title: Text(name),
                onTap: () => setState(() {
                  _folder += '$name/';
                  _level++;
                }),
                trailing: Checkbox(
                  tristate: true,
                  value: checked == 0
                      ? false
                      : checked == children.length
                          ? true
                          : null,
                  onChanged: _busy
                      ? null
                      : (_) => setState(() {
                            final ids = children.map((entry) => entry.index);
                            checked == children.length
                                ? _selected.removeAll(ids)
                                : _selected.addAll(ids);
                          }),
                ),
              );
            }
            final entry = files[index - folderNames.length];
            return CheckboxListTile(
              title: Text(p.basename(entry.path)),
              subtitle: Text(
                  '${app.fmtSize(entry.bytes)}${entry.encrypted ? ' · Có mật khẩu' : ''}'),
              value: _selected.contains(entry.index),
              onChanged: _busy
                  ? null
                  : (checked) => setState(() {
                        checked == true
                            ? _selected.add(entry.index)
                            : _selected.remove(entry.index);
                      }),
            );
          },
        )),
        SafeArea(
          top: false,
          child: Wrap(alignment: WrapAlignment.center, spacing: 12, children: [
            TextButton(
                onPressed:
                    _busy || _selected.isEmpty ? null : () => _extract(false),
                child: Text('Giải nén đã chọn (${_selected.length})')),
            FilledButton(
                onPressed:
                    _busy || _entries.isEmpty ? null : () => _extract(true),
                child: const Text('Giải nén toàn bộ')),
          ]),
        ),
      ]),
    );
  }
}

class StorageDestination extends StatefulWidget {
  final String? origin;
  final String action;
  const StorageDestination({super.key, this.origin, required this.action});
  @override
  State<StorageDestination> createState() => _DestinationState();
}

class _DestinationState extends State<StorageDestination> {
  String? _path;
  List<StorageEntry> _dirs = const [];
  String? _error;
  int _request = 0;
  bool _loading = false;

  Future<void> _open(String path) async {
    final token = ++_request;
    setState(() {
      _loading = true;
      _error = null;
      _path = path;
      _dirs = const [];
    });
    try {
      await app.storage.available(path);
      if (excludedFromTools(await app.storage.identity(path))) {
        throw FileSystemException('Thư mục được bảo vệ', path);
      }
      final children = await app.catalog.refresh(path, priority: true);
      if (!mounted || token != _request) return;
      setState(() => _dirs = children
          .where((file) => file.isDir && !excludedFromTools(file.path))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path)));
    } catch (error) {
      if (mounted && token == _request)
        setState(() => _error = storageError(error));
    } finally {
      if (mounted && token == _request) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final roots = <String>{
      if (widget.origin case final location?) location,
      if (app.indexInternal) app.rootPath,
      for (final root in app.volumeRoots) root.path,
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Chọn thư mục đích')),
      body: _path == null
          ? ListView(children: [
              for (final root in roots)
                ListTile(
                    title: Text(storageDisplayPath(root)),
                    subtitle: root == widget.origin
                        ? const Text('Thư mục chứa tập tin nén')
                        : null,
                    leading: const Icon(Icons.folder),
                    onTap: () => _open(root)),
            ])
          : Column(children: [
              ListTile(
                title: Text(storageDisplayPath(_path!)),
                leading: IconButton(
                    tooltip: 'Chọn lại vị trí',
                    onPressed: () => setState(() {
                          _request++;
                          _path = null;
                        }),
                    icon: const Icon(Icons.arrow_upward)),
              ),
              if (_loading) const LinearProgressIndicator(),
              if (_error != null) Text(_error!),
              Expanded(
                  child: ListView.builder(
                itemCount: _dirs.length,
                itemBuilder: (_, index) => ListTile(
                  leading: const Icon(Icons.folder),
                  title: Text(p.basename(_dirs[index].path)),
                  onTap: () => _open(_dirs[index].path),
                ),
              )),
            ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            onPressed: _path == null || _loading || _error != null
                ? null
                : () => Navigator.pop(context, _path),
            child: Text(widget.action),
          ),
        ),
      ),
    );
  }
}

class _ArchivePassword extends StatefulWidget {
  const _ArchivePassword();
  @override
  State<_ArchivePassword> createState() => _ArchivePasswordState();
}

class _ArchivePasswordState extends State<_ArchivePassword> {
  final _value = TextEditingController();
  bool _hidden = true;
  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Mật khẩu tập tin nén'),
        content: TextField(
          controller: _value,
          autofocus: true,
          obscureText: _hidden,
          decoration: InputDecoration(
            labelText: 'Mật khẩu',
            suffixIcon: IconButton(
              onPressed: () => setState(() => _hidden = !_hidden),
              tooltip: _hidden ? 'Hiện mật khẩu' : 'Ẩn mật khẩu',
              icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off),
            ),
          ),
          onSubmitted: (_) => Navigator.pop(context, _value.text),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Huỷ')),
          FilledButton(
              onPressed: () => Navigator.pop(context, _value.text),
              child: const Text('Xác nhận')),
        ],
      );
}
