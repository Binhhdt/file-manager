import 'dart:io';

import 'package:file_manager/file_operations.dart';
import 'package:file_manager/storage.dart';
import 'package:file_manager/trash.dart';
import 'package:file_manager/vault.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class DocumentProvider {
  final String root, device;
  final local = Storage();
  final streams = <int, StorageStream>{};
  int nextHandle = 0;
  bool connected = true;
  bool writable = true;

  DocumentProvider(this.root, this.device);

  String pathOf(String path) =>
      path == root ? device : p.join(device, p.relative(path, from: root));

  Map<String, Object> metadata(StorageEntry entry) => {
        'name': p.basename(entry.path),
        'dir': entry.isDir,
        'size': entry.size,
        'modified': entry.modified.millisecondsSinceEpoch,
      };

  Future<Object?> handle(MethodCall call) async {
    final args = (call.arguments as Map?) ?? const {};
    final path = args['path'] as String?;
    final localPath = path == null ? null : pathOf(path);
    final handle = args['handle'] as int?;
    if (call.method != 'streamClose' && !connected) {
      throw PlatformException(code: 'offline');
    }
    switch (call.method) {
      case 'available':
        return null;
      case 'identity':
        return localPath;
      case 'stat':
        final entry = await local.stat(localPath!);
        return entry == null ? null : metadata(entry);
      case 'list':
        return local.children(localPath!).map(metadata).toList();
      case 'mkdir':
        checkWrite();
        await local.createDirectory(localPath!);
        return null;
      case 'rename':
        checkWrite();
        final to = pathOf(args['to'] as String);
        expect(p.dirname(to), p.dirname(localPath!));
        await local.rename(localPath, to);
        return null;
      case 'delete':
        checkWrite();
        await local.remove(localPath!);
        return null;
      case 'streamOpen':
        final write = args['write'] == true;
        if (write) checkWrite();
        final id = nextHandle++;
        streams[id] = await local.open(localPath!, write: write);
        return id;
      case 'streamRead':
        return streams[handle]!.read();
      case 'streamWrite':
        await streams[handle]!.write(args['bytes'] as Uint8List);
        return null;
      case 'streamFlush':
        await streams[handle]!.flush();
        return null;
      case 'streamClose':
        await streams.remove(handle)?.close();
        return null;
      default:
        throw MissingPluginException(call.method);
    }
  }

  void checkWrite() {
    if (!writable) throw PlatformException(code: 'permission');
  }
}

class _VaultProgress implements TransferProgress {
  @override
  void add(int amount) {}
  @override
  void check() {}
  @override
  void describe(String text) {}
  @override
  void finishing() {}
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late DocumentProvider device;
  late FileOperations operations;
  late Directory internal;
  final root =
      '$safPrefix${Uri.encodeComponent('content://com.android.externalstorage.documents/tree/CARD%3AMedia')}';

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fm-saf-test-');
    internal = await Directory(p.join(temp.path, 'internal')).create();
    final mounted = await Directory(p.join(temp.path, 'device')).create();
    device = DocumentProvider(root, mounted.path);
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, device.handle);
    operations =
        FileOperations(Storage(), Directory(p.join(temp.path, 'journal')));
  });

  tearDown(() async {
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, null);
    await temp.delete(recursive: true);
  });

  test(
      'copies directories in both directions and preserves the old SD file on denied write',
      () async {
    final src = File(p.join(internal.path, 'Mưa', 'ảnh.png'));
    await src.parent.create();
    final bytes =
        Uint8List.fromList(List.generate(streamChunk + 19, (i) => i % 241));
    await src.writeAsBytes(bytes);
    expect(
        await operations.paste([src.parent.path], root,
            move: false, conflict: Conflict.keep),
        1);
    final virtualFile = p.join(root, 'Mưa', 'ảnh.png');
    final sd = File(device.pathOf(virtualFile));
    expect(await sd.readAsBytes(), bytes);
    final destination = await Directory(p.join(internal.path, 'back')).create();
    expect(
        await operations.paste([virtualFile], destination.path,
            move: true, conflict: Conflict.keep),
        1);
    expect(await sd.exists(), isFalse);
    expect(
        await File(p.join(destination.path, 'ảnh.png')).readAsBytes(), bytes);
    await sd.writeAsString('previous');
    device.writable = false;
    await expectLater(
      operations.paste([src.path], p.dirname(virtualFile),
          move: true, conflict: Conflict.overwrite),
      throwsA(isA<PlatformException>()
          .having((error) => error.code, 'code', 'permission')),
    );
    expect(await sd.readAsString(), 'previous');
    expect(await src.readAsBytes(), bytes);
    expect(device.streams, isEmpty);
  });

  test(
      'SAF trash retains the original path while offline and restores safely on reconnect',
      () async {
    final path = p.join(root, 'nested', 'data.txt');
    final local = File(device.pathOf(path));
    await local.parent.create();
    await local.writeAsString('original');
    final trash = Trash(
      operations,
      Directory(p.join(temp.path, 'trash-index')),
      Directory(p.join(internal.path, '.FMTrash')),
      internal.path,
      () => {},
      (_) async {},
    );
    await trash.put(path);
    expect(await local.exists(), isFalse);
    final entry = (await trash.list()).single;
    device.connected = false;
    await expectLater(
      trash.restore(entry.path),
      throwsA(isA<PlatformException>()
          .having((error) => error.code, 'code', 'offline')),
    );
    expect((await trash.list()).single.path, entry.path);
    device.connected = true;
    await local.writeAsString('new file');
    await trash.restore(entry.path);
    expect(await local.readAsString(), 'new file');
    expect(await File(p.join(local.parent.path, 'data (1).txt')).readAsString(),
        'original');
    expect(await trash.list(), isEmpty);
    expect(device.streams, isEmpty);
  });

  test(
      'encrypted vault copies an SAF folder and recovers an authenticated backup after reconnect',
      () async {
    final storage = Storage();
    final progress = _VaultProgress();
    const password = 'Mật khẩu kho thử nghiệm';
    final document = p.join(root, 'hồ sơ', 'Tài liệu.txt');
    final original = File(device.pathOf(document));
    await original.parent.create();
    await original.writeAsString('nội dung từ thẻ');
    final vault =
        VaultStore(Directory(p.join(internal.path, 'vault')), storage);
    addTearDown(vault.lock);
    await vault.unlock(password, create: true);
    await vault.importFile(p.dirname(document), progress);
    expect(await original.readAsString(), 'nội dung từ thẻ');
    final backup = await Directory(p.join(internal.path, 'backup')).create();
    await vault.backupTo(backup, progress);
    expect(
        await operations
            .paste([backup.path], root, move: false, conflict: Conflict.keep),
        1);
    final recoveredRoot = Directory(p.join(internal.path, 'recovered'));
    final recovered = VaultStore(recoveredRoot, storage);
    addTearDown(recovered.lock);
    final backupPath = p.join(root, 'backup');
    device.connected = false;
    await expectLater(
        recovered.restoreBackup(backupPath, password, progress),
        throwsA(
            isA<PlatformException>().having((e) => e.code, 'code', 'offline')));
    expect(await recoveredRoot.exists(), isFalse);
    device.connected = true;
    await recovered.restoreBackup(backupPath, password, progress);
    await recovered.unlock(password, create: false);
    final (items, damaged) = await recovered.list(progress);
    expect(damaged, 0);
    final output = p.join(internal.path, 'decoded');
    await recovered.exportTo(items.single, output, progress);
    expect(await File(p.join(output, 'Tài liệu.txt')).readAsString(),
        'nội dung từ thẻ');
    expect(device.streams, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
