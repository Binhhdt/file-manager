import 'dart:io';

import 'package:file_manager/file_catalog.dart';
import 'package:file_manager/file_operations.dart';
import 'package:file_manager/main.dart' as app;
import 'package:file_manager/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'storage_saf_test.dart' show DocumentProvider;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late Directory folder;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fm-rename-test-');
    folder = await Directory(p.join(temp.path, 'files')).create();
    SharedPreferences.setMockInitialValues({'grid': false, 'hidden': true});
    app.prefs = await SharedPreferences.getInstance();
    app.catalog = FileCatalog(app.storage, app.rootPath);
    app.thumbnails.setForeground(false);
    app.operations =
        FileOperations(app.storage, Directory(p.join(temp.path, 'journal')));
  });

  tearDown(() async {
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, null);
    app.catalog.setForeground(false);
    await temp.delete(recursive: true);
  });

  String longStem(int length) =>
      'Kỷ niệm 🎬.Tiếng Việt. ${List.filled(24, 'ban.sao.').join()}cuối'
          .substring(0, length - 1) +
      'Z';

  TextEditingController controller(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!;

  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var attempt = 0;
        attempt < 30 && finder.evaluate().isEmpty;
        attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(finder, findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((w) => w.data)
            .join(' | '));
  }

  Future<void> openFolder(WidgetTester tester, String path) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 740);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: app.BrowserPage(mode: app.Mode.dir, path: path),
    ));
  }

  Future<void> openRename(WidgetTester tester, String name,
      {bool selectionMenu = false}) async {
    await waitFor(tester, find.text(name));
    if (selectionMenu) {
      await tester.longPress(find.text(name));
      await tester.pumpAndSettle();
      await tester
          .runAsync(() => tester.tap(find.byType(PopupMenuButton<String>)));
    } else {
      final row = find.widgetWithText(ListTile, name);
      await tester
          .tap(find.descendant(of: row, matching: find.byTooltip('Thao tác')));
    }
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('Đổi tên')));
    await tester.pumpAndSettle();
  }

  Future<void> replaceSelection(WidgetTester tester, String text) async {
    final value = controller(tester).value;
    final selection = value.selection;
    tester.testTextInput.updateEditingValue(TextEditingValue(
      text: value.text.replaceRange(selection.start, selection.end, text),
      selection: TextSelection.collapsed(offset: selection.start + text.length),
    ));
    await tester.pump();
  }

  testWidgets('long Vietnamese name wraps and replacement keeps one extension',
      (tester) async {
    final originalStem = longStem(97);
    final original = '$originalStem.mp4';
    final editedStem = longStem(197);
    // Count the emoji as one character while retaining a real Unicode name.
    expect(original.runes.length, 100);
    expect('$editedStem.mp4'.runes.length, 200);
    File(p.join(folder.path, original)).writeAsStringSync('unchanged contents');

    await openFolder(tester, folder.path);
    await openRename(tester, original, selectionMenu: true);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    final field = controller(tester);
    expect(field.selection.textInside(field.text), originalStem);
    expect(field.selection.textAfter(field.text), '.mp4');
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    expect(
      editable
          .getLocalRectForCaret(TextPosition(offset: originalStem.length))
          .top,
      greaterThan(
          editable.getLocalRectForCaret(const TextPosition(offset: 0)).top),
    );
    await replaceSelection(tester, '$editedStem.MP4');
    expect(field.text, '$editedStem.MP4.mp4');
    await tester.tap(find.text('OK'));
    await tester.pump();
    tester.view.resetViewInsets();
    await waitFor(tester, find.text('Đã đổi tên'));
    expect(File(p.join(folder.path, original)).existsSync(), isFalse);
    expect(File(p.join(folder.path, '$editedStem.mp4')).readAsStringSync(),
        'unchanged contents');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('select all edits the extension and cancel leaves the file alone',
      (tester) async {
    const original = 'Bản.thu tiếng Việt.mp3';
    const edited = 'Bản thu mới 🎵.ogg';
    final file = File(p.join(folder.path, original))..writeAsStringSync('data');
    final result = File(p.join(folder.path, edited));
    await openFolder(tester, folder.path);
    await openRename(tester, original);
    await replaceSelection(tester, 'Tên mới có dấu');
    expect(controller(tester).text, 'Tên mới có dấu.mp3');
    await tester.tap(find.text('Huỷ'));
    await tester.pumpAndSettle();
    expect(file.existsSync(), isTrue);
    expect(folder.listSync(), hasLength(1));

    await openRename(tester, original);
    await tester.tap(find.text('Chọn toàn bộ'));
    final field = controller(tester);
    expect(field.selection.textInside(field.text), original);
    await replaceSelection(tester, edited);
    await tester.tap(find.text('OK'));
    await tester.pump();
    await waitFor(tester, find.text('Đã đổi tên'));
    expect(file.existsSync(), isFalse);
    expect(result.readAsStringSync(), 'data');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'invalid and conflicting names leave the source and target intact',
      (tester) async {
    const original = 'Bản chụp.jpg';
    const occupied = 'Có sẵn.jpg';
    final source = File(p.join(folder.path, original))
      ..writeAsStringSync('source');
    final target = File(p.join(folder.path, occupied))
      ..writeAsStringSync('target');

    await openFolder(tester, folder.path);
    await openRename(tester, original);
    await replaceSelection(tester, '');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Tên không hợp lệ'), findsOneWidget);
    for (final badName in ['../khác.jpg', '..', 'Tên\nkhác.jpg']) {
      await tester.tap(find.text('Chọn toàn bộ'));
      await replaceSelection(tester, badName);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Tên không hợp lệ'), findsOneWidget);
    }

    await tester.tap(find.text('Chọn toàn bộ'));
    await replaceSelection(tester, occupied);
    await tester.tap(find.text('OK'));
    await tester.pump();
    await waitFor(tester, find.textContaining('Tên đã tồn tại'));
    expect(source.readAsStringSync(), 'source');
    expect(target.readAsStringSync(), 'target');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('dotted directories and hidden names are selected in full',
      (tester) async {
    const directory = 'Tài liệu.cũ';
    const hidden = '.ghi chú';
    Directory(p.join(folder.path, directory)).createSync();
    File(p.join(folder.path, hidden)).createSync();
    await openFolder(tester, folder.path);
    for (final name in [directory, hidden]) {
      await openRename(tester, name);
      final field = controller(tester);
      expect(field.selection.textInside(field.text), name);
      await tester.tap(find.text('Huỷ'));
      await tester.pumpAndSettle();
    }
    await tester.pumpWidget(const SizedBox());
  });

  for (final id in ['SD', 'USB']) {
    testWidgets('renames a long name through the $id SAF provider',
        (tester) async {
      final tree = Uri.encodeComponent(
          'content://com.android.externalstorage.documents/tree/$id%3AMedia');
      final path = '$safPrefix$tree';
      final provider = DocumentProvider(path, folder.path);
      binding.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, provider.handle);
      final name = '${longStem(120)}.zip';
      final file = File(p.join(folder.path, name))..writeAsStringSync('bytes');

      await openFolder(tester, path);
      await openRename(tester, name);
      final field = controller(tester);
      expect(field.selection.textAfter(field.text), '.zip');
      await replaceSelection(tester, 'Tệp đã đổi tên.2026');
      await tester.tap(find.text('OK'));
      await tester.pump();
      await waitFor(tester, find.text('Đã đổi tên'));
      expect(file.existsSync(), isFalse);
      expect(
          File(p.join(folder.path, 'Tệp đã đổi tên.2026.zip'))
              .readAsStringSync(),
          'bytes');
      await tester.pumpWidget(const SizedBox());
    });
  }
}
