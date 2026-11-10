import 'dart:convert';
import 'dart:io';

import 'digest.dart';
import 'errors.dart';
import 'manifest.dart';
import 'store.dart';

/// Result for one blob.
class VerifyEntry {
  /// Creates an entry.
  VerifyEntry(this.digest, this.size, this.status, this.models, this.detail);

  /// Normalized digest.
  final String digest;

  /// Size according to the manifests.
  final int size;

  /// `ok`, `missing` or `corrupt`.
  final String status;

  /// Models that reference this blob.
  final List<String> models;

  /// Extra explanation (empty when ok).
  final String detail;
}

/// Result of checking an installed store.
class VerifyReport {
  /// Creates a report.
  VerifyReport(this.entries, this.invalidManifests);

  /// One entry per unique blob, sorted by digest.
  final List<VerifyEntry> entries;

  /// Manifests that could not be read or parsed (name to reason).
  final Map<String, String> invalidManifests;

  int _count(String status) => entries.where((e) => e.status == status).length;

  /// Number of blobs that are fine.
  int get okCount => _count('ok');

  /// Number of blobs that are not on disk.
  int get missingCount => _count('missing');

  /// Number of blobs whose content does not match the digest.
  int get corruptCount => _count('corrupt');

  /// True if nothing is wrong.
  bool get isOk =>
      missingCount == 0 && corruptCount == 0 && invalidManifests.isEmpty;

  /// Plain text report.
  String toText() {
    final lines = <String>[];
    for (final e in entries) {
      final detail = e.detail.isEmpty ? '' : ' (${e.detail})';
      lines.add(
        '${e.status.padRight(8)} ${shortDigest(e.digest)}  '
        '${formatBytes(e.size)}  ${e.models.join(', ')}$detail',
      );
    }
    invalidManifests.forEach((name, why) {
      lines.add('invalid  manifest $name: $why');
    });
    lines
      ..add('ok: $okCount')
      ..add('missing: $missingCount')
      ..add('corrupt: $corruptCount');
    return lines.join('\n');
  }

  /// JSON report (stable keys for scripts).
  String toJson() => const JsonEncoder.withIndent('  ').convert({
    'ok': isOk,
    'counts': {'ok': okCount, 'missing': missingCount, 'corrupt': corruptCount},
    'blobs': [
      for (final e in entries)
        {
          'digest': e.digest,
          'size': e.size,
          'status': e.status,
          'models': e.models,
        },
    ],
    'invalid_manifests': invalidManifests,
  });
}

/// Checks that every blob referenced by the installed manifests exists, has
/// the right size and hashes to its digest. With [models] only those models
/// are checked. Each unique blob is hashed once.
VerifyReport verifyStore(
  ModelStore store, {
  List<String> models = const [],
  void Function(String line)? log,
}) {
  final refs = models.isEmpty ? store.listModels() : store.resolveNames(models);
  final users = <String, Set<String>>{};
  final sizes = <String, int>{};
  final invalid = <String, String>{};
  for (final ref in refs) {
    final Manifest manifest;
    try {
      manifest = store.readManifest(ref);
    } on CarryException catch (e) {
      invalid[ref.display] = e.message;
      continue;
    } on FileSystemException catch (e) {
      invalid[ref.display] = e.message;
      continue;
    }
    for (final blob in manifest.blobs) {
      users.putIfAbsent(blob.digest, () => {}).add(ref.display);
      sizes[blob.digest] = blob.size;
    }
  }
  final entries = <VerifyEntry>[];
  for (final digest in (users.keys.toList()..sort())) {
    final size = sizes[digest]!;
    final names = users[digest]!.toList()..sort();
    final file = store.findBlob(digest);
    if (file == null) {
      entries.add(
        VerifyEntry(
          digest,
          size,
          'missing',
          names,
          'not in ${store.blobsDir.path}',
        ),
      );
    } else if (file.lengthSync() != size) {
      entries.add(
        VerifyEntry(
          digest,
          size,
          'corrupt',
          names,
          'size ${file.lengthSync()} but manifest says $size',
        ),
      );
    } else if ('sha256:${hashFile(file)}' != digest) {
      entries.add(
        VerifyEntry(
          digest,
          size,
          'corrupt',
          names,
          'content does not match digest',
        ),
      );
    } else {
      entries.add(VerifyEntry(digest, size, 'ok', names, ''));
    }
    log?.call('  checked ${shortDigest(digest)}');
  }
  return VerifyReport(entries, invalid);
}
