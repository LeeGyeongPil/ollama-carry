import 'dart:convert';
import 'dart:typed_data';

import 'digest.dart';
import 'errors.dart';

/// Receives bytes (a file, a list of part files, a test buffer).
abstract class ByteSink {
  /// Appends [chunk].
  void add(List<int> chunk);
}

/// Produces bytes sequentially.
abstract class ByteSource {
  /// Reads up to [length] bytes into [buffer] at [start]; returns 0 at the end.
  int read(Uint8List buffer, int start, int length);
}

/// A [ByteSink] that collects bytes in memory (tests, small bundles).
class MemorySink implements ByteSink {
  /// Collected bytes.
  final BytesBuilder builder = BytesBuilder(copy: false);

  @override
  void add(List<int> chunk) => builder.add(chunk);
}

/// A [ByteSource] over an in-memory byte list.
class MemorySource implements ByteSource {
  /// Reads from [bytes].
  MemorySource(this.bytes);

  /// The data.
  final List<int> bytes;
  int _pos = 0;

  @override
  int read(Uint8List buffer, int start, int length) {
    final n = length < bytes.length - _pos ? length : bytes.length - _pos;
    buffer.setRange(start, start + n, bytes, _pos);
    _pos += n;
    return n;
  }
}

/// Largest size that fits the 11 octal digits of a ustar header (8 GiB - 1).
const int maxUstarSize = 8589934591;

const int _block = 512;

/// A malformed tar stream; [offset] is the byte position in the stream.
class TarFormatException extends CarryException {
  /// Creates the exception.
  TarFormatException(super.message, this.offset);

  /// Stream offset where the problem was found.
  final int offset;
}

/// Streaming ustar writer with PAX `path` / `size` extensions.
///
/// Entries are written as `beginFile`, any number of `writeData`, `endFile`.
/// Metadata is fixed (mtime 0, uid/gid 0, mode 0644) so the same input always
/// produces the same bytes.
class TarWriter {
  /// Writes to [sink].
  TarWriter(this._sink);

  final ByteSink _sink;
  int _remaining = 0;
  int _padding = 0;

  /// Starts an entry of [size] data bytes. Names longer than 100 bytes use a
  /// PAX `path` record and sizes above 8 GiB use a PAX `size` record.
  /// [typeFlag] other than `0` is only for tests that build hostile bundles.
  void beginFile(
    String name,
    int size, {
    String typeFlag = '0',
    String linkName = '',
  }) {
    if (_remaining != 0) {
      throw StateError('previous tar entry is not complete');
    }
    final records = <String, String>{};
    if (utf8.encode(name).length > 100) records['path'] = name;
    final bigSize = size > maxUstarSize;
    if (bigSize) records['size'] = '$size';
    if (records.isNotEmpty) _writePax(records);
    _sink.add(_header(name, bigSize ? 0 : size, typeFlag, linkName));
    _remaining = size;
    _padding = (_block - size % _block) % _block;
  }

  /// Appends data of the current entry.
  void writeData(List<int> chunk) {
    _remaining -= chunk.length;
    if (_remaining < 0) throw StateError('more data than the entry size');
    _sink.add(chunk);
  }

  /// Finishes the current entry (writes block padding).
  void endFile() {
    if (_remaining != 0) throw StateError('entry data is incomplete');
    if (_padding > 0) _sink.add(Uint8List(_padding));
    _padding = 0;
  }

  /// Writes a whole small entry.
  void addBytes(String name, List<int> bytes) {
    beginFile(name, bytes.length);
    writeData(bytes);
    endFile();
  }

  /// Writes a link entry (used by tests to build hostile bundles).
  void addLink(String name, String target, {bool symbolic = true}) {
    beginFile(name, 0, typeFlag: symbolic ? '2' : '1', linkName: target);
    endFile();
  }

  /// Writes the end-of-archive marker.
  void finish() => _sink.add(Uint8List(_block * 2));

  void _writePax(Map<String, String> records) {
    final body = BytesBuilder();
    for (final e in records.entries) {
      final rest = utf8.encode(' ${e.key}=${e.value}\n');
      var length = rest.length + 1;
      while (rest.length + '$length'.length != length) {
        length = rest.length + '$length'.length;
      }
      body.add(utf8.encode('$length'));
      body.add(rest);
    }
    final bytes = body.takeBytes();
    _sink.add(_header('PaxHeader/entry', bytes.length, 'x', ''));
    _sink.add(bytes);
    final pad = (_block - bytes.length % _block) % _block;
    if (pad > 0) _sink.add(Uint8List(pad));
  }

  Uint8List _header(String name, int size, String typeFlag, String linkName) {
    final h = Uint8List(_block);
    void put(int offset, int width, String text) {
      final bytes = utf8.encode(text);
      final n = bytes.length < width ? bytes.length : width;
      h.setRange(offset, offset + n, bytes);
    }

    void octal(int offset, int width, int value) {
      put(offset, width, value.toRadixString(8).padLeft(width - 1, '0'));
    }

    put(0, 100, name);
    octal(100, 8, 420); // mode 0644
    octal(108, 8, 0); // uid
    octal(116, 8, 0); // gid
    octal(124, 12, size);
    octal(136, 12, 0); // mtime
    h.fillRange(148, 156, 0x20); // checksum placeholder
    h[156] = typeFlag.codeUnitAt(0);
    put(157, 100, linkName);
    put(257, 6, 'ustar');
    put(263, 2, '00');
    var sum = 0;
    for (final b in h) {
      sum += b;
    }
    put(148, 6, sum.toRadixString(8).padLeft(6, '0'));
    h[154] = 0;
    h[155] = 0x20;
    return h;
  }
}

/// One tar entry header.
class TarEntry {
  /// Creates an entry description.
  const TarEntry(this.name, this.size, this.typeFlag);

  /// Entry path as written in the archive.
  final String name;

  /// Data size in bytes.
  final int size;

  /// Tar type flag character (`0` regular file, `2` symlink, ...).
  final String typeFlag;

  /// True for a regular file (`0` or NUL).
  bool get isRegular => typeFlag == '0' || typeFlag == '\u0000';
}

/// Streaming tar reader (ustar + PAX `path`/`size`/`linkpath`, GNU base-256
/// sizes). It never loads an entry into memory unless you ask for that.
class TarReader {
  /// Reads from [source].
  TarReader(this._source);

  final ByteSource _source;
  final Uint8List _buf = Uint8List(chunkSize);
  int _position = 0;
  int _remaining = 0;
  int _padding = 0;

  /// Bytes consumed from the source so far.
  int get position => _position;

  /// Returns the next entry, or null at the end-of-archive marker.
  /// Unread data of the previous entry is skipped.
  TarEntry? nextEntry() {
    _skipRest();
    var pax = <String, String>{};
    while (true) {
      final block = _readHeaderBlock();
      if (block == null) return null;
      final start = _position - _block;
      _verifyChecksum(block, start);
      final type = block[156] == 0 ? '\u0000' : String.fromCharCode(block[156]);
      var name = _text(block, 0, 100);
      final prefix = _text(block, 345, 155);
      if (prefix.isNotEmpty && _text(block, 257, 5) == 'ustar') {
        name = '$prefix/$name';
      }
      var size = _size(block, start);
      if (type == 'x' || type == 'g') {
        if (size > 1024 * 1024) {
          throw TarFormatException('PAX header is too large', start);
        }
        final data = _readExact(size, start);
        _skipExact((_block - size % _block) % _block, start);
        if (type == 'x') pax = _parsePax(data, start);
        continue;
      }
      name = pax['path'] ?? name;
      if (pax['size'] != null) {
        final parsed = int.tryParse(pax['size']!);
        if (parsed == null || parsed < 0) {
          throw TarFormatException('invalid PAX size record', start);
        }
        size = parsed;
      }
      // Link, directory and device headers carry no data.
      final hasData = !'12345'.contains(type);
      _remaining = hasData ? size : 0;
      _padding = hasData ? (_block - size % _block) % _block : 0;
      return TarEntry(name, size, type);
    }
  }

  /// Reads the data of the current entry in chunks of at most [chunkSize].
  /// The chunk is only valid inside [onChunk].
  void readData(void Function(Uint8List chunk) onChunk) {
    while (_remaining > 0) {
      final want = _remaining < chunkSize ? _remaining : chunkSize;
      _fill(_buf, want, _position);
      _remaining -= want;
      onChunk(Uint8List.sublistView(_buf, 0, want));
    }
    _skipExact(_padding, _position);
    _padding = 0;
  }

  /// Reads the whole data of the current entry (small entries only).
  Uint8List readAll() {
    final out = BytesBuilder(copy: true);
    readData(out.add);
    return out.takeBytes();
  }

  void _skipRest() {
    while (_remaining > 0) {
      final n = _remaining < chunkSize ? _remaining : chunkSize;
      _fill(_buf, n, _position);
      _remaining -= n;
    }
    _skipExact(_padding, _position);
    _padding = 0;
  }

  Uint8List? _readHeaderBlock() {
    final block = Uint8List(_block);
    final first = _readUpTo(block, 0, _block);
    if (first == 0) {
      throw TarFormatException(
        'bundle ends without an end-of-archive marker; a part file is '
        'probably missing or truncated',
        _position,
      );
    }
    if (first < _block) {
      throw TarFormatException(
        'bundle ends in the middle of a header',
        _position,
      );
    }
    if (block.every((b) => b == 0)) {
      // Second zero block confirms the end; tolerate a single one.
      final next = Uint8List(_block);
      _readUpTo(next, 0, _block);
      return null;
    }
    return block;
  }

  int _readUpTo(Uint8List target, int start, int length) {
    var got = 0;
    while (got < length) {
      final n = _source.read(target, start + got, length - got);
      if (n == 0) break;
      got += n;
    }
    _position += got;
    return got;
  }

  void _fill(Uint8List target, int length, int offsetForError) {
    if (_readUpTo(target, 0, length) < length) {
      throw TarFormatException(
        'bundle ends in the middle of an entry; a part file is probably '
        'missing or truncated',
        _position,
      );
    }
  }

  Uint8List _readExact(int length, int errorOffset) {
    final data = Uint8List(length);
    if (_readUpTo(data, 0, length) < length) {
      throw TarFormatException('bundle ends early', errorOffset);
    }
    return data;
  }

  void _skipExact(int length, int errorOffset) {
    var left = length;
    while (left > 0) {
      final n = left < chunkSize ? left : chunkSize;
      _fill(_buf, n, errorOffset);
      left -= n;
    }
  }

  void _verifyChecksum(Uint8List block, int offset) {
    final stored = int.tryParse(_text(block, 148, 8).trim(), radix: 8);
    var sum = 0;
    for (var i = 0; i < _block; i++) {
      sum += (i >= 148 && i < 156) ? 0x20 : block[i];
    }
    if (stored != sum) {
      throw TarFormatException(
        'invalid tar header checksum (the data is damaged)',
        offset,
      );
    }
  }

  int _size(Uint8List block, int offset) {
    if (block[124] & 0x80 != 0) {
      var value = block[124] & 0x7f;
      for (var i = 125; i < 136; i++) {
        value = (value << 8) | block[i];
      }
      if (value < 0) throw TarFormatException('invalid size field', offset);
      return value;
    }
    final text = _text(block, 124, 12).trim();
    final value = text.isEmpty ? 0 : int.tryParse(text, radix: 8);
    if (value == null) throw TarFormatException('invalid size field', offset);
    return value;
  }

  String _text(Uint8List block, int offset, int width) {
    var end = offset;
    while (end < offset + width && block[end] != 0) {
      end++;
    }
    return utf8.decode(block.sublist(offset, end), allowMalformed: true);
  }

  Map<String, String> _parsePax(Uint8List data, int offset) {
    final records = <String, String>{};
    var pos = 0;
    while (pos < data.length) {
      final space = data.indexOf(0x20, pos);
      if (space < 0) throw TarFormatException('invalid PAX header', offset);
      final length = int.tryParse(utf8.decode(data.sublist(pos, space)));
      if (length == null || length < 1 || pos + length > data.length) {
        throw TarFormatException('invalid PAX header', offset);
      }
      final record = utf8.decode(
        data.sublist(space + 1, pos + length - 1),
        allowMalformed: true,
      );
      final eq = record.indexOf('=');
      if (eq > 0) records[record.substring(0, eq)] = record.substring(eq + 1);
      pos += length;
    }
    return records;
  }
}
