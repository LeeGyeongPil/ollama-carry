import 'dart:io';

import 'package:path/path.dart' as p;

import 'digest.dart';
import 'errors.dart';
import 'export.dart';
import 'i18n.dart';
import 'import.dart';
import 'mock.dart';
import 'store.dart';
import 'verify.dart';

/// Shows the whole flow on practice (mock) data inside a temporary folder:
/// mock store, export in parts, import, verify, tamper, verify again, and a
/// damaged part being refused. The temporary folder is always deleted.
/// Works without a network and without Ollama. Text is printed in [lang].
void runTour(
  void Function(String line) out, {
  Directory? tempParent,
  String lang = 'en',
}) {
  String t(String code, [Map<String, Object?> params = const {}]) =>
      tr(lang, code, params);
  final parent = tempParent ?? Directory.systemTemp;
  final root = parent.createTempSync('ollama-carry-tour-');
  try {
    out(t('tour.intro'));
    final src = ModelStore(Directory(p.join(root.path, 'source')));
    final dst = ModelStore(Directory(p.join(root.path, 'target')));
    final bundle = p.join(root.path, 'usb', 'demo.carry.tar');

    out(t('tour.s1'));
    createMockStore(src.root);
    for (final ref in src.listModels()) {
      out(
        t('tour.model', {
          'name': ref.display,
          'size': formatBytes(src.readManifest(ref).totalSize),
        }),
      );
    }

    out(t('tour.s2'));
    final exported = exportModels(
      src,
      ['tiny:latest', 'tiny:chat'],
      output: bundle,
      splitSize: 512 * 1024,
    );
    out(
      t('tour.exported', {
        'parts': exported.parts.length,
        'blobs': exported.blobCount,
        'saved': formatBytes(exported.savedBytes),
      }),
    );

    out(t('tour.s3'));
    final first = importBundle(dst, '$bundle.000');
    out(
      t('tour.imported', {
        'written': first.blobsToWrite,
        'skipped': first.blobsSkipped,
      }),
    );
    final again = importBundle(dst, '$bundle.000');
    out(
      t('tour.again', {
        'written': again.blobsToWrite,
        'skipped': again.blobsSkipped,
      }),
    );

    out(t('tour.s4'));
    final good = verifyStore(dst);
    out(
      t('tour.counts', {
        'ok': good.okCount,
        'missing': good.missingCount,
        'corrupt': good.corruptCount,
      }),
    );

    out(t('tour.s5'));
    final victim = good.entries.first;
    final file = dst.findBlob(victim.digest)!;
    final raf = file.openSync(mode: FileMode.append)..writeByteSync(0);
    raf.closeSync();
    final bad = verifyStore(dst);
    out(
      t('tour.counts', {
        'ok': bad.okCount,
        'missing': bad.missingCount,
        'corrupt': bad.corruptCount,
      }),
    );

    out(t('tour.s6'));
    final part = File('$bundle.001');
    final bytes = part.readAsBytesSync();
    bytes[bytes.length ~/ 2] ^= 0xFF;
    part.writeAsBytesSync(bytes);
    final other = ModelStore(Directory(p.join(root.path, 'other')));
    try {
      importBundle(other, '$bundle.000');
      throw CarryException.coded('tour.failed');
    } on CarryException catch (e) {
      if (e.code == 'tour.failed') rethrow;
      final lines = e.localized(lang).split('\n');
      final digest = e.params['digest'];
      if (e.code == 'import.blob_damaged' && digest is String) {
        // First 16 hex characters of the digest are enough to recognise it.
        out(t('tour.refused', {'digest': digest.substring(0, 23)}));
      } else {
        out(t('tour.refused_other', {'first': lines.first}));
      }
      for (final line in lines.skip(1).take(2)) {
        out('   ${line.trim()}');
      }
      final wrote =
          other.root.existsSync() &&
          other.root.listSync(recursive: true).whereType<File>().isNotEmpty;
      out(t('tour.files', {'value': t(wrote ? 'word.some' : 'word.none')}));
    }
    out('');
    out(t('tour.ok'));
  } finally {
    root.deleteSync(recursive: true);
  }
}
