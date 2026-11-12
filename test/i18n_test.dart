import 'dart:io';

import 'package:ollama_carry/ollama_carry.dart';
import 'package:ollama_carry/src/i18n.dart';
import 'package:ollama_carry/src/parts.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers.dart';

final RegExp _marker = RegExp(r'\{(\w+)\}');

Set<String> _markers(String text) => {
  for (final m in _marker.allMatches(text)) m.group(1)!,
};

/// Output language of one CLI run in a temp setup.
CliResult run(List<String> args, {Map<String, String>? env}) =>
    cli(args, environment: env);

/// Number of lines that start with an error prefix in either language.
int errorLines(String err) => err
    .split('\n')
    .where((l) => l.startsWith('error: ') || l.startsWith('오류: '))
    .length;

void main() {
  group('message tables', () {
    test('en and ko have exactly the same keys', () {
      expect(messages['ko']!.keys.toSet(), messages['en']!.keys.toSet());
    });

    test('en and ko use the same {placeholders} for every key', () {
      for (final key in messages['en']!.keys) {
        expect(
          _markers(messages['ko']![key]!),
          _markers(messages['en']![key]!),
          reason: key,
        );
      }
    });

    test('ko never puts a fixed particle right after a {placeholder}', () {
      final bad = RegExp('\\}["\'`)\\]」』]*\\s*[이가을를은는의와과로도]');
      for (final entry in messages['ko']!.entries) {
        expect(bad.hasMatch(entry.value), isFalse, reason: entry.key);
      }
    });

    test('tr fills nested messages and falls back to English', () {
      expect(
        tr('en', 'import.tar', {
          'problem': const Msg('tar.early'),
          'offset': 7,
          'where': 'x',
        }),
        'bundle ends early (at byte 7 of the bundle).\nx',
      );
      expect(tr('ko', 'tar.early'), contains('번들'));
      expect(tr('fr', 'tar.early'), 'bundle ends early');
      expect(tr('en', 'no.such.key'), 'no.such.key');
    });
  });

  group('language choice', () {
    late Directory dir;
    setUp(() => dir = makeTemp());

    List<String> where() => ['where', '--models', dir.path];

    test('default is English; ko comes only from a value starting with ko', () {
      expect(run(where()).out, startsWith('models folder:'));
      expect(
        run(where(), env: {'LANG': 'ko_KR.UTF-8'}).out,
        startsWith('모델 폴더:'),
      );
      expect(
        run(where(), env: {'LANG': 'C.UTF-8'}).out,
        startsWith('models folder:'),
      );
      expect(
        run(where(), env: {'LANG': 'fr_FR.UTF-8'}).out,
        startsWith('models'),
      );
    });

    test(
      'priority: --lang > OLLAMA_CARRY_LANG > LC_ALL > LC_MESSAGES > LANG',
      () {
        const ko = 'ko_KR.UTF-8';
        const en = 'en_US.UTF-8';
        bool isKo(CliResult r) => r.out.startsWith('모델 폴더:');
        // Only LANG.
        expect(isKo(run(where(), env: {'LANG': ko})), isTrue);
        // LC_MESSAGES beats LANG.
        expect(
          isKo(run(where(), env: {'LANG': ko, 'LC_MESSAGES': en})),
          isFalse,
        );
        expect(
          isKo(run(where(), env: {'LANG': en, 'LC_MESSAGES': ko})),
          isTrue,
        );
        // LC_ALL beats LC_MESSAGES.
        expect(
          isKo(run(where(), env: {'LC_MESSAGES': ko, 'LC_ALL': en})),
          isFalse,
        );
        expect(
          isKo(run(where(), env: {'LC_MESSAGES': en, 'LC_ALL': ko})),
          isTrue,
        );
        // OLLAMA_CARRY_LANG beats LC_ALL.
        expect(
          isKo(run(where(), env: {'LC_ALL': ko, 'OLLAMA_CARRY_LANG': 'en'})),
          isFalse,
        );
        expect(
          isKo(run(where(), env: {'LC_ALL': en, 'OLLAMA_CARRY_LANG': 'ko'})),
          isTrue,
        );
        // --lang beats everything, before or after the command, with = or space.
        final all = {'OLLAMA_CARRY_LANG': 'ko', 'LC_ALL': ko, 'LANG': ko};
        expect(isKo(run([...where(), '--lang', 'en'], env: all)), isFalse);
        expect(isKo(run(['--lang=en', ...where()], env: all)), isFalse);
        expect(isKo(run(['--lang', 'ko', ...where()])), isTrue);
        expect(isKo(run([...where(), '--lang=ko'])), isTrue);
      },
    );

    test('empty variables are ignored', () {
      expect(
        run(where(), env: {'OLLAMA_CARRY_LANG': '', 'LANG': 'ko_KR.UTF-8'}).out,
        startsWith('모델 폴더:'),
      );
    });

    test('resolveLang is case insensitive for the ko prefix', () {
      expect(resolveLang(environment: {'LANG': 'KO_kr'}), 'ko');
      expect(resolveLang(environment: const {}), 'en');
      expect(resolveLang(flag: 'en', environment: {'LANG': 'ko'}), 'en');
    });
  });

  group('--lang with a bad value', () {
    for (final args in [
      ['--lang', 'fr', 'where'],
      ['where', '--lang=xx'],
      ['--lang=', 'list'],
    ]) {
      test('${args.join(' ')}: one English error line, exit 2, no usage', () {
        final r = run(args, env: {'LANG': 'ko_KR.UTF-8'});
        expect(r.code, 2);
        expect(r.out, isEmpty);
        expect(r.err, startsWith('error: invalid --lang value "'));
        expect(r.err.trim().split('\n'), hasLength(1));
        expect(r.err, isNot(contains('Usage')));
        expect(r.err, isNot(contains('--help')));
      });
    }

    test('--lang without a value is one error line, exit 2', () {
      final r = run(['where', '--lang']);
      expect(r.code, 2);
      expect(r.err, 'error: --lang needs a value: en or ko\n');
    });
  });

  group('Korean output', () {
    late Directory tmp;
    late ModelStore src;
    setUp(() {
      tmp = makeTemp();
      src = mockStore(tmp);
    });

    List<String> ko(List<String> args) => [...args, '--lang', 'ko'];

    test('top-level and command help are Korean', () {
      final top = run(ko(['--help']));
      expect(top.code, 0);
      expect(top.out, contains('사용법: ollama-carry <명령>'));
      expect(top.out, contains('ollama-carry $toolVersion'));
      final sub = run(ko(['export', '--help']));
      expect(sub.code, 0);
      expect(sub.out, contains('사용법: ollama-carry export'));
      expect(sub.out, contains('조각 크기'));
      expect(sub.out, contains('--lang'));
      expect(run(ko([])).code, 2);
    });

    test('where and list are Korean, numbers and paths unchanged', () {
      final w = run(ko(['where', '--models', src.root.path]));
      expect(w.out, contains('모델 폴더: ${src.root.path}'));
      expect(w.out, contains('선택 근거: --models 옵션'));
      expect(w.out, contains('모델 수: 3'));
      final l = run(ko(['list', '--models', src.root.path]));
      final en = run(['list', '--models', src.root.path]);
      expect(l.out, contains('모델 3개'));
      expect(l.out.split('\n').first, en.out.split('\n').first);
      final empty = run(ko(['list', '--models', p.join(tmp.path, 'none')]));
      expect(empty.out, contains('모델이 없습니다'));
    });

    test('where reason for OLLAMA_MODELS and the OS default is Korean', () {
      final env = {'OLLAMA_MODELS': src.root.path};
      expect(run(ko(['where']), env: env).out, contains('OLLAMA_MODELS 환경 변수'));
      // The home folder comes from HOME on macOS/Linux and USERPROFILE on
      // Windows, so set both to keep this test the same on every OS.
      final homeEnv = {'HOME': tmp.path, 'USERPROFILE': tmp.path};
      final home = run(ko(['where']), env: homeEnv);
      expect(home.code, 0, reason: home.err);
      expect(home.out, contains('기본 폴더'));
    });

    test('export and import progress lines are Korean', () {
      final bundle = p.join(tmp.path, 'b.carry.tar');
      final e = run(
        ko(['export', 'tiny', '-o', bundle, '--models', src.root.path]),
      );
      expect(e.code, 0, reason: e.err);
      expect(e.out, contains('내보내는 곳:'));
      expect(e.out, contains('기록:'));
      expect(e.out, contains('고유 blob'));
      final dst = p.join(tmp.path, 'dst');
      final dry = run(ko(['import', bundle, '--dry-run', '--models', dst]));
      expect(dry.code, 0, reason: dry.err);
      expect(dry.out, contains('미리보기'));
      final real = run(ko(['import', bundle, '--models', dst]));
      expect(real.code, 0, reason: real.err);
      expect(real.out, contains('참고:'));
      expect(real.out, contains('해시 확인'));
      expect(real.out, contains('모델: 새로 1'));
    });

    test('verify: text is Korean, --json is identical to English', () {
      final tmpStore = src.root.path;
      final blob =
          Directory(p.join(tmpStore, 'blobs')).listSync().first as File;
      blob.writeAsBytesSync([...blob.readAsBytesSync(), 0]);
      final enText = run(['verify', '--models', tmpStore]);
      final koText = run(ko(['verify', '--models', tmpStore]));
      expect(enText.code, 1);
      expect(koText.code, 1);
      expect(enText.out, contains('corrupt: 1'));
      expect(koText.out, contains('손상: 1'));
      expect(koText.out, contains('실제 크기'));
      final enJson = run(['verify', '--json', '--models', tmpStore]);
      final koJson = run(ko(['verify', '--json', '--models', tmpStore]));
      expect(koJson.out, enJson.out);
      expect(koJson.code, enJson.code);
    });

    test('mock and tour are Korean', () {
      final dir = p.join(tmp.path, 'm');
      final m = run(ko(['mock', dir]));
      expect(m.code, 0, reason: m.err);
      expect(m.out, contains('연습용(mock) 모델을 만들었습니다'));
      expect(m.out, contains('ollama-carry list --models $dir'));
      final t = run(ko(['tour']));
      expect(t.code, 0, reason: t.err);
      expect(t.out, contains('둘러보기: 성공'));
      expect(t.out, contains('손상: 1'));
      expect(t.out, contains('거부됨: blob sha256:'));
      expect(t.out, contains('없음'));
    });

    test('library errors are Korean through code and params', () {
      final m = ['--models', src.root.path];
      final unknown = run(
        ko(['export', 'nope', '-o', p.join(tmp.path, 'x'), ...m]),
      );
      expect(unknown.code, 2);
      expect(unknown.err, startsWith('오류: 설치되지 않은 모델: "nope"'));
      expect(unknown.err, isNot(contains('is not installed')));
      final size = run(
        ko([
          'export',
          'tiny',
          '-o',
          p.join(tmp.path, 'y'),
          '--split',
          'abc',
          ...m,
        ]),
      );
      expect(size.code, 2);
      expect(size.err, contains('잘못된 크기 "abc"'));
      final badName = run(ko(['verify', '../x', ...m]));
      expect(badName.code, 2);
      expect(badName.err, contains('잘못된 모델 이름'));
      final missing = run(
        ko(['import', p.join(tmp.path, 'nothing.tar'), ...m]),
      );
      expect(missing.code, 2);
      expect(missing.err, contains('번들을 찾을 수 없습니다'));
      final badBundle = File(p.join(tmp.path, 'junk.tar'))
        ..writeAsBytesSync(List.filled(2048, 7));
      final junk = run(
        ko(['import', badBundle.path, '--models', p.join(tmp.path, 'd')]),
      );
      expect(junk.code, 1);
      expect(errorLines(junk.err), 1);
      expect(junk.err, isNot(contains('invalid tar header')));
      expect(junk.err, contains('체크섬'));
    });

    test('a damaged bundle is explained in Korean, exit code unchanged', () {
      final bundle = p.join(tmp.path, 'b.carry.tar');
      exportModels(src, ['tiny:latest'], output: bundle);
      final file = File(bundle);
      final bytes = file.readAsBytesSync();
      bytes[bytes.length ~/ 2] ^= 0xFF;
      file.writeAsBytesSync(bytes);
      final dst = p.join(tmp.path, 'dst');
      final en = run(['import', bundle, '--models', dst]);
      final k = run(ko(['import', bundle, '--models', dst]));
      expect(en.code, 1);
      expect(k.code, en.code);
      expect(en.err, contains('is damaged in the bundle'));
      expect(k.err, contains('번들 안의 blob 손상'));
      expect(k.err, contains('아무것도 기록하지 않았습니다'));
      expect(k.err, isNot(contains('Nothing was written')));
    });

    test('a model name conflict keeps exit code 3 in Korean', () {
      final bundle = p.join(tmp.path, 'b.carry.tar');
      exportModels(src, ['tiny:latest'], output: bundle);
      final other = mockStore(tmp, name: 'other', weights: 128 * 1024);
      final conflict = run(ko(['import', bundle, '--models', other.root.path]));
      expect(conflict.code, 3);
      expect(conflict.err, contains('이미 있는 모델과 내용이 다릅니다'));
    });

    test('usage errors from the command line parser are Korean, once', () {
      final cases = <List<String>, String>{
        ['import', '--bogus']: '"--bogus" 옵션이 없습니다',
        ['import', '-x']: '"-x" 옵션이나 플래그가 없습니다',
        ['import', '-fo']: '"-f" 짧은 옵션이 없습니다',
        ['export', '-o']: '"-o" 옵션에 값이 없습니다',
        ['export', '--split']: '"--split" 옵션에 값이 없습니다',
        ['import', '--force=1']: '"--force" 플래그는 값을 받지 않습니다',
      };
      cases.forEach((args, expected) {
        final r = run(ko(args));
        expect(r.code, 2, reason: args.join(' '));
        expect(r.err, startsWith('오류: '), reason: args.join(' '));
        expect(r.err, contains(expected), reason: args.join(' '));
        expect(errorLines(r.err), 1, reason: args.join(' '));
        // The option list that follows is translated as well.
        expect(r.err, contains('이 도움말을 보여 줍니다.'));
        expect(r.err, isNot(contains('Could not find')));
        expect(r.err, isNot(contains('Missing argument')));
        expect(r.out, isEmpty);
      });
    });

    test('unknown command and missing arguments are Korean', () {
      expect(
        run(ko(['frobnicate'])).err,
        '오류: 알 수 없는 명령: "frobnicate". `ollama-carry --help` 를 실행하세요.\n',
      );
      expect(run(ko(['export'])).err, contains('-o <file> 이 없습니다'));
      expect(run(ko(['import'])).err, startsWith('오류: 번들을 정확히'));
      expect(run(ko(['mock'])).err, startsWith('오류: 빈 폴더를'));
    });

    test('exit codes and --json match English for common calls', () {
      final m = ['--models', src.root.path];
      final calls = <List<String>>[
        [],
        ['--help'],
        ['--version'],
        ['where', ...m],
        ['list', ...m],
        ['verify', '--json', ...m],
        ['export', ...m],
        ['frobnicate'],
        ['import', '--bogus'],
        ['verify', 'nope', ...m],
      ];
      for (final args in calls) {
        final en = run([...args, '--lang', 'en']);
        final k = run([...args, '--lang', 'ko']);
        expect(k.code, en.code, reason: args.join(' '));
      }
      expect(
        run(['--version', '--lang', 'ko']).out,
        'ollama-carry $toolVersion\n',
      );
    });
  });

  group('CarryException', () {
    test('plain constructor keeps working and is never translated', () {
      final e = CarryException('custom', exitCode: exitUsage);
      expect(e.message, 'custom');
      expect(e.toString(), 'custom');
      expect(e.exitCode, exitUsage);
      expect(e.code, isNull);
      expect(e.params, isEmpty);
      expect(e.localized('ko'), 'custom');
    });

    test(
      'coded exceptions keep the English message and translate on demand',
      () {
        final e = CarryException.coded(
          'digest.invalid',
          params: {'raw': 'zz'},
          exitCode: exitUsage,
        );
        expect(
          e.message,
          'invalid digest "zz": expected sha256:<64 hex characters>',
        );
        expect(e.exitCode, exitUsage);
        expect(e.code, 'digest.invalid');
        expect(e.localized('ko'), contains('잘못된 다이제스트 "zz"'));
        expect(e.localized('en'), e.message);
      },
    );

    test('library errors carry a code and English text', () {
      try {
        ModelRef.parse('');
        fail('should throw');
      } on CarryException catch (e) {
        expect(e.message, 'model name is empty');
        expect(e.code, 'model.empty');
      }
      try {
        parseSize('x');
        fail('should throw');
      } on CarryException catch (e) {
        expect(e.code, 'size.invalid');
        expect(e.params['text'], 'x');
      }
    });
  });
}
