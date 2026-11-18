import 'dart:io';
import 'dart:typed_data';

import 'package:file_manager/file_operations.dart';
import 'package:file_manager/storage.dart';
import 'package:file_manager/trash.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class Progress implements TransferProgress {
  final void Function()? onBytes;
  bool cancelled = false;

  Progress({this.onBytes});

  @override
  void check() {
    if (cancelled) throw TransferCancelled();
  }

  @override
  void add(int bytes) => onBytes?.call();

  @override
  void describe(String label) {}

  @override
  void finishing() {}
}

class FaultStorage extends Storage {
  final bool full, corrupt;
  bool interruptPublish = false;
  bool blockRecovery = false;
  bool failSourceDetach = false;
  int writes = 0;
  void Function()? afterBackup;

  FaultStorage({this.full = false, this.corrupt = false});

  @override
  Future<StorageStream> open(String path, {bool write = false}) async {
    final stream = await super.open(path, write: write);
    if (write && path.contains(transactionPrefix)) {
      writes++;
      if ((full && writes == 2) || corrupt) {
        return FaultStream(stream, full: full, corrupt: corrupt);
      }
    }
    return stream;
  }

  @override
  Future<void> rename(String from, String to) async {
    if (failSourceDetach &&
        to.endsWith('-source') &&
        p.basename(from) == 'second') {
      throw FileSystemException(
          'Permission denied', from, const OSError('EACCES', 13));
    }
    if (interruptPublish && from.endsWith('-stage')) {
      blockRecovery = true;
      throw FileSystemException('Device disconnected during publication', from);
    }
    if (blockRecovery && from.endsWith('-backup')) {
      throw FileSystemException('Device disconnected during recovery', from);
    }
    await super.rename(from, to);
    if (to.endsWith('-backup')) afterBackup?.call();
  }
}

class FaultStream extends StorageStream {
  final StorageStream delegate;
  final bool full, corrupt;

  FaultStream(this.delegate, {required this.full, required this.corrupt})
      : super.local(null);

  @override
  Future<void> write(Uint8List bytes) async {
    if (full)
      throw FileSystemException('Disk full', null, const OSError('ENOSPC', 28));
    if (corrupt) bytes[0] ^= 1;
    await delegate.write(bytes);
  }

  @override
  Future<void> flush() => delegate.flush();

  @override
  Future<void> close() => delegate.close();
}

void main() {
  late Directory temp;
  late Directory journal;
  late String internal, incoming, outgoing;
  late FileOperations operations;

  Future<File> write(String path, String contents) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    return file.writeAsString(contents);
  }

  Future<void> expectClean() async {
    final files =
        await temp.list(recursive: true).map((entry) => entry.path).toList();
    expect(
        files.where((path) => p.basename(path).startsWith(transactionPrefix)),
        isEmpty);
    if (await journal.exists()) expect(await journal.list().toList(), isEmpty);
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fm-test-');
    incoming = p.join(temp.path, 'incoming');
    outgoing = p.join(temp.path, 'outgoing');
    internal = p.join(temp.path, 'internal');
    await Directory(incoming).create();
    await Directory(outgoing).create();
    await Directory(internal).create();
    journal = Directory(p.join(temp.path, 'journal'));
    operations = FileOperations(Storage(), journal);
  });

  tearDown(() => temp.delete(recursive: true));

  test('copies many levels, a multi-chunk file and empty directories',
      () async {
    final dir = p.join(incoming, 'folder');
    final file = File(p.join(dir, 'deep', 'large.bin'));
    await file.parent.create(recursive: true);
    final bytes =
        Uint8List.fromList(List.generate(streamChunk * 4 + 37, (i) => i % 251));
    await file.writeAsBytes(bytes);
    await Directory(p.join(dir, 'empty')).create();
    final small = await write(p.join(incoming, 'small'), 'second item');

    expect(
        await operations.paste([dir, small.path], outgoing,
            move: false, conflict: Conflict.keep),
        2);
    expect(
        await File(p.join(outgoing, 'folder', 'deep', 'large.bin'))
            .readAsBytes(),
        bytes);
    expect(await File(p.join(outgoing, 'small')).readAsString(), 'second item');
    expect(
        await Directory(p.join(outgoing, 'folder', 'empty')).exists(), isTrue);
    expect(await file.exists(), isTrue);
    await expectClean();
  });

  test('overwriting a directory merges existing contents', () async {
    final src = p.join(incoming, 'folder');
    final dest = p.join(outgoing, 'folder');
    await write(p.join(src, 'nested', 'shared'), 'new');
    await write(p.join(src, 'nested', 'source-only'), 'source');
    await write(p.join(dest, 'nested', 'shared'), 'old');
    await write(p.join(dest, 'nested', 'dest-only'), 'preserved');

    expect(
        await operations
            .paste([src], outgoing, move: false, conflict: Conflict.overwrite),
        1);
    expect(await File(p.join(dest, 'nested', 'shared')).readAsString(), 'new');
    expect(await File(p.join(dest, 'nested', 'dest-only')).readAsString(),
        'preserved');
    expect(await File(p.join(dest, 'nested', 'source-only')).readAsString(),
        'source');
    await expectClean();
  });

  test('keep both and skip preserve the original destination', () async {
    final src = await write(p.join(incoming, 'same.txt'), 'new');
    final dest = await write(p.join(outgoing, 'same.txt'), 'old');
    expect(
        await operations
            .paste([src.path], outgoing, move: false, conflict: Conflict.skip),
        0);
    expect(
        await operations
            .paste([src.path], outgoing, move: false, conflict: Conflict.keep),
        1);
    expect(await dest.readAsString(), 'old');
    expect(await File(p.join(outgoing, 'same (1).txt')).readAsString(), 'new');
    await expectClean();
  });

  test('same-name file and directory conflict preserves both originals',
      () async {
    final src = await write(p.join(incoming, 'same'), 'new');
    final dest = await write(p.join(outgoing, 'same', 'inside'), 'old');
    await expectLater(
      operations.paste([src.path], outgoing,
          move: false, conflict: Conflict.overwrite),
      throwsA(isA<FileSystemException>()),
    );
    expect(await src.readAsString(), 'new');
    expect(await dest.readAsString(), 'old');
    await expectClean();
  });

  test('cancellation while staging a cut preserves source and old target',
      () async {
    final src = await write(p.join(incoming, 'same'), 'new');
    final dest = await write(p.join(outgoing, 'same'), 'old');
    late final Progress progress;
    progress = Progress(onBytes: () => progress.cancelled = true);
    await expectLater(
      operations.paste([src.path], outgoing,
          move: true, conflict: Conflict.overwrite, progress: progress),
      throwsA(isA<TransferCancelled>()),
    );
    expect(await src.readAsString(), 'new');
    expect(await dest.readAsString(), 'old');
    await expectClean();
  });

  test('cancellation after backing up the destination rolls back', () async {
    final src = await write(p.join(incoming, 'same'), 'new');
    final dest = await write(p.join(outgoing, 'same'), 'old');
    final progress = Progress();
    final backend = FaultStorage()
      ..afterBackup = () => progress.cancelled = true;
    operations = FileOperations(backend, journal);
    await expectLater(
      operations.paste([src.path], outgoing,
          move: true, conflict: Conflict.overwrite, progress: progress),
      throwsA(isA<TransferCancelled>()),
    );
    expect(await src.readAsString(), 'new');
    expect(await dest.readAsString(), 'old');
    await expectClean();
  });

  test('out of space on second item leaves the entire batch intact', () async {
    operations = FileOperations(FaultStorage(full: true), journal);
    final first = await write(p.join(incoming, 'first'), 'first');
    final second = await write(p.join(incoming, 'second'), 'second');
    final old = await write(p.join(outgoing, 'first'), 'old');
    await expectLater(
      operations.paste([first.path, second.path], outgoing,
          move: true, conflict: Conflict.overwrite),
      throwsA(isA<FileSystemException>()
          .having((e) => e.osError?.errorCode, 'ENOSPC', 28)),
    );
    expect(await first.readAsString(), 'first');
    expect(await second.readAsString(), 'second');
    expect(await old.readAsString(), 'old');
    expect(await File(p.join(outgoing, 'second')).exists(), isFalse);
    await expectClean();
  });

  test('verification rejects a same-size corrupted copy', () async {
    operations = FileOperations(FaultStorage(corrupt: true), journal);
    final src = await write(p.join(incoming, 'same'), 'new');
    final old = await write(p.join(outgoing, 'same'), 'old');
    await expectLater(
      operations.paste([src.path], outgoing,
          move: true, conflict: Conflict.overwrite),
      throwsA(isA<FileSystemException>().having(
          (error) => error.message, 'verification', contains('không khớp'))),
    );
    expect(await src.readAsString(), 'new');
    expect(await old.readAsString(), 'old');
    await expectClean();
  });

  test(
      'source permission failure after publication rolls back all earlier changes',
      () async {
    operations =
        FileOperations(FaultStorage()..failSourceDetach = true, journal);
    final first = await write(p.join(incoming, 'first'), 'first');
    final second = await write(p.join(incoming, 'second'), 'second');
    final old = await write(p.join(outgoing, 'first'), 'old');
    await expectLater(
      operations.paste([first.path, second.path], outgoing,
          move: true, conflict: Conflict.overwrite),
      throwsA(isA<FileSystemException>()),
    );
    expect(await first.readAsString(), 'first');
    expect(await second.readAsString(), 'second');
    expect(await old.readAsString(), 'old');
    expect(await File(p.join(outgoing, 'second')).exists(), isFalse);
    await expectClean();
  });

  test(
      'restart recovery restores an overwrite whose backup could not be restored while offline',
      () async {
    final src = await write(p.join(incoming, 'same'), 'new');
    final dest = await write(p.join(outgoing, 'same'), 'old');
    operations =
        FileOperations(FaultStorage()..interruptPublish = true, journal);
    await expectLater(
      operations.paste([src.path], outgoing,
          move: true, conflict: Conflict.overwrite),
      throwsA(isA<FileSystemException>()),
    );
    expect(await src.readAsString(), 'new');
    expect(await dest.exists(), isFalse);
    expect(await journal.list().toList(), hasLength(1));

    final restarted = FileOperations(Storage(), journal);
    expect(await restarted.recover(), isEmpty);
    expect(await dest.readAsString(), 'old');
    expect(await src.readAsString(), 'new');
    await expectClean();
  });

  test('move removes the source after publishing the verified target',
      () async {
    final src = await write(p.join(incoming, 'same'), 'new');
    final dest = await write(p.join(outgoing, 'same'), 'old');
    expect(
        await operations.paste([src.path], outgoing,
            move: true, conflict: Conflict.overwrite),
        1);
    expect(await src.exists(), isFalse);
    expect(await dest.readAsString(), 'new');
    await expectClean();
  });

  Trash trashFor(FileOperations fs, Map<String, String> old) => Trash(
        fs,
        Directory(p.join(temp.path, 'index')),
        Directory(p.join(internal, '.FMTrash')),
        internal,
        () => {...old},
        (path) async {
          old.remove(path);
        },
      );

  test('trash survives restart and restores a directory to its exact parent',
      () async {
    final source =
        await write(p.join(internal, 'Mẹ', 'Folder', 'file.txt'), 'old');
    final trash = trashFor(operations, {});
    await trash.put(source.parent.path);
    expect(await source.exists(), isFalse);
    await Directory(p.join(internal, 'Mẹ')).delete();
    final restarted = trashFor(FileOperations(Storage(), journal), {});
    final entry = (await restarted.list()).single;
    await restarted.restore(entry.path);
    expect(await source.readAsString(), 'old');
    expect(await restarted.list(), isEmpty);
    await expectClean();
  });

  test('trash restores collisions as separate files and accepts legacy records',
      () async {
    final source = await write(p.join(internal, 'nested', 'same.txt'), 'trash');
    final legacy =
        await write(p.join(internal, '.FMTrash', 'same.txt'), 'legacy');
    final old = {legacy.path: source.path};
    final trash = trashFor(operations, old);
    await trash.put(source.path);
    await write(source.path, 'active');
    for (final item in await trash.list()) {
      await trash.restore(item.path);
    }
    expect(await source.readAsString(), 'active');
    final copies = await Future.wait([
      File(p.join(source.parent.path, 'same (1).txt')).readAsString(),
      File(p.join(source.parent.path, 'same (2).txt')).readAsString(),
    ]);
    expect(copies, unorderedEquals(['legacy', 'trash']));
    expect(await trash.list(), isEmpty);
    expect(old, isEmpty);
    await expectClean();
  });

  test(
      'trash purge is independent, selected-only, and refuses paths outside trash',
      () async {
    final one = await write(p.join(internal, 'one'), 'one');
    final two = await write(p.join(internal, 'two'), 'two');
    final outside = await write(p.join(internal, 'outside'), 'safe');
    final trash = trashFor(operations, {});
    await trash.put(one.path);
    await expectLater(trash.put(p.join(internal, 'missing')),
        throwsA(isA<FileSystemException>()));
    await trash.put(two.path);
    final items = await trash.list();
    await trash
        .purge(items.firstWhere((item) => p.basename(item.path) == 'one').path);
    await expectLater(
        trash.purge(outside.path), throwsA(isA<FileSystemException>()));
    expect(await outside.readAsString(), 'safe');
    expect(p.basename((await trash.list()).single.path), 'two');
    await expectClean();
  });

  test(
      'trash restores no entry to a guessed location without original metadata',
      () async {
    final legacy = await write(p.join(internal, '.FMTrash', 'orphan'), 'keep');
    final trash = trashFor(operations, {});
    await expectLater(
        trash.restore(legacy.path), throwsA(isA<FileSystemException>()));
    expect(await legacy.readAsString(), 'keep');
    await trash.purge(legacy.path);
    expect(await trash.list(), isEmpty);
  });
}
