import 'dart:io';

import 'package:path/path.dart' as p;

import 'digest.dart';
import 'errors.dart';
import 'manifest.dart';
import 'model_ref.dart';

/// Where the Linux install script keeps models (service account `ollama`).
const String linuxServiceModelsDir = '/usr/share/ollama/.ollama/models';

/// A resolved models folder and the reason it was chosen.
class StoreLocation {
  /// Creates a location.
  const StoreLocation(this.path, this.reason);

  /// Models folder path.
  final String path;

  /// Why this folder was chosen (printed by `where`).
  final String reason;
}

bool _hasManifests(String dir) =>
    Directory(p.join(dir, 'manifests')).existsSync();

/// Decides which models folder to use.
///
/// Order: [explicit] (`--models`), `OLLAMA_MODELS`, then the OS default.
/// On Linux the service folder wins over `~/.ollama/models` when it already
/// contains `manifests/`. Environment, platform and folder check are
/// injectable so this is testable on any OS.
StoreLocation resolveModelsDir({
  String? explicit,
  Map<String, String>? environment,
  String? platform,
  bool Function(String dir)? hasManifests,
}) {
  final env = environment ?? Platform.environment;
  final os = platform ?? Platform.operatingSystem;
  final check = hasManifests ?? _hasManifests;
  if (explicit != null && explicit.isNotEmpty) {
    return StoreLocation(explicit, '--models option');
  }
  final fromEnv = env['OLLAMA_MODELS'];
  if (fromEnv != null && fromEnv.isNotEmpty) {
    return StoreLocation(fromEnv, 'OLLAMA_MODELS environment variable');
  }
  final home = (os == 'windows' ? env['USERPROFILE'] : env['HOME']) ?? '';
  if (home.isEmpty) {
    throw CarryException(
      'cannot find your home folder; pass --models <folder> or set '
      'OLLAMA_MODELS',
      exitCode: exitUsage,
    );
  }
  if (os == 'linux' && check(linuxServiceModelsDir)) {
    return const StoreLocation(
      linuxServiceModelsDir,
      'Linux service folder (it contains manifests/)',
    );
  }
  return StoreLocation(
    p.join(home, '.ollama', 'models'),
    'default for $os (~/.ollama/models)',
  );
}

/// Read/write access to an Ollama models folder
/// (`manifests/` + content addressed `blobs/`).
class ModelStore {
  /// Opens the store at [root] (the folder is not created).
  ModelStore(this.root);

  /// The models folder.
  final Directory root;

  /// `<root>/manifests`.
  Directory get manifestsDir => Directory(p.join(root.path, 'manifests'));

  /// `<root>/blobs`.
  Directory get blobsDir => Directory(p.join(root.path, 'blobs'));

  /// Manifest file of [ref].
  File manifestFile(ModelRef ref) =>
      File(p.joinAll([manifestsDir.path, ...ref.segments]));

  /// Path where a blob with [digest] is written (`sha256-<hex>`).
  File blobFile(String digest) =>
      File(p.join(blobsDir.path, blobFileName(digest)));

  /// Existing blob file for [digest]; both `sha256-` and `sha256:` names are
  /// accepted when reading. Returns null if absent.
  File? findBlob(String digest) {
    final dash = blobFile(digest);
    if (dash.existsSync()) return dash;
    final colon = File(p.join(blobsDir.path, digest));
    if (colon.existsSync()) return colon;
    return null;
  }

  /// All installed models, sorted by display name.
  List<ModelRef> listModels() {
    final dir = manifestsDir;
    if (!dir.existsSync()) return [];
    final refs = <ModelRef>[];
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final segments = p.split(p.relative(entity.path, from: dir.path));
      if (segments.length != 4 || segments.any((s) => s.startsWith('.'))) {
        continue;
      }
      try {
        refs.add(ModelRef.fromSegments(segments));
      } on CarryException {
        continue; // not a name Ollama would create
      }
    }
    refs.sort((a, b) => a.display.compareTo(b.display));
    return refs;
  }

  /// Reads and validates the manifest of [ref].
  Manifest readManifest(ModelRef ref) {
    final file = manifestFile(ref);
    if (!file.existsSync()) {
      throw CarryException(
        'model "${ref.display}" is not installed in ${root.path}. '
        'Run `ollama-carry list` to see installed models.',
        exitCode: exitUsage,
      );
    }
    return Manifest.parse(file.readAsBytesSync(), source: ref.display);
  }

  /// Resolves user supplied names to installed models (exit code 2 if absent).
  List<ModelRef> resolveNames(List<String> names) {
    final refs = <ModelRef>[];
    for (final name in names) {
      final ref = ModelRef.parse(name);
      if (!manifestFile(ref).existsSync()) {
        throw CarryException(
          'model "$name" is not installed in ${root.path}. '
          'Run `ollama-carry list` to see installed models, or pass '
          '--models <folder>.',
          exitCode: exitUsage,
        );
      }
      if (!refs.contains(ref)) refs.add(ref);
    }
    return refs;
  }
}
