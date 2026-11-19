import 'dart:convert';
import 'dart:io';

import 'package:file_manager/batch_rename.dart';
import 'package:file_manager/file_catalog.dart';
import 'package:file_manager/file_operations.dart';
import 'package:file_manager/media_player.dart';
import 'package:file_manager/music_playlists.dart';
import 'package:file_manager/storage.dart';
import 'package:file_manager/storage_tools.dart';
import 'package:file_manager/vault.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class _Progress implements TransferProgress {
  final int? cancelAfter;
  int processed = 0;
  _Progress([this.cancelAfter]);
  @override
  void add(int amount) => processed += amount;
  @override
  void check() {
    if (cancelAfter != null && processed >= cancelAfter!) {
      throw TransferCancelled();
    }
  }

  @override
  void describe(String text) {}
  @override
  void finishing() {}
}

class _CountingStorage extends Storage {
  int reads = 0;
  @override
  Future<StorageStream> open(String path, {bool write = false}) {
    if (!write) reads++;
    return super.open(path, write: write);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp, data;
  late _CountingStorage storage;
  late BatchRename rename;
  late List<Map<String, String>> rewrites;
  File file(String name) => File(p.join(data.path, name));

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fm-toolkit-test-');
    data = await Directory(p.join(temp.path, 'files')).create();
    storage = _CountingStorage();
    rewrites = [];
    rename = BatchRename(
      FileOperations(storage, Directory(p.join(temp.path, 'operations'))),
      Directory(p.join(temp.path, 'rename')),
      onCommit: (_, paths) async => rewrites.add(paths),
      markPaths: (_) {},
    );
  });

  tearDown(() => temp.delete(recursive: true));

  test('content hash distinguishes same-size files and caches unchanged hashes',
      () async {
    for (final (name, value) in [
      ('A.mp4', 'abcd'),
      ('B.zip', 'abcd'),
      ('C.mp4', 'dcba')
    ]) {
      await file(name).writeAsString(value);
    }
    final scanner =
        DuplicateScan(storage, File(p.join(temp.path, 'hashes.json')));
    Future<List<StorageEntry>> entries() =>
        storage.children(data.path).toList();
    final result = await scanner.find(await entries(), _Progress());
    expect(result.single.files.map((entry) => p.basename(entry.path)),
        unorderedEquals(['A.mp4', 'B.zip']));
    expect(result.single.reclaimable, 4);
    expect(storage.reads, 3);
    await scanner.find(await entries(), _Progress());
    expect(storage.reads, 3);
    await file('C.mp4').writeAsString('abcd');
    final updated = await scanner.find(await entries(), _Progress());
    expect(updated.single.files.length, 3);
    expect(storage.reads, 4);
  });

  test('scan aborts and excludes protected Android folders and app data',
      () async {
    await Directory(p.join(data.path, 'Android', 'data'))
        .create(recursive: true);
    await File(p.join(data.path, 'Android', 'data', 'private.txt'))
        .writeAsString('private');
    await file('Bài hát.mp3').writeAsString('audio');
    await Directory(p.join(data.path, 'empty')).create();
    final catalog = FileCatalog(storage, data.path, watch: false);
    final roots = [CatalogRoot(data.path)];
    final survey = await StorageSurvey.scan(catalog, roots, _Progress());
    expect(
        survey.entries.map((file) => p.basename(file.path)), ['Bài hát.mp3']);
    expect(survey.emptyFolders.map((file) => p.basename(file.path)), ['empty']);
    await expectLater(StorageSurvey.scan(catalog, roots, _Progress(0)),
        throwsA(isA<TransferCancelled>()));
  });

  test('batch rename previews conflicts and handles a cycle with undo',
      () async {
    await file('A.txt').writeAsString('A');
    await file('B.txt').writeAsString('B');
    await file('C.txt').writeAsString('C');
    final conflict = await rename
        .preview({file('A.txt').path: 'C.txt', file('B.txt').path: 'C.txt'});
    expect(conflict.errors.length, 2);
    final changes = {file('A.txt').path: 'B.txt', file('B.txt').path: 'A.txt'};
    expect(await rename.apply(changes, _Progress()), 2);
    expect(await file('A.txt').readAsString(), 'B');
    expect(await file('B.txt').readAsString(), 'A');
    expect(await file('C.txt').readAsString(), 'C');
    expect(rewrites.single, {
      file('A.txt').path: file('B.txt').path,
      file('B.txt').path: file('A.txt').path,
    });
    expect(await rename.undo(_Progress()), 2);
    expect(await file('A.txt').readAsString(), 'A');
    expect(await file('B.txt').readAsString(), 'B');
    expect(await rename.hasUndo(), isFalse);
  });

  test(
      'cancelling during publication restores originals and removes intermediates',
      () async {
    await file('A.txt').writeAsString('A');
    await file('B.txt').writeAsString('B');
    final changes = {file('A.txt').path: 'B.txt', file('B.txt').path: 'A.txt'};
    await expectLater(
        rename.apply(changes, _Progress(3)), throwsA(isA<TransferCancelled>()));
    expect(await file('A.txt').readAsString(), 'A');
    expect(await file('B.txt').readAsString(), 'B');
    expect(await data.list().length, 2);
    expect(rewrites, isEmpty);
  });

  test('batch naming supports Unicode, templates and protected names', () {
    expect(batchName('  Bài   hát .mp3', RenameStyle.trim, '', '', 0),
        'Bài hát.mp3');
    expect(batchName('Đường.mp3', RenameStyle.upper, '', '', 0), 'ĐƯỜNG.mp3');
    expect(batchName('Đường.mp3', RenameStyle.template, 'Bài {n}', '', 2),
        'Bài 003.mp3');
    expect(
        batchName('Đường.mp3', RenameStyle.template, 'Bài {n}.ogg', '', 2,
            editExtension: true),
        'Bài 003.ogg');
    expect(isBatchNameValid('../bad.txt'), isFalse);
    expect(isBatchNameValid('.FMTrash'), isFalse);
  });

  test('vault authenticates passwords, names and streamed contents', () async {
    const pass = 'Mật khẩu tốt 123';
    final root = Directory(p.join(temp.path, 'vault'));
    final vault = VaultStore(root, storage);
    final original = file('Tên riêng tư.txt');
    final contents = List.generate(605000, (index) => index % 251);
    await original.writeAsBytes(contents);
    await vault.unlock(pass, create: true);
    await vault.importFile(original.path, _Progress());
    final configuration = File(p.join(root.path, 'vault.json'));
    expect(await configuration.readAsString(), isNot(contains(pass)));
    final encrypted = await root
        .list()
        .where((entry) => entry.path.endsWith('.fmv'))
        .cast<File>()
        .single;
    expect(await encrypted.readAsString(encoding: latin1),
        isNot(contains('Tên riêng tư')));
    expect(await original.length(), contents.length);
    vault.lock();
    expect(vault.unlocked, isFalse);
    await expectLater(vault.unlock('không phải mật khẩu', create: false),
        throwsA(isA<FileSystemException>()));
    await vault.unlock(pass, create: false);
    final (files, damaged) = await vault.list(_Progress());
    expect(damaged, 0);
    expect(files.single.name, 'Tên riêng tư.txt');
    final restored = file('restored.txt');
    await vault.decryptTo(files.single, restored, _Progress());
    expect(await restored.readAsBytes(), contents);
    final bytes = await encrypted.readAsBytes();
    bytes[bytes.length - 1] ^= 1;
    await encrypted.writeAsBytes(bytes);
    await expectLater(
        vault.decryptTo(files.single, file('tampered'), _Progress()),
        throwsA(isA<FileSystemException>()));
    vault.lock();
  });

  test('playlists persist ordered paths and apply a cyclic rename once',
      () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final playback = MediaPlayback();
    final first = PlaylistStore(preferences, playback);
    final id = await first.create('Nhạc Việt');
    await first.add(id, ['/a.mp3', '/b.mp3', '/a.mp3']);
    await first
        .applyRenames('transaction', {'/a.mp3': '/b.mp3', '/b.mp3': '/a.mp3'});
    first.dispose();
    final second = PlaylistStore(preferences, playback);
    expect(second.find(id)!.songs, ['/b.mp3', '/a.mp3']);
    await second
        .applyRenames('transaction', {'/a.mp3': '/b.mp3', '/b.mp3': '/a.mp3'});
    expect(second.find(id)!.songs, ['/b.mp3', '/a.mp3']);
    second.dispose();
    playback.dispose();
  });
}
