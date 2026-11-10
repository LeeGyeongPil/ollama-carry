import 'dart:convert';
import 'dart:io';

import 'package:ollama_carry/ollama_carry.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// First blob digest of [name] that only that model needs, plus its file.
File blobOf(ModelStore store, String name, String mediaSuffix) {
  final manifest = store.readManifest(ModelRef.parse(name));
  final blob = manifest.blobs.firstWhere(
    (b) => b.mediaType.endsWith(mediaSuffix),
  );
  return store.findBlob(blob.digest)!;
}

void main() {
  group('verify', () {
    test('a clean store is ok (exit 0)', () {
      final store = mockStore(makeTemp());
      final r = cli(['verify', '--models', store.root.path]);
      expect(r.code, 0, reason: r.out);
      expect(r.out, contains('corrupt: 0'));
      expect(r.out, contains('missing: 0'));
    });

    test('one appended byte is corrupt, one deleted blob is missing', () {
      final store = mockStore(makeTemp());
      final weights = blobOf(store, 'tiny:latest', 'image.model');
      weights.writeAsBytesSync([...weights.readAsBytesSync(), 0]);
      final r = cli(['verify', '--models', store.root.path]);
      expect(r.code, 1);
      expect(r.out, contains('corrupt: 1'));

      final params = blobOf(store, 'tiny:latest', 'image.params');
      params.deleteSync();
      final r2 = cli(['verify', '--models', store.root.path]);
      expect(r2.code, 1);
      expect(r2.out, contains('missing: 1'));
      expect(r2.out, contains('corrupt: 1'));
    });

    test('same size but different content is corrupt', () {
      final store = mockStore(makeTemp());
      final weights = blobOf(store, 'tiny:latest', 'image.model');
      final bytes = weights.readAsBytesSync();
      bytes[5] ^= 0x10;
      weights.writeAsBytesSync(bytes);
      final report = verifyStore(store);
      expect(report.corruptCount, 1);
      expect(report.isOk, isFalse);
    });

    test('--json is valid JSON with status and models per digest', () {
      final store = mockStore(makeTemp());
      final weights = blobOf(store, 'tiny:latest', 'image.model');
      weights.writeAsBytesSync([...weights.readAsBytesSync(), 1]);
      final r = cli(['verify', '--json', '--models', store.root.path]);
      expect(r.code, 1);
      final json = jsonDecode(r.out) as Map<String, dynamic>;
      expect(json['ok'], isFalse);
      final blobs = (json['blobs'] as List).cast<Map<String, dynamic>>();
      final bad = blobs.where((b) => b['status'] == 'corrupt').single;
      expect(bad['models'], containsAll(['tiny:latest', 'tiny:chat']));
      expect(bad['digest'], startsWith('sha256:'));
    });

    test('naming a model checks only that model', () {
      final store = mockStore(makeTemp());
      final mini = blobOf(store, 'hf.co/demo/mini:Q4_0', 'image.model');
      mini.writeAsBytesSync([...mini.readAsBytesSync(), 9]);
      expect(cli(['verify', 'tiny', '--models', store.root.path]).code, 0);
      expect(
        cli([
          'verify',
          'hf.co/demo/mini:Q4_0',
          '--models',
          store.root.path,
        ]).code,
        1,
      );
    });

    test('an unknown model name is a usage error (exit 2)', () {
      final store = mockStore(makeTemp());
      final r = cli(['verify', 'ghost', '--models', store.root.path]);
      expect(r.code, 2);
      expect(r.err, contains('ollama-carry list'));
    });

    test(
      'blobs named sha256:<hex> are found too',
      () {
        final store = mockStore(makeTemp());
        final weights = blobOf(store, 'tiny:latest', 'image.model');
        final colon = weights.path.replaceFirstMapped(
          RegExp(r'sha256-([0-9a-f]+)$'),
          (m) => 'sha256:${m[1]}',
        );
        weights.renameSync(colon);
        expect(colon, matches(RegExp(r'sha256:[0-9a-f]{64}$')));
        expect(verifyStore(store).isOk, isTrue);
      },
      skip: Platform.isWindows
          ? 'Windows cannot create ":" in file names'
          : null,
    );
  });
}
