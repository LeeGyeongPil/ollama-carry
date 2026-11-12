import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'bundle.dart';
import 'digest.dart';
import 'errors.dart';
import 'i18n.dart';
import 'manifest.dart';
import 'parts.dart';
import 'store.dart';
import 'tar.dart';

/// What `exportModels` produced.
class ExportResult {
  /// Creates a result.
  const ExportResult({
    required this.parts,
    required this.models,
    required this.blobCount,
    required this.blobBytes,
    required this.savedBytes,
  });

  /// Files written (the `.sha256` list is not included).
  final List<PartInfo> parts;

  /// Number of models.
  final int models;

  /// Unique blobs in the bundle.
  final int blobCount;

  /// Bytes of unique blobs.
  final int blobBytes;

  /// Bytes saved because shared blobs are stored once.
  final int savedBytes;
}

/// Writes the named models of [store] into a bundle at [output].
///
/// The bundle is a tar stream: `carry.json`, then `manifests/...` sorted by
/// path, then `blobs/sha256-<hex>` sorted by digest. Shared blobs are stored
/// once. Each blob is hashed while it is copied; a blob that does not match
/// its digest aborts the export. With [splitSize] the stream is cut into
/// `output.000`, `output.001`, ... and `output.sha256` lists the part hashes.
ExportResult exportModels(
  ModelStore store,
  List<String> names, {
  required String output,
  int? splitSize,
  void Function(String line)? log,
  String lang = 'en',
}) {
  if (names.isEmpty) {
    throw CarryException.coded('export.no_models', exitCode: exitUsage);
  }
  final refs = store.resolveNames(names)
    ..sort((a, b) => a.entryName.compareTo(b.entryName));

  // 1. Read manifests and collect unique blobs (shared blobs once).
  final models = <IndexModel>[];
  final manifestBytes = <String, Uint8List>{};
  final blobs = <String, int>{};
  var referenced = 0;
  for (final ref in refs) {
    final bytes = store.manifestFile(ref).readAsBytesSync();
    final manifest = Manifest.parse(bytes, source: ref.display);
    manifestBytes[ref.entryName] = bytes;
    models.add(IndexModel(ref, sha256Hex(bytes), bytes.length));
    for (final blob in manifest.blobs) {
      referenced += blob.size;
      final known = blobs[blob.digest];
      if (known != null && known != blob.size) {
        throw CarryException.coded(
          'export.size_conflict',
          params: {'digest': shortDigest(blob.digest)},
        );
      }
      blobs[blob.digest] = blob.size;
    }
  }
  final sortedDigests = blobs.keys.toList()..sort();
  final sortedBlobs = {for (final d in sortedDigests) d: blobs[d]!};

  // 2. Refuse early if a blob file is missing or has the wrong size.
  for (final entry in sortedBlobs.entries) {
    final file = store.findBlob(entry.key);
    if (file == null) {
      throw CarryException.coded(
        'export.blob_missing',
        params: {'digest': entry.key, 'dir': store.blobsDir.path},
      );
    }
    if (file.lengthSync() != entry.value) {
      throw CarryException.coded(
        'export.blob_size',
        params: {
          'digest': entry.key,
          'actual': file.lengthSync(),
          'expected': entry.value,
        },
      );
    }
  }

  // 3. Never overwrite an earlier export (stale parts would be confusing).
  final dir = Directory(p.dirname(output));
  final base = p.basename(output);
  if (dir.existsSync()) {
    final taken = dir.listSync(followLinks: false).where((e) {
      final name = p.basename(e.path);
      return name == base ||
          name == '$base.sha256' ||
          RegExp('^${RegExp.escape(base)}\\.\\d{3}\$').hasMatch(name);
    });
    if (taken.isNotEmpty) {
      throw CarryException.coded(
        'export.exists',
        params: {'path': taken.first.path},
        exitCode: exitUsage,
      );
    }
  } else {
    dir.createSync(recursive: true);
  }

  // 4. Stream everything into the (split) output.
  final writer = PartsWriter(output, partSize: splitSize);
  try {
    final tar = TarWriter(writer);
    tar.addBytes('carry.json', BundleIndex(models, sortedBlobs).encode());
    for (final model in models) {
      tar.addBytes(model.ref.entryName, manifestBytes[model.ref.entryName]!);
    }
    final buffer = Uint8List(chunkSize);
    for (final entry in sortedBlobs.entries) {
      final digest = entry.key;
      tar.beginFile('blobs/${blobFileName(digest)}', entry.value);
      final hash = Sha256Stream();
      final raf = store.findBlob(digest)!.openSync();
      var copied = 0;
      try {
        while (true) {
          final n = raf.readIntoSync(buffer);
          if (n == 0) break;
          copied += n;
          if (copied > entry.value) break;
          final view = Uint8List.sublistView(buffer, 0, n);
          hash.add(view);
          tar.writeData(view);
        }
      } finally {
        raf.closeSync();
      }
      if (copied != entry.value || 'sha256:${hash.close()}' != digest) {
        throw CarryException.coded(
          'export.blob_changed',
          params: {'digest': digest},
        );
      }
      tar.endFile();
      log?.call(
        tr(lang, 'export.log_blob', {
          'digest': shortDigest(digest),
          'size': formatBytes(entry.value),
        }),
      );
    }
    tar.finish();
  } catch (_) {
    writer.abort();
    rethrow;
  }
  final parts = writer.close();
  writeChecksumFile(output, parts);
  final blobBytes = sortedBlobs.values.fold(0, (a, b) => a + b);
  return ExportResult(
    parts: parts,
    models: models.length,
    blobCount: sortedBlobs.length,
    blobBytes: blobBytes,
    savedBytes: referenced - blobBytes,
  );
}
