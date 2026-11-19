import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import 'file_operations.dart';
import 'storage.dart';

const _metadataSize = 4096;
const _tagSize = 16;
const _version = 'FMV1';
const _chunk = 64 * 1024;
const _backupTag = 'vault-backup.tag';
const _maxDepth = 64;
const _maxObjects = 100000;

Uint8List _random(int length) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

Future<Uint8List> _passwordKey(String password, List<int> salt) =>
    Isolate.run(() async {
      final key = await Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: 600000,
        bits: 256,
      ).deriveKeyFromPassword(password: password, nonce: salt);
      try {
        return Uint8List.fromList(await key.extractBytes());
      } finally {
        key.destroy();
      }
    });

class VaultItem {
  final String id, name;
  final int size, children;
  final bool isDir;
  final List<String> ancestors;
  const VaultItem(this.id, this.name, this.size,
      {this.isDir = false, this.children = 0, this.ancestors = const []});
}

typedef VaultDeviceEnvelope = Future<Uint8List> Function(Uint8List data,
    {required bool seal});

class VaultStore {
  final Directory root;
  final Storage storage;
  final VaultDeviceEnvelope? deviceEnvelope;
  final _cipher = AesGcm.with256bits();
  SecretKeyData? _master;
  int _generation = 0;

  VaultStore(this.root, this.storage, {this.deviceEnvelope});

  File get _config => File(p.join(root.path, 'vault.json'));
  bool get unlocked => _master != null;
  Future<bool> configured() => _config.exists();

  void lock() {
    _generation++;
    _master?.destroy();
    _master = null;
  }

  Future<void> unlock(String password, {required bool create}) async {
    final generation = _generation;
    if (create) {
      await root.create(recursive: true);
      if (await configured() || !await root.list(followLinks: false).isEmpty) {
        throw const FileSystemException('Thư mục riêng tư đã có dữ liệu');
      }
    }
    final rawMaster = create ? _random(32) : await _unwrap(_config, password);
    try {
      if (create)
        await _wrap(rawMaster, password, () => _checkGeneration(generation));
      _checkGeneration(generation);
      _master?.destroy();
      _master = SecretKeyData(Uint8List.fromList(rawMaster),
          overwriteWhenDestroyed: true);
    } finally {
      rawMaster.fillRange(0, rawMaster.length, 0);
    }
  }

  void _checkGeneration(int generation) {
    if (generation != _generation) throw TransferCancelled();
  }

  Future<void> changePassword(
      String oldPassword, String newPassword, TransferProgress progress) async {
    if (!unlocked)
      throw const FileSystemException('Thư mục riêng tư đang khóa');
    final generation = _generation;
    final master = await _unwrap(_config, oldPassword);
    try {
      await _wrap(master, newPassword, () {
        progress.check();
        _checkGeneration(generation);
      });
    } finally {
      master.fillRange(0, master.length, 0);
    }
  }

  Future<void> _wrap(
      List<int> master, String password, void Function() check) async {
    if (password.length < 8) {
      throw const FileSystemException('Mật khẩu cần ít nhất 8 ký tự');
    }
    final salt = _random(24);
    final derived = await _passwordKey(password, salt);
    final key = SecretKeyData(derived, overwriteWhenDestroyed: true);
    try {
      final box = await _cipher.encrypt(master,
          secretKey: key, aad: utf8.encode('$_version:master'));
      await _writeLocalConfig(
          _config,
          {
            'version': 1,
            'salt': base64Encode(salt),
            'key': base64Encode(box.concatenation()),
          },
          check);
    } finally {
      key.destroy();
      derived.fillRange(0, derived.length, 0);
    }
  }

  Future<void> _writeLocalConfig(
      File config, Map<String, Object> portable, void Function() check) async {
    final envelope = deviceEnvelope;
    if (envelope == null) {
      check();
      await writeStorageRecord(config, portable);
      return;
    }
    final data = Uint8List.fromList(utf8.encode(jsonEncode(portable)));
    try {
      check();
      final protected = await envelope(data, seal: true);
      check();
      await writeStorageRecord(
          config, {'version': 2, 'device': base64Encode(protected)});
    } finally {
      data.fillRange(0, data.length, 0);
    }
  }

  Future<Map<String, Object>> _readConfig(File config) async {
    if (await config.length() > 4096) {
      throw const FormatException('Cấu hình thư mục riêng tư không hợp lệ');
    }
    var row = jsonDecode(await config.readAsString());
    if (row is Map && row['version'] == 2) {
      final envelope = deviceEnvelope;
      if (envelope == null || row['device'] is! String) {
        throw const FileSystemException(
            'Cần khóa Android Keystore của thiết bị này');
      }
      final data = Uint8List.fromList(
          await envelope(base64Decode(row['device'] as String), seal: false));
      try {
        row = jsonDecode(utf8.decode(data));
      } finally {
        data.fillRange(0, data.length, 0);
      }
    }
    if (row is! Map ||
        row['version'] != 1 ||
        row['salt'] is! String ||
        row['key'] is! String) {
      throw const FormatException('Cấu hình thư mục riêng tư không hợp lệ');
    }
    return {
      'version': 1,
      'salt': row['salt'] as String,
      'key': row['key'] as String
    };
  }

  Future<List<int>> _unwrap(File config, String password) async {
    final row = await _readConfig(config);
    final salt = base64Decode(row['salt'] as String);
    final wrapped = base64Decode(row['key'] as String);
    if (salt.length != 24 ||
        wrapped.length != _cipher.nonceLength + _tagSize + 32) {
      throw const FormatException('Cấu hình thư mục riêng tư không hợp lệ');
    }
    final derived = await _passwordKey(password, salt);
    final passKey = SecretKeyData(Uint8List.fromList(derived),
        overwriteWhenDestroyed: true);
    derived.fillRange(0, derived.length, 0);
    try {
      return Uint8List.fromList(await _cipher.decrypt(
          SecretBox.fromConcatenation(wrapped,
              nonceLength: _cipher.nonceLength, macLength: _tagSize),
          secretKey: passKey,
          aad: utf8.encode('$_version:master')));
    } on SecretBoxAuthenticationError {
      throw const FileSystemException('Sai mật khẩu hoặc cấu hình đã hỏng');
    } finally {
      passKey.destroy();
    }
  }

  static final _id = RegExp(r'^[0-9a-f]{32}$');
  static final _fileName = RegExp(r'^[0-9a-f]{32}\.fmv$');
  static final _folderName = RegExp(r'^[0-9a-f]{32}\.fmd$');

  File _object(String id, [Directory? location]) {
    if (!_id.hasMatch(id))
      throw const FormatException('Mã tệp riêng tư không hợp lệ');
    return File(p.join((location ?? root).path, '$id.fmv'));
  }

  Directory _folder(String id, [Directory? location]) {
    if (!_id.hasMatch(id))
      throw const FormatException('Mã thư mục không hợp lệ');
    return Directory(p.join((location ?? root).path, '$id.fmd'));
  }

  Future<SecretKey> _key(String id, [String parent = '']) async {
    final master = _master;
    if (master == null)
      throw const FileSystemException('Thư mục riêng tư đang khóa');
    return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: master,
      nonce: utf8.encode(parent.isEmpty ? id : '$parent:$id'),
      info: utf8.encode('$_version:file'),
    );
  }

  Uint8List _nonce(int sequence) {
    final nonce = ByteData(12)..setUint64(4, sequence);
    return nonce.buffer.asUint8List();
  }

  List<int> _aad(String id, int sequence) =>
      utf8.encode('$_version:$id:$sequence');

  Future<void> _seal(RandomAccessFile out, List<int> plaintext, SecretKey key,
      String id, int sequence) async {
    final box = await _cipher.encrypt(plaintext,
        secretKey: key, nonce: _nonce(sequence), aad: _aad(id, sequence));
    await out.writeFrom(box.cipherText);
    await out.writeFrom(box.mac.bytes);
  }

  Future<List<int>> _open(RandomAccessFile input, int size, SecretKey key,
      String id, int sequence) async {
    final record = await input.read(size + _tagSize);
    if (record.length != size + _tagSize) {
      throw const FileSystemException('Tập tin riêng tư bị thiếu dữ liệu');
    }
    try {
      return await _cipher.decrypt(
          SecretBox(
            Uint8List.sublistView(record, 0, size),
            nonce: _nonce(sequence),
            mac: Mac(Uint8List.sublistView(record, size)),
          ),
          secretKey: key,
          aad: _aad(id, sequence));
    } on SecretBoxAuthenticationError {
      throw const FileSystemException(
          'Dữ liệu riêng tư không vượt qua xác thực');
    }
  }

  Uint8List _metadata(VaultItem item) {
    _checkName(item.name);
    final json = utf8.encode(jsonEncode({
      'name': item.name,
      'size': item.size,
      if (item.isDir) 'children': item.children,
    }));
    if (json.length > _metadataSize - 4) {
      throw const FileSystemException('Tên tập tin quá dài');
    }
    final header = Uint8List(_metadataSize);
    ByteData.sublistView(header).setUint32(0, json.length);
    header.setRange(4, 4 + json.length, json);
    return header;
  }

  Future<VaultItem> _readHeader(
      RandomAccessFile input, SecretKey key, String id) async {
    final record =
        Uint8List.fromList(await _open(input, _metadataSize, key, id, 0));
    final length = ByteData.sublistView(record).getUint32(0);
    if (length > _metadataSize - 4)
      throw const FormatException('Đầu tệp riêng tư bị lỗi');
    final row =
        jsonDecode(utf8.decode(Uint8List.sublistView(record, 4, length + 4)))
            as Map;
    final name = row['name'];
    final size = row['size'];
    final children = row['children'];
    if (name is! String ||
        size is! int ||
        size < 0 ||
        (children != null &&
            (children is! int || children < 0 || children > _maxObjects))) {
      throw const FormatException('Thông tin tập tin riêng tư không hợp lệ');
    }
    _checkName(name);
    return VaultItem(id, name, size,
        isDir: children != null, children: children as int? ?? 0);
  }

  static void _checkName(String name) {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name != p.basename(name) ||
        privateStorageName(name) ||
        name.contains('\u0000') ||
        name.contains('\\')) {
      throw const FormatException('Thông tin tập tin riêng tư không hợp lệ');
    }
  }

  Future<(List<VaultItem>, int)> list(TransferProgress progress) async {
    if (!unlocked)
      throw const FileSystemException('Thư mục riêng tư đang khóa');
    return _readItems(root, const [], progress);
  }

  Future<List<VaultItem>> listFolder(
      VaultItem folder, TransferProgress progress) async {
    final (items, damaged) = await _readItems(
        _folder(folder.id, _location(folder.ancestors)),
        [...folder.ancestors, folder.id],
        progress);
    if (damaged != 0 ||
        items.length != folder.children ||
        items.fold(0, (sum, item) => sum + item.size) != folder.size ||
        items.map((item) => item.name).toSet().length != items.length) {
      throw const FormatException('Nội dung thư mục riêng tư không khớp');
    }
    return items;
  }

  Directory _location(List<String> ancestors) =>
      ancestors.fold(root, (location, id) => _folder(id, location));

  Future<(List<VaultItem>, int)> _readItems(Directory location,
      List<String> ancestors, TransferProgress progress) async {
    if (ancestors.length > _maxDepth)
      throw const FormatException('Thư mục riêng tư quá sâu');
    final items = <VaultItem>[];
    var damaged = 0;
    final parent = ancestors.isEmpty ? '' : ancestors.last;
    await for (final node in location.list(followLinks: false)) {
      progress.check();
      final name = p.basename(node.path);
      final folder = _folderName.hasMatch(name);
      if (!folder && !_fileName.hasMatch(name)) continue;
      final id = p.basenameWithoutExtension(name);
      if (id == parent && !folder) continue;
      final key = await _key(id, parent);
      try {
        if ((folder && node is! Directory) || (!folder && node is! File)) {
          throw const FormatException('Loại mục riêng tư không hợp lệ');
        }
        final file = folder ? _object(id, node as Directory) : node as File;
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
          throw const FormatException('Mục riêng tư không hợp lệ');
        }
        final input = await file.open();
        try {
          final item = await _readHeader(input, key, id);
          if (item.isDir != folder ||
              (folder && await input.length() != _metadataSize + _tagSize)) {
            throw const FormatException(
                'Thông tin thư mục riêng tư không hợp lệ');
          }
          items.add(VaultItem(id, item.name, item.size,
              isDir: folder,
              children: item.children,
              ancestors: List.unmodifiable(ancestors)));
        } finally {
          await input.close();
        }
      } on FileSystemException {
        damaged++;
      } on FormatException {
        damaged++;
      } finally {
        key.destroy();
      }
    }
    return (items..sort((a, b) => a.name.compareTo(b.name)), damaged);
  }

  Future<void> cleanWrites() async {
    if (await root.exists()) {
      final partName = RegExp(r'^[0-9a-f]{32}\.fm[vd]\.part$');
      await for (final node in root.list(followLinks: false)) {
        final name = p.basename(node.path);
        if ((node is File && name == 'vault.json.new') ||
            partName.hasMatch(name)) {
          await node.delete(recursive: node is Directory);
        }
      }
    }
    if (await root.parent.exists()) {
      await for (final node in root.parent.list(followLinks: false)) {
        if (node is Directory &&
            p.basename(node.path).startsWith('fm-vault-restore-')) {
          await node.delete(recursive: true);
        }
      }
    }
  }

  Future<void> importFile(String path, TransferProgress progress) async {
    final before = await storage.stat(path);
    if (before?.isDir == true) {
      final generation = _generation;
      if (!unlocked)
        throw const FileSystemException('Thư mục riêng tư đang khóa');
      final id = storageId();
      final target = _folder(id);
      final stage = Directory('${target.path}.part');
      if (await stage.exists())
        throw const FileSystemException('Mã thư mục bị trùng');
      await stage.create();
      try {
        await _importFolder(before!, id, '', stage, progress, 1, [0]);
        progress.check();
        _checkGeneration(generation);
        await storage.rename(stage.path, target.path);
      } finally {
        if (await stage.exists()) await stage.delete(recursive: true);
      }
      return;
    }
    if (before == null || !before.isFile || before.size < 0) {
      throw FileSystemException(
          'Không xác định được kích thước tập tin nguồn', path);
    }
    await _importRegular(before, root, '', progress);
  }

  Future<int> _importFolder(
      StorageEntry entry,
      String id,
      String parent,
      Directory stage,
      TransferProgress progress,
      int depth,
      List<int> walked) async {
    if (depth > _maxDepth)
      throw const FormatException('Thư mục riêng tư quá sâu');
    final name = p.basename(entry.path);
    _checkName(name);
    var count = 0, total = 0;
    final names = <String>{};
    await for (final child in storage.children(entry.path)) {
      progress.check();
      final childName = p.basename(child.path);
      _checkName(childName);
      if (++walked[0] > _maxObjects ||
          !names.add(childName) ||
          p.dirname(child.path) != entry.path) {
        throw const FormatException('Cấu trúc thư mục nguồn không hợp lệ');
      }
      if (child.isDir) {
        final childId = storageId();
        final childDir = await _folder(childId, stage).create();
        total += await _importFolder(
            child, childId, id, childDir, progress, depth + 1, walked);
      } else if (child.isFile && child.size >= 0) {
        await _importRegular(child, stage, id, progress);
        total += child.size;
      } else {
        throw const FileSystemException(
            'Thư mục chứa mục không đọc được hoặc liên kết');
      }
      count++;
    }
    final after = await storage.stat(entry.path);
    if (after == null ||
        !after.isDir ||
        after.modified != entry.modified ||
        after.version != entry.version ||
        after.identity != entry.identity) {
      throw const FileSystemException('Thư mục nguồn đã thay đổi');
    }
    final marker = _object(id, stage);
    final key = await _key(id, parent);
    try {
      await marker.create(exclusive: true);
      final output = await marker.open(mode: FileMode.writeOnly);
      try {
        await _seal(
            output,
            _metadata(VaultItem(id, name, total, isDir: true, children: count)),
            key,
            id,
            0);
        await output.flush();
      } finally {
        await output.close();
      }
      await _readFile(marker, id, key, progress, (_) async {});
    } finally {
      key.destroy();
    }
    return total;
  }

  Future<void> _importRegular(StorageEntry before, Directory location,
      String parent, TransferProgress progress) async {
    final generation = _generation;
    final path = before.path;
    final id = storageId();
    final target = _object(id, location);
    final part = File('${target.path}.part');
    final item = VaultItem(id, p.basename(path), before.size);
    final key = await _key(id, parent);
    try {
      await part.create(exclusive: true);
      final output = await part.open(mode: FileMode.writeOnly);
      final expected = _VaultDigest();
      final digest = hashes.sha256.startChunkedConversion(expected);
      try {
        await _seal(output, _metadata(item), key, id, 0);
        final input = await storage.open(path);
        var read = 0, counter = 1, pending = 0;
        final block = Uint8List(_chunk);
        try {
          while (true) {
            progress.check();
            final bytes = await input.read();
            if (bytes.isEmpty) break;
            read += bytes.length;
            if (read > item.size)
              throw FileSystemException('Tập tin đã thay đổi', path);
            digest.add(bytes);
            for (var offset = 0; offset < bytes.length;) {
              progress.check();
              final copied = min(_chunk - pending, bytes.length - offset);
              block.setRange(pending, pending + copied, bytes, offset);
              pending += copied;
              offset += copied;
              if (pending == _chunk) {
                await _seal(output, block, key, id, counter++);
                pending = 0;
              }
            }
            progress.add(bytes.length);
          }
          if (pending != 0)
            await _seal(output, Uint8List.sublistView(block, 0, pending), key,
                id, counter);
          if (read != item.size)
            throw FileSystemException('Tập tin đã thay đổi', path);
        } finally {
          block.fillRange(0, block.length, 0);
          await input.close();
        }
        await output.flush();
      } finally {
        digest.close();
        await output.close();
      }
      progress.describe('Đang xác thực bản mã hóa…');
      final actual = _VaultDigest();
      final decoded = hashes.sha256.startChunkedConversion(actual);
      try {
        await _readFile(
            part, id, key, progress, (bytes) async => decoded.add(bytes));
      } finally {
        decoded.close();
      }
      final after = await storage.stat(path);
      if (actual.value != expected.value ||
          after == null ||
          after.type != before.type ||
          after.size != before.size ||
          after.modified != before.modified ||
          after.version != before.version ||
          after.identity != before.identity) {
        throw FileSystemException('Không xác minh được bản mã hóa', path);
      }
      progress.check();
      _checkGeneration(generation);
      if (await target.exists())
        throw const FileSystemException('Mã tệp bị trùng');
      await part.rename(target.path);
    } finally {
      key.destroy();
      if (await part.exists()) await part.delete();
    }
  }

  Future<VaultItem> _readFile(
      File file,
      String id,
      SecretKey key,
      TransferProgress progress,
      Future<void> Function(List<int>) onChunk) async {
    final input = await file.open();
    try {
      final item = await _readHeader(input, key, id);
      var left = item.isDir ? 0 : item.size, counter = 1;
      final records = (left + _chunk - 1) ~/ _chunk;
      final expected = _metadataSize + _tagSize + left + _tagSize * records;
      if (await input.length() != expected) {
        throw const FileSystemException(
            'Kích thước dữ liệu riêng tư không hợp lệ');
      }
      while (left > 0) {
        progress.check();
        final bytes = await _open(input, min(_chunk, left), key, id, counter++);
        await onChunk(bytes);
        left -= bytes.length;
      }
      return item;
    } finally {
      await input.close();
    }
  }

  Future<void> decryptTo(
      VaultItem item, File target, TransferProgress progress) async {
    if (item.isDir) throw const FormatException('Chọn đích thư mục để xuất');
    final source = _object(item.id, _location(item.ancestors));
    final key =
        await _key(item.id, item.ancestors.isEmpty ? '' : item.ancestors.last);
    var created = false;
    var verified = false;
    try {
      await target.create(exclusive: true);
      created = true;
      final output = await target.open(mode: FileMode.writeOnly);
      try {
        final actual =
            await _readFile(source, item.id, key, progress, (bytes) async {
          await output.writeFrom(bytes);
          progress.add(bytes.length);
        });
        if (actual.name != item.name || actual.size != item.size) {
          throw const FileSystemException('Tệp riêng tư đã thay đổi');
        }
        progress.check();
        await output.flush();
      } finally {
        await output.close();
      }
      verified = true;
    } finally {
      key.destroy();
      if (created && !verified) await target.delete();
    }
  }

  Future<void> exportTo(
      VaultItem item, String target, TransferProgress progress) async {
    if (!item.isDir) return decryptTo(item, File(target), progress);
    final folder = Directory(target);
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FileSystemException('Đích xuất đã tồn tại');
    }
    await folder.create();
    try {
      for (final child in await listFolder(item, progress)) {
        progress.check();
        await exportTo(child, p.join(target, child.name), progress);
      }
    } catch (_) {
      await folder.delete(recursive: true);
      rethrow;
    }
  }

  Future<Uint8List> preview(VaultItem item, TransferProgress progress,
      {required int limit}) async {
    if (item.isDir || item.size > limit) {
      throw const FileSystemException('Tập tin vượt giới hạn xem trước');
    }
    final key =
        await _key(item.id, item.ancestors.isEmpty ? '' : item.ancestors.last);
    final bytes = BytesBuilder();
    try {
      final actual = await _readFile(
          _object(item.id, _location(item.ancestors)), item.id, key, progress,
          (chunk) async {
        if (bytes.length + chunk.length > limit) {
          throw const FileSystemException('Tập tin vượt giới hạn xem trước');
        }
        bytes.add(chunk);
      });
      if (actual.isDir ||
          actual.name != item.name ||
          actual.size != item.size) {
        throw const FileSystemException('Tệp riêng tư đã thay đổi');
      }
      progress.check();
      return bytes.takeBytes();
    } finally {
      key.destroy();
      final remaining = bytes.takeBytes();
      remaining.fillRange(0, remaining.length, 0);
    }
  }

  Future<void> backupTo(
      Directory destination, TransferProgress progress) async {
    final generation = _generation;
    if (!unlocked)
      throw const FileSystemException('Thư mục riêng tư đang khóa');
    if (!await destination.list(followLinks: false).isEmpty) {
      throw const FileSystemException('Vị trí sao lưu phải trống');
    }
    await _verifyObjects(progress);
    final snapshotConfig = File(p.join(destination.path, 'vault.json'));
    await writeStorageRecord(snapshotConfig, await _readConfig(_config));
    await _copySnapshot(root.path, destination, progress, restore: false);
    final tag = await _snapshotMac(destination, progress);
    progress.check();
    _checkGeneration(generation);
    await File(p.join(destination.path, _backupTag))
        .writeAsString(tag, flush: true);
    await _verifySnapshot(destination, progress);
  }

  Future<void> restoreBackup(
      String source, String password, TransferProgress progress) async {
    final generation = _generation;
    if (await root.exists() && !await root.list(followLinks: false).isEmpty) {
      throw const FileSystemException('Chỉ phục hồi vào kho trống');
    }
    await root.parent.create(recursive: true);
    final stage = await root.parent.createTemp('fm-vault-restore-');
    final copy = VaultStore(stage, storage);
    try {
      final config = p.join(source, 'vault.json');
      if (await storage.stat(config) case final stat?
          when stat.isFile && stat.size >= 0 && stat.size <= 4096) {
        await storage.copyFile(config, copy._config.path, progress: progress);
      } else {
        throw const FormatException('Bản sao thiếu cấu hình kho mã hóa');
      }
      await copy.unlock(password, create: false);
      progress.check();
      await _copySnapshot(source, stage, progress, restore: true);
      await copy._verifySnapshot(stage, progress);
      await copy._verifyObjects(progress);
      await _writeLocalConfig(
          copy._config, await copy._readConfig(copy._config), () {
        progress.check();
        _checkGeneration(generation);
      });
      await File(p.join(stage.path, _backupTag)).delete();
      progress.check();
      _checkGeneration(generation);
      if (await root.exists())
        await root.delete(); // Fails if the existing vault contains any data.
      progress.check();
      _checkGeneration(generation);
      await stage.rename(root.path);
    } finally {
      copy.lock();
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  }

  Future<void> _copySnapshot(
      String source, Directory destination, TransferProgress progress,
      {required bool restore}) async {
    var count = 0;
    Future<void> copyChildren(String from, Directory to, int depth) async {
      if (depth > _maxDepth)
        throw const FormatException('Bản sao vượt quá độ sâu cho phép');
      await for (final entry in storage.children(from)) {
        progress.check();
        final name = p.basename(entry.path);
        if (p.dirname(entry.path) != from || ++count > 2 * _maxObjects) {
          throw const FormatException('Cấu trúc bản sao kho không hợp lệ');
        }
        final target = p.join(to.path, name);
        if (entry.isDir && _folderName.hasMatch(name)) {
          if (await FileSystemEntity.type(target, followLinks: false) !=
              FileSystemEntityType.notFound) {
            throw const FormatException('Bản sao có mục trùng tên');
          }
          await copyChildren(
              entry.path, await Directory(target).create(), depth + 1);
        } else if (entry.isFile &&
            entry.size >= 0 &&
            (_fileName.hasMatch(name) ||
                (depth == 0 && name == 'vault.json' && entry.size <= 4096) ||
                (depth == 0 &&
                    restore &&
                    name == _backupTag &&
                    entry.size == 44))) {
          if (depth == 0 && name == 'vault.json') continue;
          await storage.copyFile(entry.path, target, progress: progress);
        } else {
          throw const FormatException('Bản sao chứa mục không hợp lệ');
        }
      }
    }

    await copyChildren(source, destination, 0);
  }

  Future<void> _verifyObjects(TransferProgress progress) async {
    final (entries, damaged) = await list(progress);
    if (damaged != 0)
      throw const FormatException('Kho có dữ liệu không xác thực được');
    Future<void> verify(List<VaultItem> items) async {
      for (final item in items) {
        progress.check();
        if (item.isDir) {
          await verify(await listFolder(item, progress));
        } else {
          final key = await _key(
              item.id, item.ancestors.isEmpty ? '' : item.ancestors.last);
          try {
            await _readFile(_object(item.id, _location(item.ancestors)),
                item.id, key, progress, (chunk) async {});
          } finally {
            key.destroy();
          }
        }
      }
    }

    await verify(entries);
  }

  Future<String> _snapshotMac(
      Directory location, TransferProgress progress) async {
    final master = _master;
    if (master == null)
      throw const FileSystemException('Thư mục riêng tư đang khóa');
    final snapshotKey = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(
            secretKey: master,
            nonce: const [],
            info: utf8.encode('$_version:backup'));
    final bytes = await snapshotKey.extractBytes();
    final sink = _VaultDigest();
    final mac = hashes.Hmac(hashes.sha256, bytes).startChunkedConversion(sink);
    try {
      mac.add(utf8.encode('$_version:backup\n'));
      Future<void> addFiles(Directory directory) async {
        final children = await directory.list(followLinks: false).toList()
          ..sort((a, b) => a.path.compareTo(b.path));
        for (final node in children) {
          progress.check();
          final relative = p.relative(node.path, from: location.path);
          if (relative == _backupTag) continue;
          if (node is Directory) {
            mac.add(utf8.encode(jsonEncode([relative, -1])));
            await addFiles(node);
          } else if (node is File) {
            final length = await node.length();
            mac.add(utf8.encode(jsonEncode([relative, length])));
            var read = 0;
            await for (final data in node.openRead()) {
              progress.check();
              mac.add(data);
              read += data.length;
            }
            if (read != length)
              throw const FormatException('Bản sao đã thay đổi khi xác minh');
          } else {
            throw const FormatException('Bản sao chứa liên kết');
          }
        }
      }

      await addFiles(location);
    } finally {
      mac.close();
      snapshotKey.destroy();
    }
    return base64Encode(sink.value!.bytes);
  }

  Future<void> _verifySnapshot(
      Directory location, TransferProgress progress) async {
    final tag = File(p.join(location.path, _backupTag));
    if (await tag.length() != 44)
      throw const FormatException('Thiếu mã xác thực bản sao kho');
    final expected = base64Decode(await tag.readAsString());
    final actual = base64Decode(await _snapshotMac(location, progress));
    if (Mac(expected) != Mac(actual)) {
      throw const FormatException('Bản sao kho không vượt qua xác thực');
    }
  }
}

class _VaultDigest implements Sink<hashes.Digest> {
  hashes.Digest? value;
  @override
  void add(hashes.Digest data) => value = data;
  @override
  void close() {}
}
