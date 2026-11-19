import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import 'main.dart' as app;
import 'file_operations.dart';
import 'storage.dart';

Future<void> openPdfReader(BuildContext context, String path) async {
  Directory? staging;
  try {
    var local = path;
    if (isSaf(path)) {
      staging = await Directory.systemTemp.createTemp('fm-open-');
      local = p.join(staging.path, p.basename(path));
      if (!context.mounted) return;
      final job = app.Job();
      await app.runJob(context, 'Đang chuẩn bị PDF', job, () async {
        job.start((await app.storage.stat(path))?.size ?? 0);
        await app.storage.copyFile(path, local, progress: job);
      });
      job.check();
    }
    if (!context.mounted) return;
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => PdfReaderPage(source: path, local: local),
    ));
  } on TransferCancelled {
    // The temporary file is removed below.
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
        // The app already retries stale materializations on startup.
      }
    }
  }
}

class PdfReaderPage extends StatefulWidget {
  final String source, local;
  const PdfReaderPage({super.key, required this.source, required this.local});

  @override
  State<PdfReaderPage> createState() => _PdfReaderPageState();
}

class _PdfReaderPageState extends State<PdfReaderPage> {
  final _controller = PdfViewerController();
  late final _search = PdfTextSearcher(_controller);
  late final _key = 'pdf.${sha256.convert(utf8.encode(widget.source))}';
  late final _initial = app.prefs.getInt('$_key.page') ?? 1;
  late final _document = PdfDocumentRefByLoader((_) async {
    Pdfrx.cacheDirectoryPath ??= Directory.systemTemp.path;
    await pdfrxFlutterInitialize().timeout(
      const Duration(seconds: 25),
      onTimeout: () =>
          throw const FileSystemException('Trình đọc PDF không khởi động được'),
    );
    return PdfDocument.openFile(
      widget.local,
      passwordProvider: _password,
      useProgressiveLoading: true,
    );
  }, key: PdfDocumentRefKey(widget.local));
  late final _bookmarks = (app.prefs.getStringList('$_key.bookmarks') ?? [])
      .map(int.tryParse)
      .whereType<int>()
      .toSet();
  late bool _dark = app.prefs.getBool('pdf.dark') ?? false;
  bool _find = false, _passwordPrompt = false;
  int _page = 0, _pages = 0;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _changed(int? page) {
    if (!mounted || page == null || page < 1 || _page == page) return;
    setState(() => _page = page);
    unawaited(app.prefs.setInt('$_key.page', page));
  }

  Future<String?> _password() async {
    if (!mounted || _passwordPrompt) return null;
    _passwordPrompt = true;
    try {
      return await showDialog<String>(
        context: context,
        builder: (_) => const _PdfPasswordDialog(),
      );
    } finally {
      _passwordPrompt = false;
    }
  }

  Future<void> _jump() async {
    if (!_controller.isReady) return;
    final result = await app.prompt(context, 'Chuyển đến trang', '$_page');
    if (!mounted || result == null) return;
    final page = int.tryParse(result);
    if (page != null && page >= 1 && page <= _pages && _controller.isReady) {
      await _controller.goToPage(pageNumber: page);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Nhập số trang từ 1 đến $_pages.')),
      );
    }
  }

  void _bookmark() {
    setState(() {
      if (!_bookmarks.remove(_page)) _bookmarks.add(_page);
    });
    final sorted = _bookmarks.toList()..sort();
    unawaited(app.prefs.setStringList(
        '$_key.bookmarks', sorted.map((number) => '$number').toList()));
  }

  Future<void> _bookmarkedPages() async {
    final pages = (_bookmarks
        .where((page) => page >= 1 && page <= _pages)
        .toList())
      ..sort();
    final page = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Trang đã đánh dấu'),
        content: pages.isEmpty
            ? const Text('Chưa có trang được đánh dấu.')
            : SizedBox(
                width: 300,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: pages.length,
                  itemBuilder: (_, index) => ListTile(
                    title: Text('Trang ${pages[index]}'),
                    onTap: () => Navigator.pop(context, pages[index]),
                  ),
                )),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Đóng'))
        ],
      ),
    );
    if (mounted && page != null && _controller.isReady) {
      await _controller.goToPage(pageNumber: page);
    }
  }

  void _menu(String action) {
    switch (action) {
      case 'theme':
        setState(() => _dark = !_dark);
        unawaited(app.prefs.setBool('pdf.dark', _dark));
      case 'bookmarks':
        unawaited(_bookmarkedPages());
      case 'share':
        unawaited(app.shareFiles(context, [widget.source]));
      case 'external':
        unawaited(app.openExternal(context, widget.source));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _dark
          ? ThemeData.dark(useMaterial3: true)
          : ThemeData.light(useMaterial3: true),
      child: Scaffold(
        appBar: AppBar(
          title: Text(p.basename(widget.source),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: 'Tìm trong PDF',
              onPressed: _pages == 0
                  ? null
                  : () {
                      if (_find) _search.resetTextSearch();
                      setState(() => _find = !_find);
                    },
              icon: Icon(_find ? Icons.close : Icons.search),
            ),
            IconButton(
              tooltip: 'Đánh dấu trang',
              onPressed: _page > 0 ? _bookmark : null,
              icon: Icon(_bookmarks.contains(_page)
                  ? Icons.bookmark
                  : Icons.bookmark_border),
            ),
            PopupMenuButton<String>(
                onSelected: _menu,
                itemBuilder: (_) => [
                      PopupMenuItem(
                          value: 'theme',
                          child:
                              Text(_dark ? 'Giao diện sáng' : 'Giao diện tối')),
                      const PopupMenuItem(
                          value: 'bookmarks', child: Text('Trang đã đánh dấu')),
                      const PopupMenuItem(
                          value: 'share', child: Text('Chia sẻ')),
                      const PopupMenuItem(
                          value: 'external',
                          child: Text('Mở bằng ứng dụng khác')),
                    ]),
          ],
        ),
        body: Column(children: [
          if (_find)
            Row(children: [
              Expanded(
                  child: Padding(
                padding: const EdgeInsets.only(left: 12),
                child: TextField(
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                      labelText: 'Từ khóa trong tài liệu'),
                  onChanged: (value) => value.trim().isEmpty
                      ? _search.resetTextSearch()
                      : _search.startTextSearch(value),
                ),
              )),
              AnimatedBuilder(
                animation: _search,
                builder: (_, __) => Text(_search.isSearching
                    ? '${_search.matches.length}…'
                    : '${_search.matches.length} kết quả'),
              ),
              IconButton(
                  tooltip: 'Kết quả trước',
                  onPressed: _search.goToPrevMatch,
                  icon: const Icon(Icons.keyboard_arrow_up)),
              IconButton(
                  tooltip: 'Kết quả sau',
                  onPressed: _search.goToNextMatch,
                  icon: const Icon(Icons.keyboard_arrow_down)),
            ]),
          Expanded(
              child: PdfViewer(
            _document,
            controller: _controller,
            initialPageNumber: _initial,
            params: PdfViewerParams(
              backgroundColor:
                  _dark ? const Color(0xff232323) : const Color(0xffdddfe1),
              maxImageBytesCachedOnMemory: 48 * 1024 * 1024,
              verticalCacheExtent: 0.7,
              horizontalCacheExtent: 0.3,
              calculateInitialPageNumber: (document, _) => _initial.clamp(
                  1, document.pages.isEmpty ? 1 : document.pages.length),
              onViewerReady: (document, controller) {
                if (!mounted || document.pages.isEmpty) return;
                final initial = controller.pageNumber ??
                    _initial.clamp(1, document.pages.length);
                setState(() {
                  _pages = document.pages.length;
                  _page = initial;
                });
                unawaited(app.prefs.setInt('$_key.page', initial));
              },
              onPageChanged: _changed,
              pagePaintCallbacks: [_search.pageTextMatchPaintCallback],
              onGeneralTap: (_, __, details) {
                if (details.type != PdfViewerGeneralTapType.doubleTap)
                  return false;
                unawaited(_controller.zoomUpOnLocalPosition(
                    loop: true, localPosition: details.localPosition));
                return true;
              },
              loadingBannerBuilder: (_, __, ___) => const Center(
                child: CircularProgressIndicator(semanticsLabel: 'Đang mở PDF'),
              ),
              errorBannerBuilder: (_, error, __, ___) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Không mở được PDF. ${storageError(error)}',
                      textAlign: TextAlign.center),
                ),
              ),
            ),
          )),
          if (_pages > 0)
            SafeArea(
              top: false,
              child:
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                IconButton(
                    tooltip: 'Trang trước',
                    icon: const Icon(Icons.chevron_left),
                    onPressed: _page <= 1
                        ? null
                        : () => _controller.goToPage(pageNumber: _page - 1)),
                TextButton(onPressed: _jump, child: Text('$_page / $_pages')),
                IconButton(
                    tooltip: 'Trang sau',
                    icon: const Icon(Icons.chevron_right),
                    onPressed: _page >= _pages
                        ? null
                        : () => _controller.goToPage(pageNumber: _page + 1)),
              ]),
            ),
        ]),
      ),
    );
  }
}

class _PdfPasswordDialog extends StatefulWidget {
  const _PdfPasswordDialog();
  @override
  State<_PdfPasswordDialog> createState() => _PdfPasswordDialogState();
}

class _PdfPasswordDialogState extends State<_PdfPasswordDialog> {
  final _password = TextEditingController();
  bool _hidden = true;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Mật khẩu PDF'),
        content: TextField(
          autofocus: true,
          controller: _password,
          obscureText: _hidden,
          decoration: InputDecoration(
            labelText: 'Mật khẩu',
            suffixIcon: IconButton(
              onPressed: () => setState(() => _hidden = !_hidden),
              tooltip: _hidden ? 'Hiện mật khẩu' : 'Ẩn mật khẩu',
              icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off),
            ),
          ),
          onSubmitted: (_) => Navigator.pop(context, _password.text),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Huỷ')),
          FilledButton(
              onPressed: () => Navigator.pop(context, _password.text),
              child: const Text('Mở')),
        ],
      );
}
