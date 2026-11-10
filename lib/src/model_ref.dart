import 'errors.dart';

/// Default registry host used by Ollama when a name has no host.
const String defaultHost = 'registry.ollama.ai';

/// Default namespace used by Ollama when a name has no namespace.
const String defaultNamespace = 'library';

/// Default tag used by Ollama when a name has no tag.
const String defaultTag = 'latest';

final RegExp _segment = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9._-]*$');
final RegExp _hostSegment = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9._-]*(:[0-9]+)?$');

/// A model name such as `llama3`, `user/m:q4` or `hf.co/u/m:Q8_0`,
/// mapped to the manifest path `manifests/<host>/<namespace>/<model>/<tag>`.
class ModelRef {
  const ModelRef._(this.host, this.namespace, this.model, this.tag);

  /// Registry host (may include a port).
  final String host;

  /// Namespace (`library` for official models).
  final String namespace;

  /// Model name.
  final String model;

  /// Tag.
  final String tag;

  /// Parses a user supplied model name (defaults are filled in like Ollama).
  static ModelRef parse(String input) {
    final text = input.trim();
    if (text.isEmpty) {
      throw CarryException('model name is empty', exitCode: exitUsage);
    }
    final parts = text.split('/');
    if (parts.length > 3) {
      throw CarryException(
        'invalid model name "$input": use [host/][namespace/]model[:tag]',
        exitCode: exitUsage,
      );
    }
    var last = parts.removeLast();
    var tag = defaultTag;
    final colon = last.lastIndexOf(':');
    if (colon >= 0) {
      tag = last.substring(colon + 1);
      last = last.substring(0, colon);
    }
    var host = defaultHost;
    var namespace = defaultNamespace;
    if (parts.length == 1) {
      namespace = parts[0];
    } else if (parts.length == 2) {
      host = parts[0];
      namespace = parts[1];
    }
    return _validated(host, namespace, last, tag, input);
  }

  /// Builds a reference from manifest path segments
  /// `[host, namespace, model, tag]` (no defaults are applied).
  static ModelRef fromSegments(List<String> segments) {
    if (segments.length != 4) {
      throw CarryException(
        'invalid manifest path "${segments.join('/')}": '
        'expected manifests/<host>/<namespace>/<model>/<tag>',
      );
    }
    return _validated(
      segments[0],
      segments[1],
      segments[2],
      segments[3],
      segments.join('/'),
      exitCode: exitIntegrity,
    );
  }

  /// Parses a bundle entry name `manifests/<host>/<ns>/<model>/<tag>`.
  static ModelRef fromEntryName(String name) {
    final segments = name.split('/');
    if (segments.length != 5 || segments.first != 'manifests') {
      throw CarryException('invalid manifest entry name "$name"');
    }
    return fromSegments(segments.sublist(1));
  }

  static ModelRef _validated(
    String host,
    String namespace,
    String model,
    String tag,
    String original, {
    int exitCode = exitUsage,
  }) {
    final ok =
        _hostSegment.hasMatch(host) &&
        _segment.hasMatch(namespace) &&
        _segment.hasMatch(model) &&
        _segment.hasMatch(tag);
    if (!ok) {
      throw CarryException(
        'invalid model name "$original": each part must use only letters, '
        'digits, "." "_" "-" and must not be empty or start with "."',
        exitCode: exitCode,
      );
    }
    return ModelRef._(host, namespace, model, tag);
  }

  /// Path segments below `manifests/`.
  List<String> get segments => [host, namespace, model, tag];

  /// Manifest path with `/` separators (also the bundle entry name).
  String get entryName => 'manifests/${segments.join('/')}';

  /// Full name `host/namespace/model:tag`.
  String get canonical => '$host/$namespace/$model:$tag';

  /// Short display name: default host and `library` namespace are hidden.
  String get display {
    final hideHost = host == defaultHost;
    final hideNamespace = hideHost && namespace == defaultNamespace;
    final prefix = hideHost
        ? (hideNamespace ? '' : '$namespace/')
        : '$host/$namespace/';
    return '$prefix$model:$tag';
  }

  @override
  bool operator ==(Object other) =>
      other is ModelRef && other.canonical == canonical;

  @override
  int get hashCode => canonical.hashCode;

  @override
  String toString() => display;
}
