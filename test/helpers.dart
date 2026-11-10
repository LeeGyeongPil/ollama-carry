import 'dart:io';
import 'dart:typed_data';

import 'package:ollama_carry/ollama_carry.dart';
import 'package:ollama_carry/src/parts.dart';
import 'package:ollama_carry/src/tar.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Creates a temp folder (system temp only) that is removed after each test.
Directory makeTemp() {
  final dir = Directory.systemTemp.createTempSync('ollama-carry-test-');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// Result of a CLI run.
class CliResult {
  CliResult(this.code, this.out, this.err);
  final int code;
  final String out;
  final String err;
}

/// Runs the CLI in-process and captures output.
CliResult cli(List<String> args, {Map<String, String>? environment}) {
  final out = StringBuffer();
  final err = StringBuffer();
  final code = runCli(args, out: out, err: err, environment: environment);
  return CliResult(code, out.toString(), err.toString());
}

/// A mock models folder with the 3 practice models.
ModelStore mockStore(Directory parent, {String name = 'src', int? weights}) {
  final dir = Directory(p.join(parent.path, name));
  createMockStore(dir, weightsSize: weights ?? 256 * 1024);
  return ModelStore(dir);
}

/// All files below [dir] as relative paths (empty if [dir] is missing).
List<String> filesBelow(Directory dir) {
  if (!dir.existsSync()) return [];
  return [
    for (final e in dir.listSync(recursive: true, followLinks: false))
      if (e is File) p.relative(e.path, from: dir.path),
  ]..sort();
}

/// Bytes of a bundle: all parts joined in order.
Uint8List joinParts(String base) {
  final parts = BundleParts.discover(base);
  final out = BytesBuilder(copy: false);
  for (final f in parts.files) {
    out.add(f.readAsBytesSync());
  }
  return out.takeBytes();
}

/// One tar entry with its bytes (only for small test bundles).
class Entry {
  Entry(this.name, this.data, {this.type = '0'});
  String name;
  List<int> data;
  String type;
}

/// Reads every entry of a bundle into memory.
List<Entry> readEntries(String base) {
  final reader = TarReader(MemorySource(joinParts(base)));
  final entries = <Entry>[];
  while (true) {
    final e = reader.nextEntry();
    if (e == null) break;
    entries.add(Entry(e.name, reader.readAll(), type: e.typeFlag));
  }
  return entries;
}

/// Writes [entries] as an unsplit bundle file.
void writeEntries(String path, List<Entry> entries) {
  final sink = MemorySink();
  final tar = TarWriter(sink);
  for (final e in entries) {
    if (e.type == '0') {
      tar.addBytes(e.name, e.data);
    } else {
      tar.addLink(e.name, '/etc/passwd', symbolic: e.type == '2');
    }
  }
  tar.finish();
  File(path).writeAsBytesSync(sink.builder.takeBytes());
}
