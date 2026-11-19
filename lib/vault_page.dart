import 'dart:async';
import 'dart:io';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(app.vault.configured().then((value) {
      if (mounted) setState(() => _configured = value);
    }));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _job?.cancelled = true;
    app.vault.lock();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden)
      _lock();
  }

  void _lock() {
    _job?.cancelled = true;
    app.vault.lock();
    if (mounted)
      setState(() {
        _files = const [];
        _notice = null;
      });
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
    final (files, damaged) = await app.vault.list(job);
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
      for (final path in current) {
        job.check();
        try {
          final size = (await app.storage.stat(path))?.size ?? 0;
          if (size > 0) total += size;
        } on Exception {
          // The import loop reports inaccessible paths individually.
        }
      }
      job.start(total);
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
      if (mounted)
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
        final temporary = File(p.join(area.path, item.name));
        job.start(item.size);
        await app.vault.decryptTo(item, temporary, job);
        job.check();
        final target = await app.storage.unique(destination, item.name);
        job.describe('Đang công bố bản sao…');
        job.start(item.size);
        await app.operations.exclusive(() => app.operations.execute([
              TransferItem(
                  temporary.path, target, false, false, false, storageId()),
            ], progress: job));
        app.catalog.markPath(target);
        if (mounted)
          setState(() => _notice = 'Đã xuất ${storageDisplayPath(target)}');
      } finally {
        await area.delete(recursive: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Thư mục riêng tư'), actions: [
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
                        'Cần mật khẩu để đọc hoặc xuất tập tin. Hãy ghi nhớ mật khẩu.'),
                  ),
                  FilledButton(
                      onPressed: _busy ? null : _unlock,
                      child: Text(
                          _configured! ? 'Mở khóa' : 'Tạo thư mục riêng tư')),
                ] else ...[
                  if (_imports.isNotEmpty)
                    FilledButton(
                        onPressed: _busy ? null : _import,
                        child: Text('Nhập ${_imports.length} bản sao')),
                  Expanded(
                    child: _files.isEmpty
                        ? const Center(child: Text('Chưa có tập tin riêng tư.'))
                        : ListView.builder(
                            itemCount: _files.length,
                            itemBuilder: (_, index) {
                              final item = _files[index];
                              return ListTile(
                                leading: const Icon(Icons.lock_outline),
                                title: Text(item.name),
                                subtitle: Text(app.fmtSize(item.size)),
                                trailing: IconButton(
                                  tooltip: 'Xuất bản sao',
                                  onPressed: _busy ? null : () => _export(item),
                                  icon:
                                      const Icon(Icons.file_download_outlined),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ]),
      );
}

class _VaultPassword extends StatefulWidget {
  final bool create;
  const _VaultPassword({required this.create});
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
        title:
            Text(widget.create ? 'Tạo mật khẩu riêng tư' : 'Mở khóa thư mục'),
        scrollable: true,
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _pass,
            obscureText: _hidden,
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
