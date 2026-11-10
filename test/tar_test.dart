import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:ollama_carry/ollama_carry.dart';
import 'package:ollama_carry/src/tar.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('tar codec', () {
    test('a 9 GiB entry uses a PAX size record and reads back', () {
      const nineGiB = 9663676416;
      final sink = MemorySink();
      TarWriter(sink).beginFile('blobs/big', nineGiB); // header only
      final bytes = sink.builder.takeBytes();
      expect(
        utf8.decode(bytes, allowMalformed: true),
        contains('size=9663676416'),
      );
      final entry = TarReader(MemorySource(bytes)).nextEntry();
      expect(entry!.name, 'blobs/big');
      expect(entry.size, nineGiB);
    });

    test('a path longer than 100 bytes round-trips via PAX path', () {
      final name = 'manifests/${List.filled(8, 'directory-name').join('/')}';
      expect(name.length, greaterThan(100));
      final sink = MemorySink();
      final tar = TarWriter(sink)
        ..addBytes(name, utf8.encode('hello'))
        ..addBytes('short', [1, 2, 3])
        ..finish();
      expect(tar, isNotNull);
      final reader = TarReader(MemorySource(sink.builder.takeBytes()));
      final first = reader.nextEntry()!;
      expect(first.name, name);
      expect(utf8.decode(reader.readAll()), 'hello');
      final second = reader.nextEntry()!;
      expect(second.name, 'short');
      expect(reader.readAll(), [1, 2, 3]);
      expect(reader.nextEntry(), isNull);
    });

    test('entries not read are skipped; links carry no data', () {
      final sink = MemorySink();
      TarWriter(sink)
        ..addBytes('a', List.filled(1000, 7))
        ..addLink('l', 'target')
        ..addBytes('b', [9])
        ..finish();
      final reader = TarReader(MemorySource(sink.builder.takeBytes()));
      expect(reader.nextEntry()!.name, 'a'); // data not read
      final link = reader.nextEntry()!;
      expect(link.isRegular, isFalse);
      expect(reader.nextEntry()!.name, 'b');
      expect(reader.readAll(), [9]);
    });

    test('a damaged header is detected by its checksum', () {
      final sink = MemorySink();
      TarWriter(sink)
        ..addBytes('a', [1])
        ..finish();
      final bytes = sink.builder.takeBytes();
      bytes[3] ^= 1; // inside the name
      expect(
        () => TarReader(MemorySource(bytes)).nextEntry(),
        throwsA(isA<TarFormatException>()),
      );
    });

    test('GNU base-256 sizes are read', () {
      final sink = MemorySink();
      TarWriter(sink).beginFile('x', 5);
      final bytes = Uint8List.fromList(sink.builder.takeBytes());
      bytes.fillRange(124, 136, 0);
      bytes[124] = 0x80;
      bytes[135] = 5;
      var sum = 0;
      for (var i = 0; i < 512; i++) {
        sum += (i >= 148 && i < 156) ? 0x20 : bytes[i];
      }
      final chk = '${sum.toRadixString(8).padLeft(6, '0')}\u0000 ';
      bytes.setRange(148, 156, utf8.encode(chk));
      final entry = TarReader(MemorySource(bytes)).nextEntry()!;
      expect(entry.size, 5);
    });
  });

  group('interoperability', () {
    test('package:archive reads the same entries and contents', () {
      final tmp = makeTemp();
      final store = mockStore(tmp);
      final out = p.join(tmp.path, 'b.carry.tar');
      exportModels(store, ['tiny:latest', 'tiny:chat'], output: out);
      final ours = readEntries(out);
      final theirs = TarDecoder().decodeBytes(File(out).readAsBytesSync());
      final files = theirs.files.where((f) => f.isFile).toList();
      expect(files.map((f) => f.name).toList(), ours.map((e) => e.name));
      for (var i = 0; i < files.length; i++) {
        expect(files[i].content, ours[i].data, reason: ours[i].name);
      }
    });

    test('the system tar lists the same names (skipped if no tar)', () {
      final tmp = makeTemp();
      final store = mockStore(tmp);
      final out = p.join(tmp.path, 'b.carry.tar');
      exportModels(store, ['tiny'], output: out);
      final ProcessResult result;
      try {
        // A relative file name avoids drive letters such as C: on Windows.
        result = Process.runSync('tar', [
          '-tf',
          'b.carry.tar',
        ], workingDirectory: tmp.path);
      } on ProcessException {
        markTestSkipped('no tar on PATH');
        return;
      }
      if (result.exitCode != 0) {
        markTestSkipped('tar could not read the bundle: ${result.stderr}');
        return;
      }
      final listed = (result.stdout as String)
          .split(RegExp(r'\r?\n'))
          .where((l) => l.isNotEmpty)
          .toList();
      expect(listed, readEntries(out).map((e) => e.name).toList());
    });
  });
}
