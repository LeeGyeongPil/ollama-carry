import 'dart:io';

import 'package:args/args.dart';

import 'bundle.dart';
import 'digest.dart';
import 'errors.dart';
import 'export.dart';
import 'i18n.dart';
import 'import.dart';
import 'mock.dart';
import 'parts.dart';
import 'store.dart';
import 'tour.dart';
import 'verify.dart';

const Set<String> _commands = {
  'where',
  'list',
  'export',
  'import',
  'verify',
  'mock',
  'tour',
};

ArgParser _parser(String name, String lang) {
  String t(String code) => tr(lang, code);
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: t('opt.help'))
    ..addOption('lang', help: t('opt.lang'), valueHelp: 'en|ko');
  switch (name) {
    case 'export':
      parser
        ..addOption('output', abbr: 'o', help: t('opt.output'))
        ..addOption('split', help: t('opt.split'));
    case 'import':
      parser
        ..addFlag('dry-run', negatable: false, help: t('opt.dry_run'))
        ..addFlag('force', negatable: false, help: t('opt.force'));
    case 'verify':
      parser.addFlag('json', negatable: false, help: t('opt.json'));
    case 'mock':
      parser.addOption(
        'weights-size',
        defaultsTo: '$defaultMockWeightsSize',
        help: t('opt.weights_size'),
      );
  }
  if (const {'where', 'list', 'export', 'import', 'verify'}.contains(name)) {
    parser.addOption('models', help: t('opt.models'));
  }
  return parser;
}

/// Turns a `package:args` parse error into a message that can be translated;
/// unknown wording stays as the original English text.
Object _parseProblem(FormatException e) {
  final text = e.message;
  const patterns = {
    'args.no_option': r'^Could not find an option named "(.*)"\.$',
    'args.no_flag': r'^Could not find an option or flag "(.*)"\.$',
    'args.no_short': r'^Could not find an option with short name "(.*)"\.$',
    'args.missing_value': r'^Missing argument for "(.*)"\.$',
    'args.flag_value': r'^Flag option "(.*)" ',
  };
  for (final entry in patterns.entries) {
    final m = RegExp(entry.value).firstMatch(text);
    if (m != null) return Msg(entry.key, {'name': m.group(1)});
  }
  final allowed = RegExp(
    r'^"(.*)" is not an allowed value for option "(.*)"\.',
  ).firstMatch(text);
  if (allowed != null) {
    return Msg('args.bad_value', {
      'value': allowed.group(1),
      'name': allowed.group(2),
    });
  }
  return text;
}

/// Result of looking for `--lang` in the arguments.
class _LangScan {
  _LangScan(this.rest, this.value, this.error);
  final List<String> rest;
  final String? value;
  final String? error;
}

/// Removes `--lang <v>` / `--lang=<v>` (allowed before or after the command).
_LangScan _scanLang(List<String> args) {
  final rest = <String>[];
  String? value;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--') {
      rest.addAll(args.sublist(i));
      break;
    }
    String? given;
    if (a == '--lang') {
      if (i + 1 >= args.length) {
        return _LangScan(rest, null, langMissingMessage());
      }
      given = args[++i];
    } else if (a.startsWith('--lang=')) {
      given = a.substring('--lang='.length);
    } else {
      rest.add(a);
      continue;
    }
    if (!supportedLangs.contains(given)) {
      return _LangScan(rest, null, langInvalidMessage(given));
    }
    value = given;
  }
  return _LangScan(rest, value, null);
}

/// Runs the CLI and returns the exit code. Output goes to [out] and [err]
/// (default stdout and stderr); [environment] defaults to the process
/// environment. The language comes from `--lang`, then `OLLAMA_CARRY_LANG`,
/// `LC_ALL`, `LC_MESSAGES`, `LANG` (Korean if it starts with `ko`, else
/// English).
int runCli(
  List<String> allArgs, {
  StringSink? out,
  StringSink? err,
  Map<String, String>? environment,
}) {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  void say(String line) => stdoutSink.writeln(line);

  final scan = _scanLang(allArgs);
  if (scan.error != null) {
    stderrSink.writeln('error: ${scan.error}');
    return exitUsage;
  }
  final args = scan.rest;
  final lang = resolveLang(
    flag: scan.value,
    environment: environment ?? Platform.environment,
  );
  String t(String code, [Map<String, Object?> params = const {}]) =>
      tr(lang, code, params);

  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    say(t('usage.main', {'version': toolVersion}));
    return args.isEmpty ? exitUsage : exitOk;
  }
  if (args.first == '--version') {
    say('ollama-carry $toolVersion');
    return exitOk;
  }
  final command = args.first;
  try {
    if (!_commands.contains(command)) {
      throw CarryException.coded(
        'error.unknown_command',
        params: {'command': command},
        exitCode: exitUsage,
      );
    }
    final parser = _parser(command, lang);
    final ArgResults results;
    try {
      results = parser.parse(args.sublist(1));
    } on FormatException catch (e) {
      throw CarryException.coded(
        'args.with_usage',
        params: {'problem': _parseProblem(e), 'usage': parser.usage},
        exitCode: exitUsage,
      );
    }
    // `<command> --help`: print usage only, run nothing.
    if (results['help'] as bool) {
      say(t('cmd.$command'));
      say(parser.usage);
      return exitOk;
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
        final reason = location.reasonCode == null
            ? location.reason
            : t(location.reasonCode!, location.reasonParams);
        say(t('where.folder', {'path': location.path}));
        say(t('where.reason', {'reason': reason}));
        say(
          t('where.exists', {
            'value': t(store.root.existsSync() ? 'word.yes' : 'word.no'),
          }),
        );
        say(t('where.models', {'count': store.listModels().length}));
        return exitOk;
      case 'list':
        final store = ModelStore(Directory(locate().path));
        final refs = store.listModels();
        if (refs.isEmpty) {
          say(t('list.empty', {'path': store.root.path}));
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
          t('list.summary', {
            'count': refs.length,
            'listed': formatBytes(listed),
            'disk': formatBytes(onDisk),
          }),
        );
        return exitOk;
      case 'export':
        final output = results['output'] as String?;
        if (output == null) {
          throw CarryException.coded(
            'error.export_no_output',
            exitCode: exitUsage,
          );
        }
        final split = results['split'] as String?;
        final store = ModelStore(Directory(locate().path));
        say(t('export.start', {'path': store.root.path}));
        final result = exportModels(
          store,
          rest,
          output: output,
          splitSize: split == null ? null : parseSize(split),
          log: say,
          lang: lang,
        );
        for (final part in result.parts) {
          say(
            t('export.wrote_part', {
              'path': part.path,
              'size': formatBytes(part.size),
            }),
          );
        }
        say(t('export.wrote_sums', {'path': checksumPath(output)}));
        say(
          t('export.summary', {
            'models': result.models,
            'blobs': result.blobCount,
            'bytes': formatBytes(result.blobBytes),
            'saved': formatBytes(result.savedBytes),
          }),
        );
        return exitOk;
      case 'import':
        if (rest.length != 1) {
          throw CarryException.coded('error.import_one', exitCode: exitUsage);
        }
        final store = ModelStore(Directory(locate().path));
        final dry = results['dry-run'] as bool;
        say(
          t(dry ? 'import.start_dry' : 'import.start', {
            'path': store.root.path,
          }),
        );
        if (!dry) say(t('import.note_prune'));
        final report = importBundle(
          store,
          rest.single,
          dryRun: dry,
          force: results['force'] as bool,
          log: say,
          lang: lang,
        );
        say(t('import.models', {'names': report.modelNames.join(', ')}));
        say(
          t('import.counts', {
            'new': report.modelsNew,
            'unchanged': report.modelsUnchanged,
            'replaced': report.modelsOverwritten,
          }),
        );
        say(
          t(dry ? 'import.blobs_dry' : 'import.blobs', {
            'count': report.blobsToWrite,
            'bytes': formatBytes(report.bytesToWrite),
            'skipped': report.blobsSkipped,
          }),
        );
        if (dry) {
          say(t('import.dry_note'));
        } else if (store.root.path.startsWith('/usr/share/ollama')) {
          say(t('import.chown_hint', {'path': store.root.path}));
        }
        return exitOk;
      case 'verify':
        final store = ModelStore(Directory(locate().path));
        final report = verifyStore(store, models: rest);
        say(
          (results['json'] as bool)
              ? report.toJson()
              : report.toText(lang: lang),
        );
        return report.isOk ? exitOk : exitIntegrity;
      case 'mock':
        if (rest.length != 1) {
          throw CarryException.coded('error.mock_one', exitCode: exitUsage);
        }
        final size = parseSize(results['weights-size'] as String);
        createMockStore(Directory(rest.single), weightsSize: size);
        say(t('mock.created', {'path': rest.single}));
        say('  ollama-carry list --models ${rest.single}');
        return exitOk;
      default:
        runTour(say, lang: lang);
        return exitOk;
    }
  } on CarryException catch (e) {
    stderrSink.writeln('${t('error.prefix')}${e.localized(lang)}');
    return e.exitCode;
  } on FileSystemException catch (e) {
    stderrSink.writeln(
      '${t('error.prefix')}${t('error.fs', {'message': e.message, 'path': e.path ?? '', 'os': e.osError?.message ?? t('error.fs_generic')})}',
    );
    return exitIntegrity;
  }
}
