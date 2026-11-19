import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'batch_rename.dart';
import 'file_operations.dart';
import 'main.dart' as app;
import 'storage.dart';

const _labels = {
  RenameStyle.prefix: 'Thêm tiền tố',
  RenameStyle.suffix: 'Thêm hậu tố',
  RenameStyle.replace: 'Thay chuỗi',
  RenameStyle.remove: 'Xoá chuỗi',
  RenameStyle.number: 'Thêm số thứ tự',
  RenameStyle.template: 'Đặt tên theo mẫu',
  RenameStyle.upper: 'Chữ hoa',
  RenameStyle.lower: 'Chữ thường',
  RenameStyle.trim: 'Bỏ khoảng trắng thừa',
};

Future<void> undoBatchRename(BuildContext context) async {
  try {
    if (!await app.batchRename.hasUndo()) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Chưa có lần đổi tên hàng loạt để hoàn tác.')),
        );
      return;
    }
    if (!context.mounted ||
        !await app.confirm(
            context,
            'Hoàn tác đổi tên?',
            'Dùng lại các tên ban đầu nếu tất cả tập tin vẫn còn ở đúng vị trí.',
            'Hoàn tác') ||
        !context.mounted) return;
    final job = app.Job(unit: 'bước');
    var total = 0;
    await app.runJob(context, 'Đang hoàn tác đổi tên', job, () async {
      total = await app.batchRename.undo(job, start: job.start);
    });
    if (context.mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Đã hoàn tác $total tập tin.')),
      );
  } on TransferCancelled {
    if (context.mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã huỷ hoàn tác.')),
      );
  } catch (error) {
    if (context.mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(storageError(error))),
      );
  }
}

class BatchRenamePage extends StatefulWidget {
  final List<String> paths;
  const BatchRenamePage({super.key, required this.paths});

  @override
  State<BatchRenamePage> createState() => _BatchRenamePageState();
}

class _BatchRenamePageState extends State<BatchRenamePage> {
  var _style = RenameStyle.prefix;
  final _text = TextEditingController(), _replacement = TextEditingController();
  final _overrides = <String, String>{};
  Map<String, String> _names = const {};
  RenamePlan? _plan;
  bool _editExtension = false, _applying = false;
  Timer? _debounce;
  int _revision = 0;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _revision++;
    _debounce?.cancel();
    _text.dispose();
    _replacement.dispose();
    super.dispose();
  }

  void _refresh() {
    final revision = ++_revision;
    _debounce?.cancel();
    setState(() {
      _plan = null;
      _notice = null;
      _names = {
        for (final (index, path) in widget.paths.indexed)
          path: _overrides[path] ??
              batchName(p.basename(path), _style, _text.text, _replacement.text,
                  index,
                  editExtension: _editExtension),
      };
    });
    _debounce = Timer(const Duration(milliseconds: 220), () async {
      try {
        final plan = await app.batchRename.preview(_names, check: () {
          if (revision != _revision) throw TransferCancelled();
        });
        if (mounted && revision == _revision) setState(() => _plan = plan);
      } on TransferCancelled {
        // A newer edit invalidates this preview.
      } catch (error) {
        if (mounted && revision == _revision)
          setState(() => _notice = storageError(error));
      }
    });
  }

  Future<void> _override(String path) async {
    final original = _names[path]!;
    final result = await app.prompt(context, 'Sửa tên dự kiến',
        _editExtension ? original : p.basenameWithoutExtension(original));
    if (result == null || !mounted) return;
    _overrides[path] = _editExtension ? result : result + p.extension(path);
    _refresh();
  }

  Future<void> _apply() async {
    final plan = _plan;
    if (_applying || plan?.valid != true) return;
    if (!await app.confirm(context, 'Đổi tên ${plan!.paths.length} tập tin?',
            'Kiểm tra bảng xem trước trước khi lưu.', 'Đổi tên') ||
        !mounted) return;
    setState(() {
      _applying = true;
      _notice = null;
    });
    final job = app.Job(unit: 'bước');
    try {
      var changed = 0;
      await app.runJob(context, 'Đang đổi tên hàng loạt', job, () async {
        changed = await app.batchRename.apply(_names, job, start: job.start);
      });
      if (mounted) Navigator.pop(context, changed);
    } on TransferCancelled {
      if (mounted) setState(() => _notice = 'Đã huỷ, tên đã được phục hồi.');
    } catch (error) {
      if (mounted) setState(() => _notice = storageError(error));
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final needsText = const <RenameStyle>{
      RenameStyle.prefix,
      RenameStyle.suffix,
      RenameStyle.remove,
      RenameStyle.replace,
      RenameStyle.template,
    }.contains(_style);
    final errors = _plan?.errors ?? const <String, String>{};
    return Scaffold(
      appBar: AppBar(title: const Text('Đổi tên hàng loạt')),
      body: Column(children: [
        ExpansionTile(
          title: Text(_labels[_style]!),
          initiallyExpanded: true,
          children: [
            DropdownButton<RenameStyle>(
              value: _style,
              items: [
                for (final style in RenameStyle.values)
                  DropdownMenuItem(value: style, child: Text(_labels[style]!))
              ],
              onChanged: _applying
                  ? null
                  : (style) {
                      if (style == null || _style == style) return;
                      _style = style;
                      _text.clear();
                      _replacement.clear();
                      _overrides.clear();
                      _refresh();
                    },
            ),
            if (needsText)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _text,
                  onChanged: (_) => _refresh(),
                  decoration: InputDecoration(
                    labelText:
                        _style == RenameStyle.template ? 'Mẫu tên' : 'Nội dung',
                    hintText: _style == RenameStyle.template
                        ? (_editExtension ? 'Bài hát {n}{ext}' : 'Bài hát {n}')
                        : null,
                  ),
                ),
              ),
            if (_style == RenameStyle.replace)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _replacement,
                  onChanged: (_) => _refresh(),
                  decoration:
                      const InputDecoration(labelText: 'Chuỗi thay thế'),
                ),
              ),
            CheckboxListTile(
              title: const Text('Cho phép sửa đuôi tập tin'),
              value: _editExtension,
              onChanged: _applying
                  ? null
                  : (checked) {
                      _editExtension = checked == true;
                      _overrides.clear();
                      _refresh();
                    },
            ),
          ],
        ),
        if (_notice != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_notice!, textAlign: TextAlign.center),
          ),
        if (_plan == null) const LinearProgressIndicator(),
        Expanded(
            child: ListView.builder(
          itemCount: widget.paths.length,
          itemBuilder: (_, index) {
            final path = widget.paths[index];
            return ListTile(
              title: Text(p.basename(path)),
              subtitle: Text(
                  '→ ${_names[path]}${errors[path] == null ? '' : '\n${errors[path]}'}'),
              trailing: IconButton(
                tooltip: 'Sửa tên dự kiến',
                onPressed: _applying ? null : () => _override(path),
                icon: const Icon(Icons.edit_outlined),
              ),
            );
          },
        )),
        SafeArea(
          top: false,
          child: FilledButton(
            onPressed: _plan?.valid == true && !_applying ? _apply : null,
            child: Text(errors.isNotEmpty
                ? '${errors.length} lỗi tên'
                : 'Đổi tên ${_plan?.paths.length ?? 0} tập tin'),
          ),
        ),
      ]),
    );
  }
}
