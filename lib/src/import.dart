import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'bundle.dart';
import 'digest.dart';
import 'errors.dart';
import 'i18n.dart';
import 'manifest.dart';
import 'model_ref.dart';
import 'parts.dart';
import 'store.dart';
import 'tar.dart';

const int _maxIndexBytes = 64 * 1024 * 1024;
const int _maxManifestBytes = 4 * 1024 * 1024;

final RegExp _blobEntry = RegExp(r'^blobs/sha256-([0-9a-f]{64})$');

/// What `importBundle` did (or would do with `dryRun`).
class ImportReport {
  /// Creates a report.
  ImportReport({
    required this.dryRun,
    required this.blobsToWrite,
    required this.blobsSkipped,
    required this.bytesToWrite,
    required this.modelsNew,
    required this.modelsUnchanged,
    required this.modelsOverwritten,
    required this.modelNames,
  });

  /// True if nothing was written.
  final bool dryRun;

  /// Blobs written (or that would be written).
  final int blobsToWrite;

  /// Blobs already installed and therefore skipped.
  final int blobsSkipped;

  /// Bytes of the blobs written (or that would be written).
  final int bytesToWrite;

  /// Manifests that did not exist before.
  final int modelsNew;

  /// Manifests that already existed with identical content.
  final int modelsUnchanged;

  /// Manifests replaced because of `--force`.
  final int modelsOverwritten;

  /// Display names of the models in the bundle.
  final List<String> modelNames;
}

/// Installs the models of a bundle into [store].
///
/// Safety rules: only `carry.json`, `manifests/<4 parts>` and
/// `blobs/sha256-<hex>` entries are accepted (no links, no `..`); each blob is
/// hashed while it is unpacked into a staging folder inside the models
/// folder; nothing is moved into place unless every blob matches its digest;
/// blobs are placed first and manifests last, so `ollama list` never shows a
/// half installed model. Blobs that are already installed are skipped.
ImportReport importBundle(
  ModelStore store,
  String bundlePath, {
  bool dryRun = false,
  bool force = false,
  void Function(String line)? log,
  String lang = 'en',
}) {
  final parts = BundleParts.discover(bundlePath);
  final reader = PartsReader(parts);
  final tar = TarReader(reader);
  Directory? staging;
  try {
    // 1. The index comes first.
    final first = _guard(parts, tar.nextEntry);
    if (first == null || first.name != 'carry.json' || !first.isRegular) {
      throw CarryException.coded('import.not_bundle');
    }
    if (first.size > _maxIndexBytes) {
      throw CarryException.coded('import.index_large');
    }
    final index = BundleIndex.parse(_guard(parts, tar.readAll));

    // 2. Decide what is new, unchanged or in conflict before reading blobs.
    var modelsNew = 0;
    var modelsUnchanged = 0;
    final conflicts = <String>[];
    final overwrite = <String>{};
    for (final model in index.models) {
      final file = store.manifestFile(model.ref);
      if (!file.existsSync()) {
        modelsNew++;
      } else if (sha256Hex(file.readAsBytesSync()) == model.sha256) {
        modelsUnchanged++;
      } else {
        conflicts.add(model.ref.display);
        overwrite.add(model.ref.entryName);
      }
    }
    if (conflicts.isNotEmpty && !force) {
      throw CarryException.coded(
        'import.conflicts',
        params: {'names': conflicts.join(', ')},
        exitCode: exitConflict,
      );
    }
    final present = <String>{};
    var bytesToWrite = 0;
    for (final blob in index.blobs.entries) {
      final existing = store.findBlob(blob.key);
      if (existing != null && existing.lengthSync() == blob.value) {
        present.add(blob.key);
      } else {
        bytesToWrite += blob.value;
      }
    }
    final names = [for (final m in index.models) m.ref.display];
    ImportReport report() => ImportReport(
      dryRun: dryRun,
      blobsToWrite: index.blobs.length - present.length,
      blobsSkipped: present.length,
      bytesToWrite: bytesToWrite,
      modelsNew: modelsNew,
      modelsUnchanged: modelsUnchanged,
      modelsOverwritten: overwrite.length,
      modelNames: names,
    );
    if (dryRun) return report();

    // 3. Unpack into staging, hashing every blob on the way.
    staging = Directory(p.join(store.root.path, '.carry-staging-$pid'))
      ..createSync(recursive: true);
    final stagedBlobs = <String>[];
    final manifests = <String, Uint8List>{};
    final seen = <String>{};
    while (true) {
      final entry = _guard(parts, tar.nextEntry);
      if (entry == null) break;
      if (!entry.isRegular) {
        throw CarryException.coded(
          'import.not_plain',
          params: {'name': entry.name, 'type': entry.typeFlag},
        );
      }
      if (!seen.add(entry.name)) {
        throw CarryException.coded(
          'import.duplicate',
          params: {'name': entry.name},
        );
      }
      if (entry.name.startsWith('manifests/')) {
        final ref = ModelRef.fromEntryName(entry.name);
        final model = index.models.where((m) => m.ref == ref).firstOrNull;
        if (model == null || entry.size > _maxManifestBytes) {
          throw CarryException.coded(
            'import.manifest_unlisted',
            params: {'name': entry.name},
          );
        }
        final bytes = _guard(parts, tar.readAll);
        if (bytes.length != model.size || sha256Hex(bytes) != model.sha256) {
          throw CarryException.coded(
            'import.manifest_mismatch',
            params: {'name': entry.name},
          );
        }
        Manifest.parse(bytes, source: entry.name);
        manifests[entry.name] = bytes;
        continue;
      }
      final match = _blobEntry.firstMatch(entry.name);
      if (match == null) {
        throw CarryException.coded(
          'import.unexpected_entry',
          params: {'name': entry.name},
        );
      }
      final digest = 'sha256:${match.group(1)}';
      final expectedSize = index.blobs[digest];
      if (expectedSize == null || expectedSize != entry.size) {
        throw CarryException.coded(
          'import.blob_unlisted',
          params: {
            'name': entry.name,
            'actual': entry.size,
            'expected': expectedSize ?? 'n/a',
          },
        );
      }
      final installed = present.contains(digest);
      final start = tar.position;
      // Blobs that are already installed are not rewritten, but the bundle's
      // copy is still hashed so a damaged part is never reported as fine.
      final out = installed
          ? null
          : File(
              p.join(staging.path, blobFileName(digest)),
            ).openSync(mode: FileMode.writeOnly);
      final hash = Sha256Stream();
      try {
        _guard(parts, () {
          tar.readData((chunk) {
            hash.add(chunk);
            out?.writeFromSync(chunk);
          });
        });
      } finally {
        out?.closeSync();
      }
      final actual = 'sha256:${hash.close()}';
      if (actual != digest) {
        throw CarryException.coded(
          'import.blob_damaged',
          params: {
            'digest': digest,
            'actual': actual,
            'where': parts.describeProblemMsg(start, tar.position - 1),
            'path': store.root.path,
          },
        );
      }
      if (installed) {
        log?.call(tr(lang, 'import.log_skip', {'digest': shortDigest(digest)}));
        continue;
      }
      stagedBlobs.add(digest);
      log?.call(
        tr(lang, 'import.log_hash', {
          'digest': shortDigest(digest),
          'size': formatBytes(entry.size),
        }),
      );
    }

    // 4. The bundle must be complete and self-consistent.
    for (final model in index.models) {
      if (!manifests.containsKey(model.ref.entryName)) {
        throw CarryException.coded(
          'import.incomplete_manifest',
          params: {'name': model.ref.display},
        );
      }
    }
    for (final digest in index.blobs.keys) {
      if (!present.contains(digest) && !stagedBlobs.contains(digest)) {
        throw CarryException.coded(
          'import.incomplete_blob',
          params: {'digest': digest},
        );
      }
    }
    for (final entry in manifests.entries) {
      for (final blob in Manifest.parse(entry.value).blobs) {
        if (index.blobs[blob.digest] != blob.size) {
          throw CarryException.coded(
            'import.ref_mismatch',
            params: {'manifest': entry.key, 'digest': blob.digest},
          );
        }
      }
    }

    // 5. Commit: blobs first, manifests last.
    store.blobsDir.createSync(recursive: true);
    for (final digest in stagedBlobs) {
      final target = store.blobFile(digest);
      final source = File(p.join(staging.path, blobFileName(digest)));
      if (target.existsSync()) continue;
      _move(source, target);
    }
    var counter = 0;
    for (final entry in manifests.entries) {
      final ref = ModelRef.fromEntryName(entry.key);
      final target = store.manifestFile(ref);
      final temp = File(p.join(staging.path, 'manifest-${counter++}'))
        ..writeAsBytesSync(entry.value, flush: true);
      target.parent.createSync(recursive: true);
      if (target.existsSync()) target.deleteSync();
      _move(temp, target);
    }
    return report();
  } finally {
    reader.close();
    if (staging != null && staging.existsSync()) {
      try {
        staging.deleteSync(recursive: true);
      } on FileSystemException {
        // Leaving a stale staging folder is harmless; it is not a model.
      }
    }
  }
}

/// Runs a tar read; a damaged stream reports which part is affected.
T _guard<T>(BundleParts parts, T Function() read) {
  try {
    return read();
  } on TarFormatException catch (e) {
    throw CarryException.coded(
      'import.tar',
      params: {
        'problem': e.asMsg(),
        'offset': e.offset,
        'where': parts.describeProblemMsg(e.offset, e.offset),
      },
    );
  }
}

/// Moves a file; falls back to copy + size check when rename is not possible
/// (different volume).
void _move(File source, File target) {
  try {
    source.renameSync(target.path);
  } on FileSystemException {
    source.copySync(target.path);
    if (target.lengthSync() != source.lengthSync()) {
      target.deleteSync();
      throw CarryException.coded(
        'import.copy_incomplete',
        params: {'path': target.path},
      );
    }
    source.deleteSync();
  }
}
