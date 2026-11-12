import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'errors.dart';

/// Chunk size for every streaming read, hash and copy (1 MiB).
const int chunkSize = 1024 * 1024;

final RegExp _digestPattern = RegExp(r'^sha256[:-]([0-9a-fA-F]{64})$');

/// Returns true if [raw] looks like `sha256:<64 hex>` or `sha256-<64 hex>`.
bool isDigest(String raw) => _digestPattern.hasMatch(raw);

/// Normalizes a digest to the manifest form `sha256:<lowercase hex>`.
String normalizeDigest(String raw) {
  final match = _digestPattern.firstMatch(raw);
  if (match == null) {
    throw CarryException.coded('digest.invalid', params: {'raw': raw});
  }
  return 'sha256:${match.group(1)!.toLowerCase()}';
}

/// The 64 hex characters of a normalized [digest].
String digestHex(String digest) => digest.substring('sha256:'.length);

/// On-disk blob file name (`sha256-<hex>`; `:` is not allowed on Windows).
String blobFileName(String digest) => 'sha256-${digestHex(digest)}';

/// Shortened digest for log lines.
String shortDigest(String digest) =>
    'sha256:${digestHex(digest).substring(0, 12)}...';

class _DigestCapture implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Incremental SHA-256 (synchronous, memory use is constant).
class Sha256Stream {
  /// Starts a new hash.
  Sha256Stream() {
    _input = sha256.startChunkedConversion(_capture);
  }

  final _DigestCapture _capture = _DigestCapture();
  late final ByteConversionSink _input;

  /// Feeds [chunk] into the hash.
  void add(List<int> chunk) => _input.add(chunk);

  /// Finishes and returns the lowercase hex digest.
  String close() {
    _input.close();
    return _capture.value.toString();
  }
}

/// SHA-256 of an in-memory byte list, as lowercase hex.
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// SHA-256 of a file read in [chunkSize] pieces, as lowercase hex.
String hashFile(File file, {void Function(int bytes)? onBytes}) {
  final hash = Sha256Stream();
  final raf = file.openSync();
  try {
    final buffer = Uint8List(chunkSize);
    while (true) {
      final n = raf.readIntoSync(buffer);
      if (n == 0) break;
      hash.add(Uint8List.sublistView(buffer, 0, n));
      onBytes?.call(n);
    }
  } finally {
    raf.closeSync();
  }
  return hash.close();
}

/// Human readable byte count (`1.5 MiB`).
String formatBytes(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0 ? '$bytes B' : '${value.toStringAsFixed(1)} ${units[unit]}';
}
