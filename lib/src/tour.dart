import 'dart:io';

import 'package:path/path.dart' as p;

import 'digest.dart';
import 'errors.dart';
import 'export.dart';
import 'import.dart';
import 'mock.dart';
import 'store.dart';
import 'verify.dart';

/// Shows the whole flow on practice (mock) data inside a temporary folder:
/// mock store, export in parts, import, verify, tamper, verify again, and a
/// damaged part being refused. The temporary folder is always deleted.
/// Works without a network and without Ollama.
void runTour(void Function(String line) out, {Directory? tempParent}) {
  final parent = tempParent ?? Directory.systemTemp;
  final root = parent.createTempSync('ollama-carry-tour-');
  try {
    out(
      'tour: practice (mock) models, fake weights - `ollama run` would not '
      'work on them',
    );
    final src = ModelStore(Directory(p.join(root.path, 'source')));
    final dst = ModelStore(Directory(p.join(root.path, 'target')));
    final bundle = p.join(root.path, 'usb', 'demo.carry.tar');

    out('\n1. create a mock models folder');
    createMockStore(src.root);
    for (final ref in src.listModels()) {
      out('   ${ref.display}  ${formatBytes(src.readManifest(ref).totalSize)}');
    }

    out('\n2. export tiny:latest and tiny:chat in 512K parts');
    final exported = exportModels(
      src,
      ['tiny:latest', 'tiny:chat'],
      output: bundle,
      splitSize: 512 * 1024,
    );
    out(
      '   ${exported.parts.length} parts, ${exported.blobCount} unique '
      'blobs, shared blobs stored once (saved '
      '${formatBytes(exported.savedBytes)})',
    );

    out('\n3. import into an empty folder (first part is enough)');
    final first = importBundle(dst, '$bundle.000');
    out(
      '   blobs: written ${first.blobsToWrite}, skipped '
      '${first.blobsSkipped}',
    );
    final again = importBundle(dst, '$bundle.000');
    out(
      '   again: written ${again.blobsToWrite}, skipped '
      '${again.blobsSkipped}',
    );

    out('\n4. verify the installed copy');
    final good = verifyStore(dst);
    out(
      '   ok: ${good.okCount}, missing: ${good.missingCount}, '
      'corrupt: ${good.corruptCount}',
    );

    out('\n5. damage one byte of a blob, then verify');
    final victim = good.entries.first;
    final file = dst.findBlob(victim.digest)!;
    final raf = file.openSync(mode: FileMode.append)..writeByteSync(0);
    raf.closeSync();
    final bad = verifyStore(dst);
    out(
      '   ok: ${bad.okCount}, missing: ${bad.missingCount}, '
      'corrupt: ${bad.corruptCount}',
    );

    out('\n6. damage one byte inside a part, then import elsewhere');
    final part = File('$bundle.001');
    final bytes = part.readAsBytesSync();
    bytes[bytes.length ~/ 2] ^= 0xFF;
    part.writeAsBytesSync(bytes);
    final other = ModelStore(Directory(p.join(root.path, 'other')));
    try {
      importBundle(other, '$bundle.000');
      throw CarryException('tour failed: a damaged part was accepted');
    } on CarryException catch (e) {
      if (e.message.startsWith('tour failed')) rethrow;
      final lines = e.message.split('\n');
      out('   refused: ${lines.first.substring(0, 28)}... is damaged');
      for (final line in lines.skip(1).take(2)) {
        out('   ${line.trim()}');
      }
      final wrote =
          other.root.existsSync() &&
          other.root.listSync(recursive: true).whereType<File>().isNotEmpty;
      out('   files written to the target: ${wrote ? 'some' : 'none'}');
    }
    out('');
    out('tour: ok');
  } finally {
    root.deleteSync(recursive: true);
  }
}
