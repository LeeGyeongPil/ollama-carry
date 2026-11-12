import 'dart:io';

import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  const commands = [
    'where',
    'list',
    'export',
    'import',
    'verify',
    'mock',
    'tour',
  ];

  group('subcommand help', () {
    for (final command in commands) {
      for (final flag in ['--help', '-h']) {
        test('$command $flag prints usage, exit 0, empty stderr', () {
          final r = cli([command, flag]);
          expect(r.code, 0, reason: r.err);
          expect(r.out, contains('Usage: ollama-carry $command'));
          expect(r.err, isEmpty);
        });
      }
    }

    // Deterministic: the system temp folder is replaced by a counter so that
    // other test files running in parallel cannot interfere, and a tour that
    // cleans up after itself is still noticed.
    test('tour --help does not run the tour (no temp folder requested)', () {
      var tempRequests = 0;
      final realTemp = Directory.systemTemp;
      final r = IOOverrides.runZoned(
        () => cli(['tour', '--help']),
        getSystemTempDirectory: () {
          tempRequests++;
          return realTemp;
        },
      );
      expect(tempRequests, 0);
      expect(r.out, contains('Usage: ollama-carry tour'));
      expect(r.out, isNot(contains('tour: ')));
    });

    test('control: a real tour does request a temp folder', () {
      var tempRequests = 0;
      final realTemp = Directory.systemTemp;
      final r = IOOverrides.runZoned(
        () => cli(['tour']),
        getSystemTempDirectory: () {
          tempRequests++;
          return realTemp;
        },
      );
      expect(tempRequests, greaterThan(0), reason: r.err);
      expect(r.out, contains('tour: ok'));
    });

    test('help lists the command options', () {
      expect(cli(['import', '--help']).out, contains('--dry-run'));
      expect(cli(['export', '-h']).out, contains('--split'));
    });
  });

  group('error paths unchanged', () {
    test('unknown option', () {
      final r = cli(['import', '--bogus']);
      expect(r.code, 2);
      expect(
        r.err,
        startsWith('error: Could not find an option named "--bogus"'),
      );
      expect(r.out, isEmpty);
    });
    test('missing arguments', () {
      expect(
        cli(['import']).err,
        'error: give exactly one bundle: `ollama-carry import <file|file.000>`\n',
      );
      expect(cli(['export']).code, 2);
      expect(cli(['export']).err, contains('missing -o <file>'));
      expect(
        cli(['mock']).err,
        'error: give an empty folder: `ollama-carry mock <dir>`\n',
      );
    });
    test('unknown command', () {
      final r = cli(['frobnicate']);
      expect(r.code, 2);
      expect(
        r.err,
        'error: unknown command "frobnicate"; run `ollama-carry --help`\n',
      );
    });
    test('top level help, no args, version', () {
      final h = cli(['--help']);
      expect(h.code, 0);
      expect(cli(['-h']).out, h.out);
      expect(h.out, startsWith('ollama-carry 0.2.0 - move Ollama models'));
      final none = cli([]);
      expect(none.code, 2);
      expect(none.out, h.out);
      expect(cli(['--version']).out, 'ollama-carry 0.2.0\n');
    });
  });
}
