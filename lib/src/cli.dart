import 'dart:io';

import 'package:args/args.dart';

import 'bundle.dart';
import 'digest.dart';
import 'errors.dart';
import 'export.dart';
import 'import.dart';
import 'mock.dart';
import 'parts.dart';
import 'store.dart';
import 'tour.dart';
import 'verify.dart';

const String _usage =
    '''
ollama-carry $toolVersion - move Ollama models between machines, offline.

Usage: ollama-carry <command> [options]

Commands:
  where                         Show which models folder is used and why.
  list                          List installed models and their sizes.
  export <model>... -o <file>   Bundle models (shared blobs once) into a tar,
                                optionally split: --split 512K | 3.9G | fat32.
  import <file|file.000>        Verify every blob with SHA-256, then install.
                                --dry-run previews, --force replaces models.
  verify [<model>...]           Check installed blobs (ok / missing / corrupt).
                                --json prints machine readable output.
  mock <dir>                    Create practice (mock) models with fake weights.
  tour                          Run the whole flow on mock data in a temp folder.

Options for where/list/export/import/verify: --models <dir>
  (default: OLLAMA_MODELS, then the OS default folder).

Exit codes: 0 ok, 1 integrity problem, 2 usage error or unknown model,
3 model name conflict (use --force).
''';

const Set<String> _commands = {
  'where',
  'list',
  'export',
  'import',
  'verify',
  'mock',
  'tour',
};

ArgParser _parser(String name) {
  final parser = ArgParser();
  switch (name) {
    case 'export':
      parser
        ..addOption('output', abbr: 'o', help: 'Bundle file to write.')
        ..addOption(
          'split',
          help:
              'Part size such as 512K, 3.9G or "fat32" (default: one '
              'file).',
        );
    case 'import':
      parser
        ..addFlag(
          'dry-run',
          negatable: false,
          help: 'Show what would happen, write nothing.',
        )
        ..addFlag(
          'force',
          negatable: false,
          help: 'Replace models that differ.',
        );
    case 'verify':
      parser.addFlag('json', negatable: false, help: 'JSON output.');
    case 'mock':
      parser.addOption(
        'weights-size',
        defaultsTo: '$defaultMockWeightsSize',
        help: 'Size of the fake weights in bytes (K/M/G allowed).',
      );
  }
  if (const {'where', 'list', 'export', 'import', 'verify'}.contains(name)) {
    parser.addOption('models', help: 'Ollama models folder.');
  }
  return parser;
}

/// Runs the CLI and returns the exit code. Output goes to [out] and [err]
/// (default stdout and stderr); [environment] defaults to the process
/// environment.
int runCli(
  List<String> args, {
  StringSink? out,
  StringSink? err,
  Map<String, String>? environment,
}) {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  void say(String line) => stdoutSink.writeln(line);

  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    say(_usage);
    return args.isEmpty ? exitUsage : exitOk;
  }
  if (args.first == '--version') {
    say('ollama-carry $toolVersion');
    return exitOk;
  }
  final command = args.first;
  try {
    if (!_commands.contains(command)) {
      throw CarryException(
        'unknown command "$command"; run `ollama-carry --help`',
        exitCode: exitUsage,
      );
    }
    final parser = _parser(command);
    final ArgResults results;
    try {
      results = parser.parse(args.sublist(1));
    } on FormatException catch (e) {
      throw CarryException(
        '${e.message}\n${parser.usage}',
        exitCode: exitUsage,
      );
    }
    final rest = results.rest;

    StoreLocation locate() => resolveModelsDir(
      explicit: results['models'] as String?,
      environment: environment,
    );

    switch (command) {
      case 'where':
        final location = locate();
        final store = ModelStore(Directory(location.path));
        say('models folder: ${location.path}');
        say('chosen by:     ${location.reason}');
        say('exists:        ${store.root.existsSync() ? 'yes' : 'no'}');
        say('models:        ${store.listModels().length}');
        return exitOk;
      case 'list':
        final store = ModelStore(Directory(locate().path));
        final refs = store.listModels();
        if (refs.isEmpty) {
          say(
            'no models found in ${store.root.path} '
            '(see `ollama-carry where`)',
          );
          return exitOk;
        }
        final unique = <String, int>{};
        var listed = 0;
        for (final ref in refs) {
          final manifest = store.readManifest(ref);
          listed += manifest.totalSize;
          for (final b in manifest.blobs) {
            unique[b.digest] = b.size;
          }
          say('${ref.display.padRight(32)} ${formatBytes(manifest.totalSize)}');
        }
        final onDisk = unique.values.fold(0, (a, b) => a + b);
        say(
          '${refs.length} models, ${formatBytes(listed)} added up, '
          '${formatBytes(onDisk)} on disk (shared blobs counted once)',
        );
        return exitOk;
      case 'export':
        final output = results['output'] as String?;
        if (output == null) {
          throw CarryException(
            'missing -o <file>, e.g. `ollama-carry export llama3 -o '
            '/path/llama3.carry.tar`',
            exitCode: exitUsage,
          );
        }
        final split = results['split'] as String?;
        final store = ModelStore(Directory(locate().path));
        say('exporting from ${store.root.path}');
        final result = exportModels(
          store,
          rest,
          output: output,
          splitSize: split == null ? null : parseSize(split),
          log: say,
        );
        for (final part in result.parts) {
          say('wrote ${part.path}  ${formatBytes(part.size)}');
        }
        say('wrote ${checksumPath(output)}  (sha256sum format)');
        say(
          '${result.models} models, ${result.blobCount} unique blobs, '
          '${formatBytes(result.blobBytes)}; sharing saved '
          '${formatBytes(result.savedBytes)}',
        );
        return exitOk;
      case 'import':
        if (rest.length != 1) {
          throw CarryException(
            'give exactly one bundle: `ollama-carry import <file|file.000>`',
            exitCode: exitUsage,
          );
        }
        final store = ModelStore(Directory(locate().path));
        final dry = results['dry-run'] as bool;
        say('${dry ? 'dry run: ' : ''}importing into ${store.root.path}');
        if (!dry) {
          say(
            'note: stop the Ollama server (or set OLLAMA_NOPRUNE=1) while '
            'importing, or it may prune blobs that have no manifest yet',
          );
        }
        final report = importBundle(
          store,
          rest.single,
          dryRun: dry,
          force: results['force'] as bool,
          log: say,
        );
        say('models: ${report.modelNames.join(', ')}');
        say(
          'models: new ${report.modelsNew}, unchanged '
          '${report.modelsUnchanged}, replaced ${report.modelsOverwritten}',
        );
        say(
          'blobs: ${dry ? 'would write' : 'written'} ${report.blobsToWrite} '
          '(${formatBytes(report.bytesToWrite)}), '
          'skipped ${report.blobsSkipped}',
        );
        if (dry) {
          say(
            'dry run: blob contents were not hashed; run without '
            '--dry-run to verify and install',
          );
        } else if (store.root.path.startsWith('/usr/share/ollama')) {
          say(
            'hint: if Ollama runs as the "ollama" user, change the owner '
            'of ${store.root.path} to that user (chown -R ollama:ollama)',
          );
        }
        return exitOk;
      case 'verify':
        final store = ModelStore(Directory(locate().path));
        final report = verifyStore(store, models: rest);
        say((results['json'] as bool) ? report.toJson() : report.toText());
        return report.isOk ? exitOk : exitIntegrity;
      case 'mock':
        if (rest.length != 1) {
          throw CarryException(
            'give an empty folder: `ollama-carry mock <dir>`',
            exitCode: exitUsage,
          );
        }
        final size = parseSize(results['weights-size'] as String);
        createMockStore(Directory(rest.single), weightsSize: size);
        say(
          'created practice (mock) models in ${rest.single} - fake weights, '
          'same layout and hash rules as Ollama; try:',
        );
        say('  ollama-carry list --models ${rest.single}');
        return exitOk;
      default:
        runTour(say);
        return exitOk;
    }
  } on CarryException catch (e) {
    stderrSink.writeln('error: ${e.message}');
    return e.exitCode;
  } on FileSystemException catch (e) {
    stderrSink.writeln(
      'error: ${e.message}: ${e.path ?? ''} '
      '(${e.osError?.message ?? 'file system error'}). Check the path and '
      'permissions.',
    );
    return exitIntegrity;
  }
}
