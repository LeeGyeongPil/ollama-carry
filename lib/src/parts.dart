import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'digest.dart';
import 'errors.dart';
import 'i18n.dart';
import 'tar.dart';

/// Part size for `--split fat32`: just under the 4 GiB FAT32 file limit.
const int fat32PartSize = 4 * 1024 * 1024 * 1024 - 1024 * 1024;

/// Parses `100K`, `512K`, `3.9G`, `1048576` or `fat32` into bytes.
/// K, M, G mean powers of 1024.
int parseSize(String text) {
  final value = text.trim().toLowerCase();
  if (value == 'fat32') return fat32PartSize;
  final match = RegExp(
    r'^([0-9]+(?:\.[0-9]+)?)\s*([kmg]?)(?:i?b)?$',
  ).firstMatch(value);
  if (match == null) {
    throw CarryException.coded(
      'size.invalid',
      params: {'text': text},
      exitCode: exitUsage,
    );
  }
  const factor = {'': 1, 'k': 1024, 'm': 1024 * 1024, 'g': 1024 * 1024 * 1024};
  final bytes = (double.parse(match.group(1)!) * factor[match.group(2)]!)
      .floor();
  if (bytes < 1024) {
    throw CarryException.coded(
      'size.small',
      params: {'text': text},
      exitCode: exitUsage,
    );
  }
  return bytes;
}

/// Name of part [index] of [base]: `<base>.000`, `<base>.001`, ...
String partName(String base, int index) =>
    '$base.${index.toString().padLeft(3, '0')}';

/// A finished part file.
class PartInfo {
  /// Creates a part description.
  const PartInfo(this.path, this.size, this.sha256);

  /// File path.
  final String path;

  /// Size in bytes.
  final int size;

  /// SHA-256 (hex) of the file.
  final String sha256;
}

/// Writes a byte stream to one file, or to numbered parts of at most
/// `partSize` bytes. Parts are hashed while they are written.
class PartsWriter implements ByteSink {
  /// Writes to [basePath] (single file) or `basePath.000`... when [partSize]
  /// is given.
  PartsWriter(this.basePath, {this.partSize});

  /// Base path of the bundle.
  final String basePath;

  /// Maximum bytes per part, or null for a single file.
  final int? partSize;

  /// Parts finished so far.
  final List<PartInfo> parts = [];

  RandomAccessFile? _raf;
  String? _currentPath;
  Sha256Stream? _hash;
  int _written = 0;

  @override
  void add(List<int> chunk) {
    var offset = 0;
    while (offset < chunk.length) {
      if (_raf == null) _open();
      final room = partSize == null ? chunk.length : partSize! - _written;
      final n = math.min(chunk.length - offset, room);
      final view = chunk is Uint8List
          ? Uint8List.sublistView(chunk, offset, offset + n)
          : Uint8List.fromList(chunk.sublist(offset, offset + n));
      _raf!.writeFromSync(view);
      _hash!.add(view);
      _written += n;
      offset += n;
      if (partSize != null && _written >= partSize!) _closePart();
    }
  }

  void _open() {
    final path = partSize == null ? basePath : partName(basePath, parts.length);
    _currentPath = path;
    _raf = File(path).openSync(mode: FileMode.writeOnly);
    _hash = Sha256Stream();
    _written = 0;
  }

  void _closePart() {
    final raf = _raf;
    if (raf == null) return;
    raf.closeSync();
    parts.add(PartInfo(_currentPath!, _written, _hash!.close()));
    _raf = null;
  }

  /// Finishes the last part and returns all parts.
  List<PartInfo> close() {
    _closePart();
    return parts;
  }

  /// Closes and deletes everything written so far (used when export fails).
  void abort() {
    _raf?.closeSync();
    _raf = null;
    for (final path in [...parts.map((e) => e.path), ?_currentPath]) {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    }
  }
}

/// Path of the checksum list for a bundle base path.
String checksumPath(String basePath) => '$basePath.sha256';

/// Writes `<base>.sha256` in `sha256sum` format (`<hex>  <file name>`).
void writeChecksumFile(String basePath, List<PartInfo> parts) {
  final lines = [
    for (final part in parts) '${part.sha256}  ${p.basename(part.path)}\n',
  ];
  File(checksumPath(basePath)).writeAsStringSync(lines.join());
}

/// Parses a `sha256sum` style file into file name to hash.
Map<String, String> readChecksumFile(File file) {
  final result = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    final match = RegExp(
      r'^([0-9a-fA-F]{64})\s+\*?(.+)$',
    ).firstMatch(line.trim());
    if (match != null) {
      result[match.group(2)!] = match.group(1)!.toLowerCase();
    }
  }
  return result;
}

/// The files that make up one bundle (a single file or `.000`, `.001`, ...).
class BundleParts {
  BundleParts._(this.files, this.sizes, this.checksums);

  /// Part files in order.
  final List<File> files;

  /// Size of each part.
  final List<int> sizes;

  /// Expected hashes from `<base>.sha256` (file name to hex); may be empty.
  final Map<String, String> checksums;

  /// Total bytes of all parts.
  int get totalSize => sizes.fold(0, (a, b) => a + b);

  /// Finds the parts for [path], which may be the first part (`x.tar.000`),
  /// any part, or the unsplit file.
  static BundleParts discover(String path) {
    final given = File(path);
    final numbered = RegExp(r'^(.*)\.(\d{3})$').firstMatch(path);
    String base;
    if (given.existsSync() && numbered != null) {
      base = numbered.group(1)!;
    } else if (given.existsSync()) {
      return BundleParts._([given], [given.lengthSync()], _sidecar(path));
    } else if (File(partName(path, 0)).existsSync()) {
      base = path;
    } else {
      throw CarryException.coded(
        'parts.not_found',
        params: {'path': path, 'first': partName(path, 0)},
        exitCode: exitUsage,
      );
    }
    final files = <File>[];
    while (File(partName(base, files.length)).existsSync()) {
      files.add(File(partName(base, files.length)));
    }
    if (files.isEmpty) {
      throw CarryException.coded(
        'parts.first_missing',
        params: {'name': p.basename(partName(base, 0))},
        exitCode: exitUsage,
      );
    }
    final checksums = _sidecar(base);
    final dir = Directory(p.dirname(base));
    final prefix = '${p.basename(base)}.';
    for (final entity in dir.listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      final m = RegExp('^${RegExp.escape(prefix)}(\\d{3})\$').firstMatch(name);
      if (m != null) {
        final index = int.parse(m.group(1)!);
        if (index >= files.length) {
          throw CarryException.coded(
            'parts.gap',
            params: {
              'name': p.basename(partName(base, files.length)),
              'found': p.basename(entity.path),
            },
            exitCode: exitUsage,
          );
        }
      }
    }
    for (final listed in checksums.keys) {
      if (!File(p.join(p.dirname(base), listed)).existsSync()) {
        throw CarryException.coded(
          'parts.listed_missing',
          params: {'name': listed, 'list': p.basename(checksumPath(base))},
          exitCode: exitUsage,
        );
      }
    }
    return BundleParts._(files, [
      for (final f in files) f.lengthSync(),
    ], checksums);
  }

  static Map<String, String> _sidecar(String base) {
    final file = File(checksumPath(base));
    return file.existsSync() ? readChecksumFile(file) : {};
  }

  /// Names of the parts that contain stream bytes `[start, end]`.
  List<int> partIndexesCovering(int start, int end) {
    final result = <int>[];
    var offset = 0;
    for (var i = 0; i < files.length; i++) {
      final partEnd = offset + sizes[i];
      if (start < partEnd && end >= offset) result.add(i);
      offset = partEnd;
    }
    if (result.isEmpty && files.isNotEmpty) result.add(files.length - 1);
    return result;
  }

  /// Human readable explanation for a problem at stream bytes
  /// `[start, end]`: which part holds the data and whether its checksum
  /// differs from the `.sha256` list (only those parts are re-hashed).
  String describeProblem(int start, int end) {
    final msg = describeProblemMsg(start, end);
    return tr('en', msg.code, msg.params);
  }

  /// Same as [describeProblem], as a translatable message.
  Msg describeProblemMsg(int start, int end) {
    final names = <String>[];
    final damaged = <String>[];
    var unchecked = false;
    for (final i in partIndexesCovering(start, end)) {
      final name = p.basename(files[i].path);
      names.add(name);
      final expected = checksums[name];
      if (expected == null) {
        unchecked = true;
      } else if (hashFile(files[i]) != expected) {
        damaged.add(name);
      }
    }
    final params = {'parts': names.join(', '), 'damaged': damaged.join(', ')};
    if (damaged.isNotEmpty) {
      return Msg(
        damaged.length == 1 ? 'problem.damaged_one' : 'problem.damaged_many',
        params,
      );
    }
    if (unchecked) return Msg('problem.unchecked', params);
    return Msg('problem.exported_bad', params);
  }
}

/// Reads the parts of a bundle one after another as a single stream.
class PartsReader implements ByteSource {
  /// Reads [parts] sequentially.
  PartsReader(this.parts);

  /// The parts.
  final BundleParts parts;

  int _index = 0;
  RandomAccessFile? _raf;

  @override
  int read(Uint8List buffer, int start, int length) {
    while (true) {
      if (_raf == null) {
        if (_index >= parts.files.length) return 0;
        _raf = parts.files[_index].openSync();
      }
      final n = _raf!.readIntoSync(buffer, start, start + length);
      if (n > 0) return n;
      _raf!.closeSync();
      _raf = null;
      _index++;
    }
  }

  /// Closes the open part, if any.
  void close() {
    _raf?.closeSync();
    _raf = null;
  }
}
