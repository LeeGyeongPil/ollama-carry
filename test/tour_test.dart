import 'dart:io';

import 'package:ollama_carry/src/tour.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('tour', () {
    test('runs the whole flow, ends with tour: ok and exit 0', () {
      final r = cli(['tour']);
      expect(r.code, 0, reason: r.err);
      expect(r.out, contains('practice (mock)'));
      expect(r.out, contains('corrupt: 1'));
      expect(r.out, contains('written 0'));
      expect(r.out.trim().split('\n').last, 'tour: ok');
    });

    test('removes its temporary folder and writes only there', () {
      final parent = makeTemp();
      final lines = <String>[];
      runTour(lines.add, tempParent: parent);
      expect(lines.last, 'tour: ok');
      expect(parent.listSync(), isEmpty);
    });

    test('does not create files in the working directory', () {
      final before = Directory.current.listSync().map((e) => e.path).toSet();
      cli(['tour']);
      final after = Directory.current.listSync().map((e) => e.path).toSet();
      expect(after, before);
    });
  });
}
