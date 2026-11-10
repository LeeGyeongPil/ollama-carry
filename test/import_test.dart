import 'dart:io';

import 'package:ollama_carry/ollama_carry.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers.dart';

/// Exports tiny:latest + tiny:chat in 64K parts and returns the first part.
String makeBundle(Directory tmp, ModelStore store) {
  final out = p.join(tmp.path, 'usb', 'b.carry.tar');
  exportModels(
    store,
    ['tiny:latest', 'tiny:chat'],
    output: out,
    splitSize: 64 * 1024,
  );
  return '$out.000';
}

void main() {
  group('roundtrip', () {
    test('import from parts, verify, same bytes, then incremental', () {
      final tmp = makeTemp();
      final src = mockStore(tmp);
      final first = makeBundle(tmp, src);
      final dstDir = Directory(p.join(tmp.path, 'dst'))..createSync();
      final dst = ModelStore(dstDir);

      final r = importBundle(dst, first);
      expect(r.blobsToWrite, greaterThan(0));
      expect(r.blobsSkipped, 0);
      expect(r.modelsNew, 2);
      expect(filesBelow(dstDir).where((f) => f.contains('staging')), isEmpty);
      expect(verifyStore(dst).isOk, isTrue);

      for (final name in ['tiny:latest', 'tiny:chat']) {
        final ref = ModelRef.parse(name);
        expect(
          dst.manifestFile(ref).readAsBytesSync(),
          src.manifestFile(ref).readAsBytesSync(),
        );
        for (final b in src.readManifest(ref).blobs) {
          expect(
            dst.findBlob(b.digest)!.readAsBytesSync(),
            src.findBlob(b.digest)!.readAsBytesSync(),
          );
        }
      }

      final again = importBundle(dst, first);
      expect(again.blobsToWrite, 0);
      expect(again.blobsSkipped, r.blobsToWrite);
      expect(again.modelsUnchanged, 2);
    });

    test('any part name finds the whole bundle', () {
      final tmp = makeTemp();
      final first = makeBundle(tmp, mockStore(tmp));
      final dst = ModelStore(Directory(p.join(tmp.path, 'dst')));
      final r = importBundle(dst, first.replaceAll('.000', '.001'));
      expect(r.modelsNew, 2);
    });

    test('dry run writes nothing and reports the work', () {
      final tmp = makeTemp();
      final first = makeBundle(tmp, mockStore(tmp));
      final dstDir = Directory(p.join(tmp.path, 'dst'))..createSync();
      final r = importBundle(ModelStore(dstDir), first, dryRun: true);
      expect(r.dryRun, isTrue);
      expect(r.blobsToWrite, greaterThan(0));
      expect(r.bytesToWrite, greaterThan(0));
      expect(filesBelow(dstDir), isEmpty);
    });

    test('CLI import and dry run output', () {
      final tmp = makeTemp();
      final first = makeBundle(tmp, mockStore(tmp));
      final dst = p.join(tmp.path, 'dst');
      final dry = cli(['import', first, '--models', dst, '--dry-run']);
      expect(dry.code, 0, reason: dry.err);
      expect(dry.out, contains('would write'));
      final real = cli(['import', first, '--models', dst]);
      expect(real.code, 0, reason: real.err);
      final second = cli(['import', first, '--models', dst]);
      expect(second.out, contains('written 0'));
      expect(second.out, contains('already installed'));
    });

    test('a missing part is reported by name', () {
      final tmp = makeTemp();
      final first = makeBundle(tmp, mockStore(tmp));
      File(first.replaceAll('.000', '.001')).deleteSync();
      final dst = ModelStore(Directory(p.join(tmp.path, 'dst')));
      expect(
        () => importBundle(dst, first),
        throwsA(
          isA<CarryException>().having(
            (e) => e.message,
            'message',
            contains('b.carry.tar.001'),
          ),
        ),
      );
    });

    test('a truncated last part is refused', () {
      final tmp = makeTemp();
      final first = makeBundle(tmp, mockStore(tmp));
      final dir = Directory(p.dirname(first));
      final last =
          dir
              .listSync()
              .map((e) => e.path)
              .where((f) => RegExp(r'\.\d{3}$').hasMatch(f))
              .toList()
            ..sort();
      final file = File(last.last);
      final bytes = file.readAsBytesSync();
      file.writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));
      final dstDir = Directory(p.join(tmp.path, 'dst'));
      expect(
        () => importBundle(ModelStore(dstDir), first),
        throwsA(isA<CarryException>()),
      );
      expect(filesBelow(dstDir), isEmpty);
    });
  });

  group('tamper', () {
    test('one changed byte: exit 1, part named, nothing written', () {
      final tmp = makeTemp();
      final first = makeBundle(tmp, mockStore(tmp));
      final damaged = first.replaceAll('.000', '.002');
      final file = File(damaged);
      final bytes = file.readAsBytesSync();
      bytes[bytes.length ~/ 2] ^= 0x01;
      file.writeAsBytesSync(bytes);

      final dst = p.join(tmp.path, 'dst');
      Directory(dst).createSync();
      final r = cli(['import', first, '--models', dst]);
      expect(r.code, 1);
      expect(r.err, matches(RegExp(r'blob sha256:[0-9a-f]{64}')));
      expect(r.err, contains('b.carry.tar.002'));
      expect(r.err, contains('does NOT match'));
      expect(
        filesBelow(Directory(dst)),
        isEmpty,
        reason: 'no blobs, no manifests, no staging folder left',
      );
    });

    test('damage is caught even when the blobs are already installed', () {
      final tmp = makeTemp();
      final first = makeBundle(tmp, mockStore(tmp));
      final dstDir = Directory(p.join(tmp.path, 'dst'))..createSync();
      importBundle(ModelStore(dstDir), first);
      final before = filesBelow(dstDir);

      final file = File(first.replaceAll('.000', '.002'));
      final bytes = file.readAsBytesSync();
      bytes[bytes.length ~/ 2] ^= 0x01;
      file.writeAsBytesSync(bytes);

      final r = cli(['import', first, '--models', dstDir.path]);
      expect(r.code, 1);
      expect(r.err, contains('b.carry.tar.002'));
      expect(filesBelow(dstDir), before, reason: 'installed files unchanged');
    });

    test('damage in the first part (headers) is refused too', () {
      final tmp = makeTemp();
      final first = makeBundle(tmp, mockStore(tmp));
      final file = File(first);
      final bytes = file.readAsBytesSync();
      bytes[600] ^= 0xFF; // inside carry.json data
      file.writeAsBytesSync(bytes);
      final dstDir = Directory(p.join(tmp.path, 'dst'))..createSync();
      final r = cli(['import', first, '--models', dstDir.path]);
      expect(r.code, 1);
      expect(filesBelow(dstDir), isEmpty);
    });
  });
}
