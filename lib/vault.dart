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
  final int size;
  const VaultItem(this.id, this.name, this.size);
}

class VaultStore {
  final Directory root;
  final Storage storage;
  final _cipher = AesGcm.with256bits();
  SecretKeyData? _master;
  int _generation = 0;

  VaultStore(this.root, this.storage);

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
    await root.create(recursive: true);
    final salt = create ? _random(24) : null;
    final Map? previous =
        create ? null : jsonDecode(await _config.readAsString()) as Map;
    if ((create && await _config.exists()) ||
        (!create && previous!['version'] != 1)) {
      throw const FileSystemException(
          'Không mở được cấu hình thư mục riêng tư');
    }
    if (create && password.length < 8) {
      throw const FileSystemException('Mật khẩu cần ít nhất 8 ký tự');
    }
    final actualSalt = salt ?? base64Decode(previous!['salt'] as String);
    final derived = await _passwordKey(password, actualSalt);
    final passKey = SecretKeyData(Uint8List.fromList(derived),
        overwriteWhenDestroyed: true);
    derived.fillRange(0, derived.length, 0);
    List<int>? rawMaster;
    try {
      final aad = utf8.encode('$_version:master');
      if (create) {
        rawMaster = _random(32);
        final box =
            await _cipher.encrypt(rawMaster, secretKey: passKey, aad: aad);
        if (generation != _generation) throw TransferCancelled();
        await writeStorageRecord(_config, {
          'version': 1,
          'salt': base64Encode(actualSalt),
          'key': base64Encode(box.concatenation()),
        });
      } else {
        final box = SecretBox.fromConcatenation(
          base64Decode(previous!['key'] as String),
          nonceLength: _cipher.nonceLength,
          macLength: _tagSize,
        );
        rawMaster = await _cipher.decrypt(box, secretKey: passKey, aad: aad);
      }
      if (generation != _generation) throw TransferCancelled();
      _master?.destroy();
      _master = SecretKeyData(Uint8List.fromList(rawMaster),
          overwriteWhenDestroyed: true);
    } on SecretBoxAuthenticationError {
      throw const FileSystemException('Sai mật khẩu hoặc cấu hình đã hỏng');
    } finally {
      passKey.destroy();
      rawMaster?.fillRange(0, rawMaster.length, 0);
    }
  }

  static final _id = RegExp(r'^[0-9a-f]{32}$');

  File _object(String id) {
    if (!_id.hasMatch(id))
      throw const FormatException('Mã tệp riêng tư không hợp lệ');
    return File(p.join(root.path, '$id.fmv'));
  }

  Future<SecretKey> _key(String id) async {
    final master = _master;
    if (master == null)
      throw const FileSystemException('Thư mục riêng tư đang khóa');
    return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: master,
      nonce: utf8.encode(id),
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
    final json =
        utf8.encode(jsonEncode({'name': item.name, 'size': item.size}));
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
    final name = row['name'] as String;
    final size = row['size'] as int;
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name != p.basename(name) ||
        privateStorageName(name) ||
        name.contains('\u0000') ||
        size < 0) {
      throw const FormatException('Thông tin tập tin riêng tư không hợp lệ');
    }
    return VaultItem(id, name, size);
  }

  Future<(List<VaultItem>, int)> list(TransferProgress progress) async {
    if (!unlocked)
      throw const FileSystemException('Thư mục riêng tư đang khóa');
    final items = <VaultItem>[];
    var damaged = 0;
    await for (final file in root.list(followLinks: false)) {
      progress.check();
      if (file is! File || p.extension(file.path) != '.fmv') continue;
      final id = p.basenameWithoutExtension(file.path);
      if (!_id.hasMatch(id)) continue;
      final key = await _key(id);
      try {
        final input = await file.open();
        try {
          items.add(await _readHeader(input, key, id));
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
    if (!await root.exists()) return;
    await for (final file in root.list(followLinks: false)) {
      if (file is File &&
          RegExp(r'^[0-9a-f]{32}\.fmv\.part$')
              .hasMatch(p.basename(file.path))) {
        await file.delete();
      }
    }
  }

  Future<void> importFile(String path, TransferProgress progress) async {
    final before = await storage.stat(path);
    if (before == null || !before.isFile || before.size < 0) {
      throw FileSystemException(
          'Không xác định được kích thước tập tin nguồn', path);
    }
    final id = storageId();
    final target = _object(id);
    final part = File('${target.path}.part');
    final item = VaultItem(id, p.basename(path), before.size);
    final key = await _key(id);
    try {
      await part.create(exclusive: true);
      final output = await part.open(mode: FileMode.writeOnly);
      final expected = _VaultDigest();
      final digest = hashes.sha256.startChunkedConversion(expected);
      try {
        await _seal(output, _metadata(item), key, id, 0);
        final input = await storage.open(path);
        var read = 0, counter = 1;
        try {
          while (true) {
            progress.check();
            final bytes = await input.read();
            if (bytes.isEmpty) break;
            read += bytes.length;
            if (read > item.size)
              throw FileSystemException('Tập tin đã thay đổi', path);
            digest.add(bytes);
            for (var offset = 0; offset < bytes.length; offset += _chunk) {
              progress.check();
              final chunk = Uint8List.sublistView(
                  bytes, offset, min(offset + _chunk, bytes.length));
              await _seal(output, chunk, key, id, counter++);
            }
            progress.add(bytes.length);
          }
          if (read != item.size)
            throw FileSystemException('Tập tin đã thay đổi', path);
        } finally {
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
          after.version != before.version) {
        throw FileSystemException('Không xác minh được bản mã hóa', path);
      }
      progress.check();
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
      var left = item.size, counter = 1;
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
    final source = _object(item.id);
    final key = await _key(item.id);
    try {
      await target.create(exclusive: true);
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
        await output.flush();
      } finally {
        await output.close();
      }
    } finally {
      key.destroy();
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
