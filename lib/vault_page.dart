import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'archive_browser.dart';
import 'file_operations.dart';
import 'main.dart' as app;
import 'storage.dart';
import 'vault.dart';

class VaultPage extends StatefulWidget {
  final List<String> importFiles;
  const VaultPage({super.key, this.importFiles = const []});

  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> with WidgetsBindingObserver {
  late List<String> _imports = List.of(widget.importFiles);
  List<VaultItem> _files = const [];
  bool? _configured;
  bool _busy = false;
  String? _notice;
  app.Job? _job;
  final _folders = <VaultItem>[];
  VaultItem? _previewItem;
  ui.Image? _previewImage;
  String? _previewText;
  Timer? _idle;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _screenProtection(true);
    unawaited(app.vault.configured().then((value) {
      if (mounted) setState(() => _configured = value);
    }));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _screenProtection(false);
    _job?.cancelled = true;
    _idle?.cancel();
    _previewImage?.dispose();
    app.vault.lock();
    super.dispose();
  }

  void _screenProtection(bool enabled) {
    if (Platform.isAndroid) {
      unawaited(app.nativeCh.invokeMethod<void>(
        'vaultScreen',
        {'src': enabled ? '1' : '0'},
      ).catchError((Object _) {}));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden)
      _lock();
  }

  void _lock() {
    _job?.cancelled = true;
    _idle?.cancel();
    app.vault.lock();
    if (mounted)
      setState(() {
        _files = const [];
        _folders.clear();
        _clearPreview();
        _notice = null;
      });
  }

  void _touch() {
    _idle?.cancel();
    if (app.vault.unlocked && !_busy) {
      _idle = Timer(const Duration(minutes: 3), _lock);
    }
  }

  void _clearPreview() {
    final image = _previewImage;
    _previewImage = null;
    _previewText = null;
    _previewItem = null;
    if (image != null)
      WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
  }

  Future<void> _unlock() async {
    if (_busy) return;
    final create = _configured == false;
    final password = await showDialog<String>(
      context: context,
      builder: (_) => _VaultPassword(create: create),
    );
    if (password == null || !mounted) return;
    await _work(create ? 'Đang tạo thư mục riêng tư' : 'Đang mở khóa',
        (job) async {
      await app.vault.unlock(password, create: create);
      if (job.cancelled) app.vault.lock();
      job.check();
      if (mounted) setState(() => _configured = true);
      await _refresh(job);
    });
    final configured = await app.vault.configured();
    if (mounted) setState(() => _configured = configured);
  }

  Future<void> _refresh(app.Job job) async {
    final (files, damaged) = _folders.isEmpty
        ? await app.vault.list(job)
        : (await app.vault.listFolder(_folders.last, job), 0);
    job.check();
    if (mounted)
      setState(() {
        _files = files;
        if (damaged > 0) _notice = 'Không xác thực được $damaged mục.';
      });
  }

  Future<void> _work(
      String title, Future<void> Function(app.Job) action) async {
    if (_busy || !mounted) return;
    _idle?.cancel();
    setState(() {
      _busy = true;
      _notice = null;
    });
    final job = _job = app.Job();
    try {
      await app.runJob(context, title, job, () => action(job));
    } on TransferCancelled {
      if (mounted) setState(() => _notice = 'Đã huỷ.');
    } catch (error) {
      if (mounted) setState(() => _notice = storageError(error));
    } finally {
      _job = null;
      if (mounted) setState(() => _busy = false);
      if (mounted) _touch();
    }
  }

  Future<void> _import() async {
    if (_imports.isEmpty || !app.vault.unlocked) return;
    final current = List.of(_imports);
    if (!await app.confirm(
            context,
            'Nhập ${current.length} bản sao?',
            'Ứng dụng tạo bản sao được mã hóa. Tệp gốc vẫn nằm ở vị trí hiện tại.',
            'Nhập bản sao') ||
        !mounted) return;
    await _work('Đang mã hóa', (job) async {
      var total = 0;
      var folder = false;
      for (final path in current) {
        job.check();
        try {
          final stat = await app.storage.stat(path);
          folder |= stat?.isDir == true;
          final size = stat?.size ?? 0;
          if (size > 0) total += size;
        } on Exception {
          // The import loop reports inaccessible paths individually.
        }
      }
      job.start(folder ? 0 : total);
      final successes = <String>{};
      final errors = <String>[];
      for (final path in current) {
        if (job.cancelled) break;
        job.describe(p.basename(path));
        try {
          await app.vault.importFile(path, job);
          successes.add(path);
        } on TransferCancelled {
          break;
        } catch (error) {
          errors.add('${p.basename(path)} · ${storageError(error)}');
        }
      }
      if (!mounted) return;
      setState(() => _imports.removeWhere(successes.contains));
      if (app.vault.unlocked && !job.cancelled) await _refresh(job);
      if (mounted && app.vault.unlocked)
        setState(() =>
            _notice = 'Đã nhập ${successes.length}/${current.length} bản sao.'
                '${job.cancelled ? ' Đã huỷ phần còn lại.' : ''}'
                '${errors.isEmpty ? '' : '\n${errors.join('\n')}'}');
    });
  }

  Future<void> _export(VaultItem item) async {
    final destination = await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              const StorageDestination(action: 'Xuất bản sao vào đây'),
        ));
    if (destination == null || !mounted || !app.vault.unlocked) return;
    if (!await app.confirm(context, 'Xuất bản sao?',
            'Tệp xuất ra sẽ đọc được từ thư mục đích.', 'Xuất') ||
        !mounted) return;
    await _work('Đang xuất bản sao', (job) async {
      final area = await Directory.systemTemp.createTemp('fm-vault-export-');
      try {
        final temporary = p.join(area.path, 'payload');
        job.start(item.size);
        await app.vault.exportTo(item, temporary, job);
        job.check();
        final target = await app.storage.unique(destination, item.name);
        job.describe('Đang công bố bản sao…');
        job.start(item.size);
        await app.operations.exclusive(() => app.operations.execute([
              TransferItem(temporary, target, false, false, false, storageId()),
            ], progress: job));
        app.catalog.markPath(target);
        if (mounted)
          setState(() => _notice = 'Đã xuất ${storageDisplayPath(target)}');
      } finally {
        await area.delete(recursive: true);
      }
    });
  }

  Future<void> _folder(VaultItem? item) async {
    await _work('Đang đọc thư mục', (job) async {
      final next = [..._folders];
      if (item == null) {
        next.removeLast();
      } else {
        next.add(item);
      }
      final (files, damaged) = next.isEmpty
          ? await app.vault.list(job)
          : (await app.vault.listFolder(next.last, job), 0);
      job.check();
      if (mounted && app.vault.unlocked)
        setState(() {
          _folders
            ..clear()
            ..addAll(next);
          _files = files;
          if (damaged > 0) _notice = 'Không xác thực được $damaged mục.';
        });
    });
  }

  Future<void> _preview(VaultItem item) async {
    final extension = p.extension(item.name).toLowerCase();
    const images = {'.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp'};
    const text = {'.txt', '.csv', '.md', '.log', '.json', '.xml'};
    if (!images.contains(extension) && !text.contains(extension)) {
      setState(() => _notice =
          'Tập tin này có thể xuất bản sao để mở bằng ứng dụng phù hợp.');
      return;
    }
    await _work('Đang xác thực bản xem trước', (job) async {
      final bytes = await app.vault.preview(item, job,
          limit: images.contains(extension) ? 8 * 1024 * 1024 : 256 * 1024);
      ui.Image? image;
      String? value;
      try {
        if (images.contains(extension)) {
          final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
          ui.ImageDescriptor? descriptor;
          try {
            descriptor = await ui.ImageDescriptor.encoded(buffer);
            final scale = (2048 /
                    (descriptor.width > descriptor.height
                        ? descriptor.width
                        : descriptor.height))
                .clamp(0.0, 1.0);
            final codec = await descriptor.instantiateCodec(
              targetWidth: (descriptor.width * scale).round().clamp(1, 2048),
              targetHeight: (descriptor.height * scale).round().clamp(1, 2048),
            );
            try {
              image = (await codec.getNextFrame()).image;
            } finally {
              codec.dispose();
            }
          } finally {
            descriptor?.dispose();
            buffer.dispose();
          }
        } else {
          value = utf8.decode(bytes, allowMalformed: true);
        }
        job.check();
        if (mounted && app.vault.unlocked)
          setState(() {
            _clearPreview();
            _previewItem = item;
            _previewImage = image;
            _previewText = value;
            image = null;
          });
      } finally {
        bytes.fillRange(0, bytes.length, 0);
        image?.dispose();
      }
    });
  }

  Future<void> _changePassword() async {
    final old = await showDialog<String>(
        context: context,
        builder: (_) => const _VaultPassword(
            create: false, title: 'Nhập mật khẩu hiện tại'));
    if (old == null || !mounted || !app.vault.unlocked) return;
    final next = await showDialog<String>(
        context: context,
        builder: (_) =>
            const _VaultPassword(create: true, title: 'Nhập mật khẩu mới'));
    if (next == null || !mounted || !app.vault.unlocked) return;
    await _work('Đang đổi mật khẩu', (job) async {
      await app.vault.changePassword(old, next, job);
      if (mounted && app.vault.unlocked)
        setState(() => _notice =
            'Đã đổi mật khẩu. Bản sao kho đã tạo trước đây dùng mật khẩu tại thời điểm sao lưu.');
    });
  }

  Future<void> _backup(bool restore) async {
    final path = await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (_) => StorageDestination(
              action: restore
                  ? 'Phục hồi từ thư mục này'
                  : 'Sao lưu bản mã tại đây'),
        ));
    if (path == null || !mounted) return;
    if (restore) {
      final password = await showDialog<String>(
          context: context,
          builder: (_) => const _VaultPassword(
              create: false, title: 'Mật khẩu tại thời điểm sao lưu'));
      if (password == null || !mounted) return;
      await _work('Đang xác minh và phục hồi bản mã', (job) async {
        await app.vault.restoreBackup(path, password, job);
        if (mounted)
          setState(() {
            _configured = true;
            _notice = 'Đã phục hồi. Hãy mở khóa bằng mật khẩu của bản sao.';
          });
      });
    } else if (app.vault.unlocked) {
      await _work('Đang sao lưu bản mã', (job) async {
        final stage = await Directory.systemTemp.createTemp('fm-vault-export-');
        try {
          await app.vault.backupTo(stage, job);
          final target = await app.storage.unique(path, 'Kho-rieng-tu-ma-hoa');
          job.check();
          await app.operations.exclusive(() => app.operations.execute([
                TransferItem(
                    stage.path, target, false, false, false, storageId()),
              ], progress: job));
          if (mounted && app.vault.unlocked)
            setState(() => _notice =
                'Đã sao lưu kho đã mã hóa vào ${storageDisplayPath(target)}');
        } finally {
          await stage.delete(recursive: true);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
      onPointerDown: (_) => _touch(),
      child: Scaffold(
        appBar: AppBar(
            title: Text(_previewItem?.name ??
                (_folders.isEmpty ? 'Thư mục riêng tư' : _folders.last.name)),
            actions: [
              if (_previewItem != null || _folders.isNotEmpty)
                IconButton(
                    tooltip: _previewItem != null
                        ? 'Đóng bản xem trước'
                        : 'Lên thư mục cha',
                    onPressed: _busy
                        ? null
                        : () {
                            if (_previewItem != null) {
                              setState(_clearPreview);
                            } else {
                              _folder(null);
                            }
                          },
                    icon: const Icon(Icons.arrow_upward)),
              if (app.vault.unlocked)
                PopupMenuButton<String>(
                    enabled: !_busy,
                    onSelected: (action) => action == 'password'
                        ? _changePassword()
                        : _backup(false),
                    itemBuilder: (_) => const [
                          PopupMenuItem(
                              value: 'password', child: Text('Đổi mật khẩu')),
                          PopupMenuItem(
                              value: 'backup',
                              child: Text('Sao lưu kho đã mã hóa')),
                        ]),
              if (app.vault.unlocked)
                IconButton(
                    onPressed: _busy ? null : _lock,
                    tooltip: 'Khóa',
                    icon: const Icon(Icons.lock)),
            ]),
        body: _configured == null
            ? const Center(child: CircularProgressIndicator())
            : Column(children: [
                if (_notice != null)
                  Flexible(
                      child: ListView(
                    shrinkWrap: true,
                    children: [
                      Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(_notice!))
                    ],
                  )),
                if (!app.vault.unlocked) ...[
                  const ListTile(
                    leading: Icon(Icons.lock_outline),
                    title: Text('Bản sao riêng tư được mã hóa trên thiết bị'),
                    subtitle: Text(
                        'Nếu mất mật khẩu, bạn có thể mất quyền truy cập dữ liệu, kể cả bản sao đã mã hóa.'),
                  ),
                  FilledButton(
                      onPressed: _busy ? null : _unlock,
                      child: Text(
                          _configured! ? 'Mở khóa' : 'Tạo thư mục riêng tư')),
                  if (_configured == false)
                    TextButton(
                        onPressed: _busy ? null : () => _backup(true),
                        child: const Text('Phục hồi kho đã mã hóa')),
                ] else ...[
                  if (_imports.isNotEmpty &&
                      _previewItem == null &&
                      _folders.isEmpty)
                    FilledButton(
                        onPressed: _busy ? null : _import,
                        child: Text('Nhập ${_imports.length} bản sao')),
                  Expanded(
                    child: _previewItem != null
                        ? (_previewImage != null
                            ? Center(
                                child: InteractiveViewer(
                                    child: RawImage(
                                        image: _previewImage,
                                        fit: BoxFit.contain)))
                            : SingleChildScrollView(
                                padding: const EdgeInsets.all(16),
                                child: Text(_previewText ?? '')))
                        : _files.isEmpty
                            ? const Center(
                                child: Text('Chưa có tập tin riêng tư.'))
                            : ListView.builder(
                                itemCount: _files.length,
                                itemBuilder: (_, index) {
                                  final item = _files[index];
                                  return ListTile(
                                    leading: Icon(item.isDir
                                        ? Icons.folder
                                        : Icons.lock_outline),
                                    title: Text(item.name),
                                    subtitle: Text(item.isDir
                                        ? '${item.children} mục · ${app.fmtSize(item.size)}'
                                        : app.fmtSize(item.size)),
                                    onTap: _busy
                                        ? null
                                        : () => item.isDir
                                            ? _folder(item)
                                            : _preview(item),
                                    trailing: IconButton(
                                      tooltip: 'Xuất bản sao',
                                      onPressed:
                                          _busy ? null : () => _export(item),
                                      icon: const Icon(
                                          Icons.file_download_outlined),
                                    ),
                                  );
                                },
                              ),
                  ),
                ],
              ]),
      ));
}

class _VaultPassword extends StatefulWidget {
  final bool create;
  final String? title;
  const _VaultPassword({required this.create, this.title});
  @override
  State<_VaultPassword> createState() => _VaultPasswordState();
}

class _VaultPasswordState extends State<_VaultPassword> {
  final _pass = TextEditingController(), _confirm = TextEditingController();
  bool _hidden = true;
  String? _error;

  @override
  void dispose() {
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    if (_pass.text.isEmpty ||
        (widget.create &&
            (_pass.text.length < 8 || _pass.text != _confirm.text))) {
      setState(() => _error = widget.create
          ? 'Nhập cùng một mật khẩu có ít nhất 8 ký tự.'
          : 'Nhập mật khẩu.');
      return;
    }
    Navigator.pop(context, _pass.text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title ??
            (widget.create ? 'Tạo mật khẩu riêng tư' : 'Mở khóa thư mục')),
        scrollable: true,
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _pass,
            obscureText: _hidden,
            enableSuggestions: false,
            autocorrect: false,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Mật khẩu',
              errorText: _error,
              suffixIcon: IconButton(
                tooltip: _hidden ? 'Hiện mật khẩu' : 'Ẩn mật khẩu',
                onPressed: () => setState(() => _hidden = !_hidden),
                icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off),
              ),
            ),
            onSubmitted: (_) {
              if (!widget.create) _submit();
            },
          ),
          if (widget.create)
            TextField(
              controller: _confirm,
              obscureText: _hidden,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Xác nhận mật khẩu'),
              onSubmitted: (_) => _submit(),
            ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Huỷ')),
          FilledButton(
              onPressed: _submit,
              child: Text(widget.create ? 'Tạo' : 'Mở khóa')),
        ],
      );
}
