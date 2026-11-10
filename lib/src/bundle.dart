import 'dart:convert';

import 'digest.dart';
import 'errors.dart';
import 'model_ref.dart';

/// Bundle format marker stored in `carry.json`.
const String bundleFormat = 'ollama-carry/1';

/// Tool version written into bundles.
const String toolVersion = '0.1.0';

/// A model listed in the bundle index.
class IndexModel {
  /// Creates an index entry.
  const IndexModel(this.ref, this.sha256, this.size);

  /// Model name.
  final ModelRef ref;

  /// SHA-256 (hex) of the manifest bytes.
  final String sha256;

  /// Manifest size in bytes.
  final int size;
}

/// The `carry.json` index: the first entry of every bundle.
class BundleIndex {
  /// Creates an index.
  const BundleIndex(this.models, this.blobs);

  /// Models in the bundle.
  final List<IndexModel> models;

  /// Unique blobs (digest to size), in bundle order.
  final Map<String, int> blobs;

  /// Deterministic JSON bytes (no timestamps).
  List<int> encode() => utf8.encode(
    jsonEncode({
      'format': bundleFormat,
      'tool': 'ollama-carry $toolVersion',
      'models': [
        for (final m in models)
          {
            'name': m.ref.canonical,
            'manifest': m.ref.entryName,
            'sha256': m.sha256,
            'size': m.size,
          },
      ],
      'blobs': [
        for (final e in blobs.entries) {'digest': e.key, 'size': e.value},
      ],
    }),
  );

  /// Parses and validates `carry.json` bytes.
  static BundleIndex parse(List<int> bytes) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw CarryException(
        'carry.json is not valid JSON; is this a bundle '
        'made by ollama-carry?',
      );
    }
    if (json is! Map<String, Object?>) {
      throw CarryException('carry.json is not a JSON object');
    }
    if (json['format'] != bundleFormat) {
      throw CarryException(
        'unsupported bundle format "${json['format']}" (this version reads '
        '"$bundleFormat"); update ollama-carry on this machine',
      );
    }
    final models = <IndexModel>[];
    final modelList = json['models'];
    final blobList = json['blobs'];
    if (modelList is! List<Object?> || blobList is! List<Object?>) {
      throw CarryException('carry.json is missing "models" or "blobs"');
    }
    for (final raw in modelList) {
      if (raw is! Map<String, Object?>) {
        throw CarryException('carry.json has an invalid model entry');
      }
      final manifest = raw['manifest'];
      final sha = raw['sha256'];
      final size = raw['size'];
      if (manifest is! String ||
          sha is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha) ||
          size is! int ||
          size < 0) {
        throw CarryException('carry.json has an invalid model entry');
      }
      models.add(IndexModel(ModelRef.fromEntryName(manifest), sha, size));
    }
    final blobs = <String, int>{};
    for (final raw in blobList) {
      if (raw is! Map<String, Object?>) {
        throw CarryException('carry.json has an invalid blob entry');
      }
      final digest = raw['digest'];
      final size = raw['size'];
      if (digest is! String || size is! int || size < 0) {
        throw CarryException('carry.json has an invalid blob entry');
      }
      blobs[normalizeDigest(digest)] = size;
    }
    return BundleIndex(models, blobs);
  }
}
