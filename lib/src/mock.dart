import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'digest.dart';
import 'errors.dart';
import 'model_ref.dart';
import 'store.dart';

/// Default size of the fake weights blob (1.5 MiB).
const int defaultMockWeightsSize = 1536 * 1024;

/// Fake, repeatable "weights": a seeded xorshift stream, so a split bundle
/// really has several parts and every byte matters for the hash.
Uint8List _fakeWeights(int size, int seed) {
  final bytes = Uint8List(size);
  var state = (seed * 2654435761 + 1) & 0xFFFFFFFF;
  for (var i = 0; i < size; i++) {
    state ^= (state << 13) & 0xFFFFFFFF;
    state ^= state >> 17;
    state ^= (state << 5) & 0xFFFFFFFF;
    bytes[i] = state & 0xFF;
  }
  return bytes;
}

/// Creates a practice (mock) models folder with the same layout and hash
/// rules as a real Ollama folder, but fake weights. Three models:
/// `tiny:latest` and `tiny:chat` share one weights blob, and
/// `hf.co/demo/mini:Q4_0` has its own. `ollama run` does not work on it.
void createMockStore(
  Directory dir, {
  int weightsSize = defaultMockWeightsSize,
}) {
  if (weightsSize < 1) {
    throw CarryException.coded('mock.size', exitCode: exitUsage);
  }
  final store = ModelStore(dir);
  if (store.manifestsDir.existsSync() && store.listModels().isNotEmpty) {
    throw CarryException.coded(
      'mock.not_empty',
      params: {'path': dir.path},
      exitCode: exitUsage,
    );
  }
  store.blobsDir.createSync(recursive: true);

  String putBlob(List<int> bytes) {
    final digest = 'sha256:${sha256Hex(bytes)}';
    store.blobFile(digest).writeAsBytesSync(bytes);
    return digest;
  }

  Map<String, Object> layer(String type, List<int> bytes) => {
    'mediaType': type,
    'digest': putBlob(bytes),
    'size': bytes.length,
  };

  void putModel(String name, String family, List<Map<String, Object>> layers) {
    final config = utf8.encode(
      jsonEncode({
        'model_format': 'gguf',
        'model_family': family,
        'architecture': 'amd64',
        'os': 'linux',
        'rootfs': {
          'type': 'layers',
          'diff_ids': [for (final l in layers) l['digest']],
        },
      }),
    );
    final manifest = {
      'schemaVersion': 2,
      'mediaType': 'application/vnd.docker.distribution.manifest.v2+json',
      'config': {
        'mediaType': 'application/vnd.docker.container.image.v1+json',
        'digest': putBlob(config),
        'size': config.length,
      },
      'layers': layers,
    };
    final file = store.manifestFile(ModelRef.parse(name));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(manifest));
  }

  const modelType = 'application/vnd.ollama.image.model';
  const templateType = 'application/vnd.ollama.image.template';
  const systemType = 'application/vnd.ollama.image.system';
  const paramsType = 'application/vnd.ollama.image.params';
  final tinyWeights = layer(modelType, _fakeWeights(weightsSize, 1));
  final template = layer(templateType, utf8.encode('{{ .Prompt }}'));
  final params = layer(paramsType, utf8.encode('{"temperature":0.7}'));
  putModel('tiny:latest', 'tiny', [tinyWeights, template, params]);
  putModel('tiny:chat', 'tiny', [
    tinyWeights, // the same blob: only the system prompt differs
    template,
    layer(systemType, utf8.encode('You are a friendly chat assistant.')),
    params,
  ]);
  final miniWeights = layer(
    modelType,
    _fakeWeights(weightsSize ~/ 2 < 1 ? 1 : weightsSize ~/ 2, 2),
  );
  putModel('hf.co/demo/mini:Q4_0', 'mini', [miniWeights, template]);
  // Keep the folder layout obvious for people who open it.
  assert(p.basename(store.blobsDir.path) == 'blobs');
}
