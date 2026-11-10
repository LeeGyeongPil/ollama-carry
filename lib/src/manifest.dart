import 'dart:convert';

import 'digest.dart';
import 'errors.dart';

/// One blob referenced by a manifest (the config or a layer).
class BlobRef {
  /// Creates a reference.
  const BlobRef(this.mediaType, this.digest, this.size);

  /// Layer media type, for example `application/vnd.ollama.image.model`.
  final String mediaType;

  /// Normalized digest `sha256:<hex>`.
  final String digest;

  /// Blob size in bytes.
  final int size;
}

/// A parsed model manifest (Docker/OCI manifest v2 JSON).
class Manifest {
  /// Creates a manifest from its blob references (config first).
  const Manifest(this.blobs);

  /// Config blob followed by the layers. Unknown media types are kept as-is.
  final List<BlobRef> blobs;

  /// Sum of all referenced blob sizes (shared blobs counted per reference).
  int get totalSize => blobs.fold(0, (sum, b) => sum + b.size);

  /// Parses and validates manifest bytes. [source] is used in messages.
  static Manifest parse(List<int> bytes, {String source = 'manifest'}) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw CarryException('$source is not valid JSON');
    }
    if (json is! Map<String, Object?>) {
      throw CarryException('$source is not a JSON object');
    }
    final blobs = <BlobRef>[];
    final config = json['config'];
    if (config != null) blobs.add(_descriptor(config, source));
    final layers = json['layers'];
    if (layers is! List<Object?>) {
      throw CarryException('$source has no "layers" list');
    }
    for (final layer in layers) {
      blobs.add(_descriptor(layer, source));
    }
    return Manifest(blobs);
  }

  static BlobRef _descriptor(Object? raw, String source) {
    if (raw is! Map<String, Object?>) {
      throw CarryException('$source has a layer that is not an object');
    }
    final digest = raw['digest'];
    final size = raw['size'];
    if (digest is! String || size is! int || size < 0) {
      throw CarryException('$source has a layer without digest and size');
    }
    final media = raw['mediaType'];
    return BlobRef(media is String ? media : '', normalizeDigest(digest), size);
  }
}
