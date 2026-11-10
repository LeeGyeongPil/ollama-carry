import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('mock + list', () {
    test('mock creates three models and list prints them sorted', () {
      final tmp = makeTemp();
      final dir = p.join(tmp.path, 'm');
      final made = cli(['mock', dir, '--weights-size', '64K']);
      expect(made.code, 0, reason: made.err);
      expect(made.out, contains('practice (mock)'));

      final listed = cli(['list', '--models', dir]);
      expect(listed.code, 0, reason: listed.err);
      final lines = listed.out.trim().split('\n');
      expect(lines[0], startsWith('hf.co/demo/mini:Q4_0'));
      expect(lines[1], startsWith('tiny:chat'));
      expect(lines[2], startsWith('tiny:latest'));
      expect(lines[0], matches(RegExp(r'\d+(\.\d)? (KiB|MiB|B)$')));
      expect(lines[3], contains('shared blobs counted once'));
    });

    test('blobs are stored as sha256-<64 hex> files', () {
      final store = mockStore(makeTemp());
      final names = Directory(
        store.blobsDir.path,
      ).listSync().map((e) => p.basename(e.path)).toList();
      expect(names, isNotEmpty);
      for (final name in names) {
        expect(name, matches(RegExp(r'^sha256-[0-9a-f]{64}$')));
      }
    });

    test('mock refuses a folder that already has models', () {
      final tmp = makeTemp();
      final dir = p.join(tmp.path, 'm');
      expect(cli(['mock', dir]).code, 0);
      final again = cli(['mock', dir]);
      expect(again.code, 2);
      expect(again.err, contains('already contains models'));
    });

    test('list on an empty folder says where to look', () {
      final tmp = makeTemp();
      final r = cli(['list', '--models', p.join(tmp.path, 'none')]);
      expect(r.code, 0);
      expect(r.out, contains('ollama-carry where'));
    });

    test('where reports the folder and why', () {
      final tmp = makeTemp();
      final r = cli(
        ['where'],
        environment: {'OLLAMA_MODELS': tmp.path, 'HOME': tmp.path},
      );
      expect(r.code, 0);
      expect(r.out, contains(tmp.path));
      expect(r.out, contains('OLLAMA_MODELS'));
    });

    test('unknown command and no arguments are usage errors', () {
      expect(cli(['frobnicate']).code, 2);
      expect(cli([]).code, 2);
      expect(cli(['export', 'tiny']).code, 2); // missing -o
    });
  });
}
