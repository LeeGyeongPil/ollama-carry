import 'dart:convert';
import 'dart:io';

import 'package:ollama_carry/ollama_carry.dart';
import 'package:ollama_carry/src/digest.dart';
import 'package:ollama_carry/src/parts.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('export', () {
    test('split bundle: shared blob once, part limits, checksums, bytes', () {
      final tmp = makeTemp();
      final store = mockStore(tmp);
      final out = p.join(tmp.path, 'usb', 'b.carry.tar');
      final r = exportModels(
        store,
        ['tiny:latest', 'tiny:chat'],
        output: out,
        splitSize: 128 * 1024,
      );
      expect(r.parts.length, greaterThan(1));
      for (final part in r.parts) {
        expect(File(part.path).lengthSync(), lessThanOrEqualTo(128 * 1024));
      }
      expect(File('$out.000').existsSync(), isTrue);

      // The union of both manifests' digests = blobs in the bundle.
      final digests = <String>{};
      for (final name in ['tiny:latest', 'tiny:chat']) {
        final m = store.readManifest(ModelRef.parse(name));
        digests.addAll(m.blobs.map((b) => b.digest));
      }
      final entries = readEntries(out);
      expect(entries.first.name, 'carry.json');
      final blobEntries = entries
          .where((e) => e.name.startsWith('blobs/'))
          .toList();
      expect(blobEntries.length, digests.length);
      expect(
        blobEntries.map((e) => e.name).toSet().length,
        blobEntries.length,
        reason: 'no blob is stored twice',
      );
      expect(r.savedBytes, greaterThan(0));
      final json = jsonDecode(utf8.decode(entries.first.data)) as Map;
      expect((json['blobs'] as List).length, digests.length);

      // .sha256 lines match the real part hashes (sha256sum format).
      final sums = readChecksumFile(File('$out.sha256'));
      expect(sums.length, r.parts.length);
      for (final part in r.parts) {
        expect(sums[p.basename(part.path)], hashFile(File(part.path)));
      }

      // Same bytes as an unsplit export; and exporting twice is identical.
      final whole = p.join(tmp.path, 'whole.carry.tar');
      exportModels(store, ['tiny:latest', 'tiny:chat'], output: whole);
      expect(joinParts(out), File(whole).readAsBytesSync());
      final again = p.join(tmp.path, 'again.carry.tar');
      exportModels(store, ['tiny:chat', 'tiny:latest'], output: again);
      expect(File(again).readAsBytesSync(), File(whole).readAsBytesSync());
    });

    test('unknown model and missing names give clear errors', () {
      final tmp = makeTemp();
      final store = mockStore(tmp);
      expect(
        () => exportModels(store, [
          'nope',
        ], output: p.join(tmp.path, 'x.carry.tar')),
        throwsA(
          isA<CarryException>().having((e) => e.exitCode, 'exit', exitUsage),
        ),
      );
      expect(
        () => exportModels(store, [], output: p.join(tmp.path, 'x')),
        throwsA(isA<CarryException>()),
      );
    });

    test('refuses to overwrite an earlier export', () {
      final tmp = makeTemp();
      final store = mockStore(tmp);
      final out = p.join(tmp.path, 'b.carry.tar');
      exportModels(store, ['tiny'], output: out);
      expect(
        () => exportModels(store, ['tiny'], output: out),
        throwsA(
          isA<CarryException>().having(
            (e) => e.message,
            'message',
            contains('already exists'),
          ),
        ),
      );
    });

    test('a corrupt source blob aborts and leaves no partial files', () {
      final tmp = makeTemp();
      final store = mockStore(tmp);
      final manifest = store.readManifest(ModelRef.parse('tiny'));
      final weights = manifest.blobs.firstWhere(
        (b) => b.mediaType.endsWith('image.model'),
      );
      final file = store.findBlob(weights.digest)!;
      final bytes = file.readAsBytesSync();
      bytes[10] ^= 1;
      file.writeAsBytesSync(bytes);
      final out = p.join(tmp.path, 'out', 'b.carry.tar');
      expect(
        () => exportModels(store, ['tiny'], output: out, splitSize: 64 * 1024),
        throwsA(isA<CarryException>()),
      );
      expect(filesBelow(Directory(p.dirname(out))), isEmpty);
    });

    test('CLI export prints parts, checksum list and saved bytes', () {
      final tmp = makeTemp();
      final store = mockStore(tmp);
      final out = p.join(tmp.path, 'c.carry.tar');
      final r = cli([
        'export',
        'tiny:latest',
        'tiny:chat',
        '-o',
        out,
        '--split',
        '100K',
        '--models',
        store.root.path,
      ]);
      expect(r.code, 0, reason: r.err);
      expect(r.out, contains('c.carry.tar.000'));
      expect(r.out, contains('c.carry.tar.sha256'));
      expect(r.out, contains('sharing saved'));
    });

    test('size parsing', () {
      expect(parseSize('512K'), 512 * 1024);
      expect(parseSize('3.9G'), (3.9 * 1024 * 1024 * 1024).floor());
      expect(parseSize('1048576'), 1048576);
      expect(parseSize('fat32'), lessThan(4 * 1024 * 1024 * 1024));
      expect(() => parseSize('abc'), throwsA(isA<CarryException>()));
      expect(() => parseSize('10'), throwsA(isA<CarryException>()));
    });
  });
}
