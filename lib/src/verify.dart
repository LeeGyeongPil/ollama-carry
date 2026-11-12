import 'dart:convert';
import 'dart:io';

import 'digest.dart';
import 'errors.dart';
import 'i18n.dart';
import 'manifest.dart';
import 'store.dart';

/// Result for one blob.
class VerifyEntry {
  /// Creates an entry.
  VerifyEntry(
    this.digest,
    this.size,
    this.status,
    this.models,
    this.detail, {
    this.detailMsg,
  });

  /// Translatable form of [detail] (null when ok).
  final Msg? detailMsg;

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
  VerifyReport(
    this.entries,
    this.invalidManifests, {
    this.invalidManifestMsgs = const {},
  });

  /// Translatable forms of [invalidManifests] reasons (same keys; a missing
  /// key means the reason is a plain English text).
  final Map<String, Object> invalidManifestMsgs;

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

  /// Plain text report in [lang] (`en` or `ko`).
  String toText({String lang = 'en'}) {
    final lines = <String>[];
    for (final e in entries) {
      final text = e.detailMsg == null
          ? e.detail
          : tr(lang, e.detailMsg!.code, e.detailMsg!.params);
      final detail = text.isEmpty ? '' : ' ($text)';
      lines.add(
        '${tr(lang, 'status.${e.status}').padRight(8)} '
        '${shortDigest(e.digest)}  '
        '${formatBytes(e.size)}  ${e.models.join(', ')}$detail',
      );
    }
    invalidManifests.forEach((name, why) {
      final msg = invalidManifestMsgs[name];
      final reason = msg is Msg ? tr(lang, msg.code, msg.params) : why;
      lines.add(tr(lang, 'verify.invalid', {'name': name, 'why': reason}));
    });
    lines
      ..add(tr(lang, 'verify.sum_ok', {'count': okCount}))
      ..add(tr(lang, 'verify.sum_missing', {'count': missingCount}))
      ..add(tr(lang, 'verify.sum_corrupt', {'count': corruptCount}));
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
  final invalidMsgs = <String, Object>{};
  for (final ref in refs) {
    final Manifest manifest;
    try {
      manifest = store.readManifest(ref);
    } on CarryException catch (e) {
      invalid[ref.display] = e.message;
      if (e.code != null) invalidMsgs[ref.display] = Msg(e.code!, e.params);
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
          detailMsg: Msg('verify.d_missing', {'path': store.blobsDir.path}),
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
          detailMsg: Msg('verify.d_size', {
            'actual': file.lengthSync(),
            'expected': size,
          }),
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
          detailMsg: const Msg('verify.d_hash'),
        ),
      );
    } else {
      entries.add(VerifyEntry(digest, size, 'ok', names, ''));
    }
    log?.call('  checked ${shortDigest(digest)}');
  }
  return VerifyReport(entries, invalid, invalidManifestMsgs: invalidMsgs);
}
