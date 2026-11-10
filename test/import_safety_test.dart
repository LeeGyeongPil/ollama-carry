import 'dart:convert';
import 'dart:io';

import 'package:ollama_carry/ollama_carry.dart';
import 'package:ollama_carry/src/digest.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers.dart';

/// A good unsplit bundle of tiny:latest, as a list of entries to mutate.
({Directory tmp, ModelStore src, List<Entry> entries}) setup() {
  final tmp = makeTemp();
  final src = mockStore(tmp);
  final out = p.join(tmp.path, 'good.carry.tar');
  exportModels(src, ['tiny:latest'], output: out);
  return (tmp: tmp, src: src, entries: readEntries(out));
}

/// Imports the mutated [entries]; returns the CLI result and the target dir.
({CliResult result, Directory dst}) tryImport(
  Directory tmp,
  List<Entry> entries,
) {
  final bad = p.join(tmp.path, 'bad.carry.tar');
  writeEntries(bad, entries);
  final dst = Directory(p.join(tmp.path, 'inner', 'dst'))
    ..createSync(recursive: true);
  return (result: cli(['import', bad, '--models', dst.path]), dst: dst);
}

void main() {
  group('hostile bundles are refused', () {
    void expectRefused(Directory tmp, List<Entry> entries, {String? hint}) {
      final r = tryImport(tmp, entries);
      expect(r.result.code, 1, reason: r.result.err);
      if (hint != null) expect(r.result.err, contains(hint));
      expect(filesBelow(r.dst), isEmpty, reason: 'nothing written');
      // Nothing escaped next to the target either.
      expect(File(p.join(tmp.path, 'inner', 'evil')).existsSync(), isFalse);
      expect(File(p.join(tmp.path, 'evil')).existsSync(), isFalse);
    }

    test('path traversal in a blob name', () {
      final s = setup();
      final blob = s.entries.firstWhere((e) => e.name.startsWith('blobs/'));
      blob.name = '../evil';
      expectRefused(s.tmp, s.entries, hint: 'unexpected entry');
    });

    test('absolute path', () {
      final s = setup();
      s.entries.last.name = '/abs';
      expectRefused(s.tmp, s.entries, hint: 'unexpected entry');
    });

    test('manifest path with the wrong number of parts', () {
      final s = setup();
      final manifest = s.entries.firstWhere(
        (e) => e.name.startsWith('manifests/'),
      );
      manifest.name = 'manifests/a/b';
      expectRefused(s.tmp, s.entries);
    });

    test('blob name that is not sha256-<64 hex>', () {
      final s = setup();
      final blob = s.entries.firstWhere((e) => e.name.startsWith('blobs/'));
      blob.name = 'blobs/sha256-xyz';
      expectRefused(s.tmp, s.entries, hint: 'unexpected entry');
    });

    test('upper-case hex in a blob name is not accepted', () {
      final s = setup();
      final blob = s.entries.firstWhere((e) => e.name.startsWith('blobs/'));
      blob.name = blob.name.toUpperCase().replaceFirst('BLOBS/', 'blobs/');
      expectRefused(s.tmp, s.entries);
    });

    test('symbolic and hard link entries', () {
      for (final type in ['2', '1']) {
        final s = setup();
        s.entries.insert(1, Entry('manifests/a/b/c/d', [], type: type));
        expectRefused(s.tmp, s.entries, hint: 'not a plain file');
      }
    });

    test('carry.json size that does not match the blob entry', () {
      final s = setup();
      final json = jsonDecode(utf8.decode(s.entries.first.data)) as Map;
      final blobs = json['blobs'] as List;
      (blobs.first as Map)['size'] = (blobs.first as Map)['size'] + 1;
      s.entries.first.data = utf8.encode(jsonEncode(json));
      expectRefused(s.tmp, s.entries);
    });

    test('carry.json manifest sha256 that does not match', () {
      final s = setup();
      final json = jsonDecode(utf8.decode(s.entries.first.data)) as Map;
      final models = json['models'] as List;
      (models.first as Map)['sha256'] = sha256Hex(utf8.encode('other'));
      s.entries.first.data = utf8.encode(jsonEncode(json));
      expectRefused(s.tmp, s.entries, hint: 'does not match carry.json');
    });

    test('bundle without carry.json first', () {
      final s = setup();
      s.entries.removeAt(0);
      expectRefused(s.tmp, s.entries, hint: 'carry.json');
    });

    test('a blob that is listed but missing from the bundle', () {
      final s = setup();
      final index = s.entries.indexWhere((e) => e.name.startsWith('blobs/'));
      s.entries.removeAt(index);
      expectRefused(s.tmp, s.entries, hint: 'incomplete');
    });

    test('blob whose content does not match its name', () {
      final s = setup();
      final blob = s.entries.firstWhere((e) => e.name.startsWith('blobs/'));
      blob.data = List<int>.of(blob.data)..[0] ^= 1;
      expectRefused(s.tmp, s.entries, hint: 'damaged');
    });
  });

  group('name conflicts', () {
    test(
      'a different manifest with the same name: exit 3, --force replaces',
      () {
        final s = setup();
        final good = p.join(s.tmp.path, 'good.carry.tar');
        final dstDir = Directory(p.join(s.tmp.path, 'dst'));
        final dst = ModelStore(dstDir);
        importBundle(dst, good);

        // Make the installed manifest differ (different formatting, same JSON).
        final ref = ModelRef.parse('tiny:latest');
        final file = dst.manifestFile(ref);
        file.writeAsStringSync('${file.readAsStringSync()}\n');
        final before = filesBelow(dstDir);

        final blocked = cli(['import', good, '--models', dstDir.path]);
        expect(blocked.code, 3, reason: blocked.err);
        expect(blocked.err, contains('--force'));
        expect(filesBelow(dstDir), before);
        expect(file.readAsStringSync().endsWith('\n'), isTrue);

        final forced = cli([
          'import',
          good,
          '--models',
          dstDir.path,
          '--force',
        ]);
        expect(forced.code, 0, reason: forced.err);
        expect(
          file.readAsBytesSync(),
          s.src.manifestFile(ref).readAsBytesSync(),
        );
      },
    );

    test('importing the same bundle twice is not a conflict', () {
      final s = setup();
      final good = p.join(s.tmp.path, 'good.carry.tar');
      final dstDir = Directory(p.join(s.tmp.path, 'dst'));
      expect(cli(['import', good, '--models', dstDir.path]).code, 0);
      expect(cli(['import', good, '--models', dstDir.path]).code, 0);
    });
  });
}
