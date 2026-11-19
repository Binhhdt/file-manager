import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'file_catalog.dart';
import 'main.dart' as app;
import 'file_operations.dart';
import 'storage.dart';
import 'storage_tools.dart';

class StorageToolsPage extends StatefulWidget {
  final bool duplicates;
  final CatalogRoot? internal;
  final List<CatalogRoot> removable;

  const StorageToolsPage({
    super.key,
    required this.duplicates,
    required this.internal,
    required this.removable,
  });

  @override
  State<StorageToolsPage> createState() => _StorageToolsPageState();
}

enum _Group {
  large('Tập tin lớn', 'Tập tin từ 100 MB.'),
  older('Lâu chưa sửa', 'Tập tin chưa sửa từ 180 ngày.'),
  apk('Gói APK', 'Gói cài đặt trong bộ nhớ chia sẻ.'),
  downloads('Tải xuống cũ', 'Tập tin trong Download chưa sửa từ 90 ngày.'),
  empty('Tập tin trống', 'Tập tin có kích thước 0 byte.'),
  folders('Thư mục trống', 'Thư mục không có nội dung.'),
  temporary('Tập tin tạm', 'Bản nháp thumbnail đã hơn một ngày.'),
  cache('Cache thumbnail', 'Ảnh thu nhỏ có thể tạo lại.'),
  duplicates('Tập tin trùng', 'Các bản được kiểm tra nội dung bằng SHA-256.');

  const _Group(this.label, this.detail);
  final String label, detail;
}

class _StorageToolsPageState extends State<StorageToolsPage> {
  final _selected = <String>{};
  late final _roots = <String>{if (widget.internal case final root?) root.path};
  StorageSurvey? _survey;
  List<DuplicateGroup> _duplicates = const [];
  List<StorageEntry> _cache = const [];
  _Group _group = _Group.large;
  String _folder = '';
  String? _category;
  int _minimum = 0;
  bool _busy = false;
  String? _notice;

  List<CatalogRoot> get _available =>
      [if (widget.internal case final root?) root, ...widget.removable];

  bool _matches(StorageEntry file) {
    final category = app.catOf(file.path)?.name ?? 'Khác';
    return (_folder.isEmpty ||
            app
                .noAccent(storageDisplayPath(p.dirname(file.path)))
                .contains(_folder)) &&
        (_category == null || _category == category) &&
        file.size >= _minimum;
  }

  List<StorageEntry> get _candidates {
    final survey = _survey;
    if (survey == null) return [];
    final now = DateTime.now();
    bool old(StorageEntry file, int days) =>
        file.modified.millisecondsSinceEpoch > 0 &&
        now.difference(file.modified).inDays >= days;
    return switch (_group) {
      _Group.large =>
        survey.entries.where((f) => f.size >= 100 * 1024 * 1024).toList()
          ..sort((a, b) => b.size.compareTo(a.size)),
      _Group.older => survey.entries.where((f) => old(f, 180)).toList()
        ..sort((a, b) => a.modified.compareTo(b.modified)),
      _Group.apk =>
        survey.entries.where((f) => app.extOf(f.path) == 'apk').toList(),
      _Group.downloads => survey.entries
          .where((f) =>
              old(f, 90) &&
              p.split(storageDisplayPath(p.dirname(f.path))).any((part) =>
                  const {'download', 'downloads'}.contains(part.toLowerCase())))
          .toList(),
      _Group.empty => survey.entries.where((f) => f.size == 0).toList(),
      _Group.folders => survey.emptyFolders,
      _Group.temporary => _cache.where((f) => f.path.endsWith('.new')).toList(),
      _Group.cache => _cache.where((f) => !f.path.endsWith('.new')).toList(),
      _Group.duplicates => const [],
    };
  }

  bool get _isDuplicate => widget.duplicates || _group == _Group.duplicates;
  bool get _appCache =>
      !widget.duplicates &&
      (_group == _Group.temporary || _group == _Group.cache);

  Future<void> _scan() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
      _selected.clear();
    });
    final job = app.Job();
    try {
      await app.runJob(context, 'Đang quét bộ nhớ', job, () async {
        final survey = await StorageSurvey.scan(
            app.catalog,
            _available.where((root) => _roots.contains(root.path)).toList(),
            job);
        final duplicates = _isDuplicate
            ? await app.duplicateScan
                .find(survey.entries, job, onTotal: job.start)
            : const <DuplicateGroup>[];
        job.check();
        final cache = widget.duplicates
            ? const <StorageEntry>[]
            : await app.thumbnails.cleanupCandidates();
        if (!mounted) return;
        setState(() {
          _survey = survey;
          _duplicates = duplicates;
          _cache = cache;
          final skipped =
              survey.skipped + (_isDuplicate ? app.duplicateScan.skipped : 0);
          if (skipped > 0)
            _notice = 'Không đọc được hoặc đã thay đổi: $skipped mục.';
        });
      });
    } on TransferCancelled {
      if (mounted) setState(() => _notice = 'Đã huỷ quét.');
    } catch (error) {
      if (mounted) setState(() => _notice = storageError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _suggest() => setState(() {
        _selected.clear();
        for (final group in _duplicates) {
          final files = group.files.where(_matches).toList()
            ..sort((a, b) {
              final age = a.modified.compareTo(b.modified);
              return age == 0 ? a.path.compareTo(b.path) : age;
            });
          _selected.addAll(files.skip(1).map((file) => file.path));
        }
      });

  void _toggle(StorageEntry file, bool checked) {
    if (checked && _isDuplicate) {
      final group =
          _duplicates.firstWhere((group) => group.files.contains(file));
      if (group.files.every((other) =>
          other.path == file.path || _selected.contains(other.path))) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Hãy giữ lại ít nhất một bản trong nhóm.')),
        );
        return;
      }
    }
    setState(
        () => checked ? _selected.add(file.path) : _selected.remove(file.path));
  }

  Future<void> _remove(List<StorageEntry> candidates) async {
    if (_busy) return;
    final files =
        candidates.where((file) => _selected.contains(file.path)).toList();
    final inCache = _appCache;
    if (!await app.confirm(
            context,
            inCache
                ? 'Xoá ${files.length} mục cache?'
                : 'Chuyển ${files.length} mục vào Thùng rác?',
            inCache
                ? 'Các mục được chọn thuộc cache của ứng dụng.'
                : 'Bạn có thể khôi phục từ Thùng rác. Dung lượng chỉ giảm khi xoá hẳn.',
            inCache ? 'Xoá cache' : 'Chuyển vào Thùng rác') ||
        !mounted) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    final job = app.Job(unit: 'mục')..start(files.length);
    final done = <String>{};
    final errors = <String>[];
    var bytes = 0;
    try {
      await app.runJob(context, 'Đang xử lý mục đã chọn', job, () async {
        final checked = <DuplicateGroup>{};
        for (final file in files) {
          if (job.cancelled) break;
          job.describe(storageDisplayPath(file.path));
          try {
            if (inCache) {
              bytes += await app.thumbnails.removeCleanupCandidate(file);
            } else {
              if (_isDuplicate) {
                final group = _duplicates
                    .firstWhere((group) => group.files.contains(file));
                if (!checked.contains(group)) {
                  final keep = group.files
                      .firstWhere((entry) => !_selected.contains(entry.path));
                  await _verify(group, keep, job);
                  checked.add(group);
                }
                await _verify(group, file, job);
              }
              if (!DuplicateScan.unchanged(
                  file, await app.storage.stat(file.path))) {
                throw FileSystemException(
                    'Mục đã thay đổi, hãy quét lại', file.path);
              }
              if (file.isDir &&
                  !(await app.storage.children(file.path).isEmpty)) {
                throw FileSystemException('Thư mục không còn trống', file.path);
              }
              job.check();
              await app.trash.put(file.path);
              app.catalog.markPath(file.path);
              bytes += file.isFile ? file.size : 0;
            }
            done.add(file.path);
          } on TransferCancelled {
            break;
          } catch (error) {
            errors.add(storageError(error));
          }
          job.add(1);
        }
      });
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _selected.clear();
          _survey?.entries.removeWhere((file) => done.contains(file.path));
          _survey?.emptyFolders.removeWhere((file) => done.contains(file.path));
          _duplicates = [
            for (final group in _duplicates)
              if (group.files
                      .where((file) => !done.contains(file.path))
                      .length >
                  1)
                DuplicateGroup(
                    group.hash,
                    group.files
                        .where((file) => !done.contains(file.path))
                        .toList()),
          ];
          _cache = _cache.where((file) => !done.contains(file.path)).toList();
          _notice = '${inCache ? 'Đã giải phóng' : 'Đã chuyển vào Thùng rác'} '
              '${done.length}/${files.length} mục · ${app.fmtSize(bytes)}'
              '${job.cancelled ? ' · Đã huỷ phần còn lại' : ''}';
        });
    }
    if (errors.isNotEmpty && mounted) {
      await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
                title: Text('${errors.length} mục chưa xử lý'),
                content: SingleChildScrollView(child: Text(errors.join('\n'))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Đóng'))
                ],
              ));
    }
  }

  Future<void> _verify(
      DuplicateGroup group, StorageEntry file, app.Job job) async {
    if (await app.duplicateScan.digest(file, _NoByteProgress(job)) !=
        group.hash) {
      throw FileSystemException('Nội dung đã thay đổi', file.path);
    }
  }

  Widget _row(StorageEntry entry) => ListTile(
        key: ValueKey(entry.path),
        leading: app.fileIcon(app.Item(entry)),
        title: Text(p.basename(entry.path)),
        subtitle: Text('${storageDisplayPath(p.dirname(entry.path))}\n'
            '${app.fmtSize(entry.size)} · ${app.fmtDate(entry.modified)}'),
        onTap: _appCache
            ? null
            : () => entry.isDir
                ? Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                        builder: (_) => app.BrowserPage(
                            mode: app.Mode.dir, path: entry.path)))
                : app.openFile(context, entry.path),
        trailing: Checkbox(
          value: _selected.contains(entry.path),
          onChanged: (checked) => _toggle(entry, checked == true),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final files = _isDuplicate
        ? _duplicates.expand((group) => group.files).where(_matches).toList()
        : _candidates.where(_matches).toList();
    final bytes = files
        .where((file) => _selected.contains(file.path) && !file.isDir)
        .fold(0, (sum, file) => sum + file.size);
    final rows = _isDuplicate
        ? <Object>[
            for (final group in _duplicates)
              if (group.files.any(_matches)) ...[
                '${app.catOf(group.files.first.path)?.name ?? 'Khác'} · '
                    '${group.files.length} bản · ${app.fmtSize(group.reclaimable)}',
                ...group.files.where(_matches),
              ]
          ]
        : files;
    return Scaffold(
      appBar: AppBar(
          title: Text(
              widget.duplicates ? 'Tìm file trùng lặp' : 'Dọn dung lượng')),
      body: Column(children: [
        ExpansionTile(
          title: const Text('Vị trí và bộ lọc'),
          children: [
            for (final root in _available)
              CheckboxListTile(
                title: Text(root == widget.internal
                    ? 'Bộ nhớ trong'
                    : storageDisplayPath(root.path)),
                value: _roots.contains(root.path),
                onChanged: _busy
                    ? null
                    : (checked) => setState(() {
                          checked == true
                              ? _roots.add(root.path)
                              : _roots.remove(root.path);
                          _survey = null;
                          _duplicates = const [];
                          _selected.clear();
                        }),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                  decoration: const InputDecoration(labelText: 'Tên thư mục'),
                  onChanged: (value) => setState(() {
                        _folder = app.noAccent(value.trim());
                        _selected.clear();
                      })),
            ),
            Wrap(spacing: 12, children: [
              DropdownButton<String>(
                value: _category ?? '',
                items: [
                  const DropdownMenuItem(
                      value: '', child: Text('Mọi loại tệp')),
                  for (final name in [
                    ...app.cats.map((cat) => cat.name),
                    'Khác'
                  ])
                    DropdownMenuItem(value: name, child: Text(name)),
                ],
                onChanged: (value) => setState(() {
                  _category = value == '' ? null : value;
                  _selected.clear();
                }),
              ),
              DropdownButton<int>(
                value: _minimum,
                items: [
                  for (final size in [
                    0,
                    1024 * 1024,
                    100 * 1024 * 1024,
                    1024 * 1024 * 1024
                  ])
                    DropdownMenuItem(
                        value: size,
                        child: Text(size == 0
                            ? 'Mọi kích thước'
                            : 'Từ ${app.fmtSize(size)}')),
                ],
                onChanged: (value) => setState(() {
                  _minimum = value ?? 0;
                  _selected.clear();
                }),
              ),
            ]),
          ],
        ),
        if (!widget.duplicates) ...[
          DropdownButton<_Group>(
            value: _group,
            items: [
              for (final group in _Group.values)
                DropdownMenuItem(value: group, child: Text(group.label))
            ],
            onChanged: _busy
                ? null
                : (group) => setState(() {
                      _group = group ?? _Group.large;
                      _selected.clear();
                    }),
          ),
          Text(_group.detail, textAlign: TextAlign.center),
        ],
        Wrap(spacing: 10, children: [
          FilledButton(
              onPressed: _busy ? null : _scan, child: const Text('Quét')),
          if (_isDuplicate && files.isNotEmpty)
            TextButton(
                onPressed: _busy ? null : _suggest,
                child: const Text('Đề xuất giữ một bản')),
        ]),
        if (_notice != null) Text(_notice!, textAlign: TextAlign.center),
        if (_survey != null && rows.isEmpty)
          const Text('Không có mục phù hợp.'),
        Expanded(
            child: ListView.builder(
          itemCount: rows.length,
          itemBuilder: (_, index) => switch (rows[index]) {
            StorageEntry entry => _row(entry),
            final String heading => ListTile(title: Text(heading)),
            _ => const SizedBox.shrink(),
          },
        )),
        if (_selected.isNotEmpty)
          SafeArea(
            top: false,
            child: FilledButton(
              onPressed: _busy ? null : () => _remove(files),
              child: Text('${_appCache ? 'Xoá cache' : 'Chuyển vào Thùng rác'} '
                  '· ${_selected.length} · ${app.fmtSize(bytes)}'),
            ),
          ),
      ]),
    );
  }
}

class _NoByteProgress implements TransferProgress {
  final app.Job job;
  const _NoByteProgress(this.job);
  @override
  void add(int bytes) {}
  @override
  void check() => job.check();
  @override
  void describe(String text) => job.describe(text);
  @override
  void finishing() {}
}
