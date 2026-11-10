import 'package:ollama_carry/ollama_carry.dart';
import 'package:ollama_carry/src/store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ModelRef.parse', () {
    test('fills in the Ollama defaults', () {
      expect(
        ModelRef.parse('llama3').entryName,
        'manifests/registry.ollama.ai/library/llama3/latest',
      );
      expect(
        ModelRef.parse('user/m:q4').entryName,
        'manifests/registry.ollama.ai/user/m/q4',
      );
    });

    test('keeps a foreign host and a host port', () {
      expect(
        ModelRef.parse('hf.co/u/m:Q8_0').entryName,
        'manifests/hf.co/u/m/Q8_0',
      );
      expect(
        ModelRef.parse('localhost:5000/ns/m:t').entryName,
        'manifests/localhost:5000/ns/m/t',
      );
    });

    test('short display hides the default host and library namespace', () {
      expect(ModelRef.parse('llama3').display, 'llama3:latest');
      expect(ModelRef.parse('user/m:q4').display, 'user/m:q4');
      expect(ModelRef.parse('hf.co/u/m:Q8_0').display, 'hf.co/u/m:Q8_0');
    });

    test('rejects traversal, empty parts and too many parts', () {
      for (final bad in [
        '../x',
        'a/../b',
        '',
        'a//b',
        'a/b/c/d',
        'a:',
        '.hidden',
        r'a\b',
        'model:tag with space',
      ]) {
        expect(
          () => ModelRef.parse(bad),
          throwsA(
            isA<CarryException>().having((e) => e.exitCode, 'exit', exitUsage),
          ),
          reason: bad,
        );
      }
    });
  });

  group('resolveModelsDir', () {
    final env = {'HOME': '/home/u', 'USERPROFILE': r'C:\Users\u'};

    test('--models beats OLLAMA_MODELS beats the OS default', () {
      final withEnv = {...env, 'OLLAMA_MODELS': '/data/models'};
      expect(
        resolveModelsDir(
          explicit: '/x',
          environment: withEnv,
          platform: 'macos',
        ).path,
        '/x',
      );
      expect(
        resolveModelsDir(environment: withEnv, platform: 'macos').path,
        '/data/models',
      );
      expect(
        resolveModelsDir(environment: env, platform: 'macos').path,
        p.join('/home/u', '.ollama', 'models'),
      );
    });

    test('Windows uses USERPROFILE', () {
      expect(
        resolveModelsDir(environment: env, platform: 'windows').path,
        p.join(r'C:\Users\u', '.ollama', 'models'),
      );
    });

    test('Linux prefers the service folder only when it has manifests', () {
      final service = resolveModelsDir(
        environment: env,
        platform: 'linux',
        hasManifests: (dir) => dir == linuxServiceModelsDir,
      );
      expect(service.path, linuxServiceModelsDir);
      expect(service.reason, contains('service'));
      final home = resolveModelsDir(
        environment: env,
        platform: 'linux',
        hasManifests: (_) => false,
      );
      expect(home.path, p.join('/home/u', '.ollama', 'models'));
    });

    test('no home folder gives a fix-it message', () {
      expect(
        () => resolveModelsDir(environment: {}, platform: 'linux'),
        throwsA(
          isA<CarryException>().having(
            (e) => e.message,
            'message',
            contains('--models'),
          ),
        ),
      );
    });
  });
}
