/// English and Korean messages for everything the CLI prints.
///
/// All user-visible wording lives in [messages] (key to text, `{name}` marks a
/// value). Library errors carry a message code plus parameters
/// (`CarryException.code` / `.params`), so the CLI can print them in the
/// chosen language while `CarryException.message` stays English.
library;

/// A message code with its parameters; used as a nested parameter value.
class Msg {
  /// Creates a message reference.
  const Msg(this.code, [this.params = const {}]);

  /// Key in [messages].
  final String code;

  /// Values for the `{name}` markers.
  final Map<String, Object?> params;
}

/// Languages the CLI can print.
const List<String> supportedLangs = ['en', 'ko'];

/// Environment variable that selects the language.
const String langEnvVar = 'OLLAMA_CARRY_LANG';

final RegExp _marker = RegExp(r'\{(\w+)\}');

/// Renders message [code] in [lang] (falls back to English, then to [code]).
String tr(String lang, String code, [Map<String, Object?> params = const {}]) {
  final template =
      (messages[lang] ?? messages['en']!)[code] ??
      messages['en']![code] ??
      code;
  return template.replaceAllMapped(_marker, (m) {
    final value = params[m[1]];
    if (value == null) return m[0]!;
    if (value is Msg) return tr(lang, value.code, value.params);
    return '$value';
  });
}

/// Picks the language: [flag] (`--lang`) first, then `OLLAMA_CARRY_LANG`,
/// `LC_ALL`, `LC_MESSAGES`, `LANG` (first non-empty one wins). A value that
/// starts with `ko` means Korean; anything else, or nothing, means English.
String resolveLang({String? flag, required Map<String, String> environment}) {
  String pick(String value) =>
      value.toLowerCase().startsWith('ko') ? 'ko' : 'en';
  if (flag != null) return pick(flag);
  for (final name in const [langEnvVar, 'LC_ALL', 'LC_MESSAGES', 'LANG']) {
    final value = environment[name];
    if (value != null && value.trim().isNotEmpty) return pick(value.trim());
  }
  return 'en';
}

/// Error text for a `--lang` value that is not `en` or `ko` (always English).
String langInvalidMessage(String value) =>
    'invalid --lang value "$value"; use en or ko';

/// Error text for `--lang` without a value (always English).
String langMissingMessage() => '--lang needs a value: en or ko';

/// Message table. Keep both languages on the same keys and markers
/// (`test/i18n_test.dart` checks this).
const Map<String, Map<String, String>> messages = {'en': _en, 'ko': _ko};

const Map<String, String> _en = {
  // Top-level usage.
  'usage.main': '''
ollama-carry {version} - move Ollama models between machines, offline.

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

Language: --lang en|ko, else OLLAMA_CARRY_LANG, LC_ALL, LC_MESSAGES, LANG
  (anything that is not Korean prints English).

Exit codes: 0 ok, 1 integrity problem, 2 usage error or unknown model,
3 model name conflict (use --force).
''',
  'cmd.where': 'Usage: ollama-carry where [options]',
  'cmd.list': 'Usage: ollama-carry list [options]',
  'cmd.export': 'Usage: ollama-carry export <model>... -o <file> [options]',
  'cmd.import': 'Usage: ollama-carry import <file|file.000> [options]',
  'cmd.verify': 'Usage: ollama-carry verify [<model>...] [options]',
  'cmd.mock': 'Usage: ollama-carry mock <dir> [options]',
  'cmd.tour': 'Usage: ollama-carry tour [options]',
  // Option help.
  'opt.help': 'Show this help.',
  'opt.lang': 'Output language: en or ko.',
  'opt.output': 'Bundle file to write.',
  'opt.split': 'Part size such as 512K, 3.9G or "fat32" (default: one file).',
  'opt.dry_run': 'Show what would happen, write nothing.',
  'opt.force': 'Replace models that differ.',
  'opt.json': 'JSON output.',
  'opt.weights_size': 'Size of the fake weights in bytes (K/M/G allowed).',
  'opt.models': 'Ollama models folder.',
  // Generic words.
  'word.yes': 'yes',
  'word.no': 'no',
  'word.some': 'some',
  'word.none': 'none',
  'status.ok': 'ok',
  'status.missing': 'missing',
  'status.corrupt': 'corrupt',
  // CLI errors.
  'error.prefix': 'error: ',
  'error.fs': '{message}: {path} ({os}). Check the path and permissions.',
  'error.fs_generic': 'file system error',
  'error.unknown_command':
      'unknown command "{command}"; run `ollama-carry --help`',
  'error.export_no_output':
      'missing -o <file>, e.g. `ollama-carry export llama3 -o '
      '/path/llama3.carry.tar`',
  'error.import_one':
      'give exactly one bundle: `ollama-carry import <file|file.000>`',
  'error.mock_one': 'give an empty folder: `ollama-carry mock <dir>`',
  // package:args parse errors.
  'args.no_option': 'Could not find an option named "{name}".',
  'args.no_flag': 'Could not find an option or flag "{name}".',
  'args.no_short': 'Could not find an option with short name "{name}".',
  'args.missing_value': 'Missing argument for "{name}".',
  'args.bad_value': '"{value}" is not an allowed value for option "{name}".',
  'args.with_usage': '{problem}\n{usage}',
  'args.flag_value': 'Flag option "{name}" does not take a value.',
  // where / list.
  'where.folder': 'models folder: {path}',
  'where.reason': 'chosen by:     {reason}',
  'where.exists': 'exists:        {value}',
  'where.models': 'models:        {count}',
  'reason.models_option': '--models option',
  'reason.env': 'OLLAMA_MODELS environment variable',
  'reason.service': 'Linux service folder (it contains manifests/)',
  'reason.default': 'default for {os} (~/.ollama/models)',
  'list.empty': 'no models found in {path} (see `ollama-carry where`)',
  'list.summary':
      '{count} models, {listed} added up, {disk} on disk '
      '(shared blobs counted once)',
  // export.
  'export.start': 'exporting from {path}',
  'export.wrote_part': 'wrote {path}  {size}',
  'export.wrote_sums': 'wrote {path}  (sha256sum format)',
  'export.summary':
      '{models} models, {blobs} unique blobs, {bytes}; sharing saved {saved}',
  'export.log_blob': '  blob {digest}  {size}',
  // import.
  'import.start': 'importing into {path}',
  'import.start_dry': 'dry run: importing into {path}',
  'import.note_prune':
      'note: stop the Ollama server (or set OLLAMA_NOPRUNE=1) while importing, '
      'or it may prune blobs that have no manifest yet',
  'import.models': 'models: {names}',
  'import.counts':
      'models: new {new}, unchanged {unchanged}, replaced {replaced}',
  'import.blobs': 'blobs: written {count} ({bytes}), skipped {skipped}',
  'import.blobs_dry': 'blobs: would write {count} ({bytes}), skipped {skipped}',
  'import.dry_note':
      'dry run: blob contents were not hashed; run without --dry-run to '
      'verify and install',
  'import.chown_hint':
      'hint: if Ollama runs as the "ollama" user, change the owner of {path} '
      'to that user (chown -R ollama:ollama)',
  'import.log_skip':
      '  skip   {digest}  already installed (bundle copy hash ok)',
  'import.log_hash': '  hash ok {digest}  {size}  (staged)',
  // mock.
  'mock.created':
      'created practice (mock) models in {path} - fake weights, same layout '
      'and hash rules as Ollama; try:',
  // verify text report.
  'verify.invalid': 'invalid  manifest {name}: {why}',
  'verify.sum_ok': 'ok: {count}',
  'verify.sum_missing': 'missing: {count}',
  'verify.sum_corrupt': 'corrupt: {count}',
  'verify.d_missing': 'not in {path}',
  'verify.d_size': 'size {actual} but manifest says {expected}',
  'verify.d_hash': 'content does not match digest',
  // tour.
  'tour.intro':
      'tour: practice (mock) models, fake weights - `ollama run` would not work '
      'on them',
  'tour.s1': '\n1. create a mock models folder',
  'tour.model': '   {name}  {size}',
  'tour.s2': '\n2. export tiny:latest and tiny:chat in 512K parts',
  'tour.exported':
      '   {parts} parts, {blobs} unique blobs, shared blobs stored once '
      '(saved {saved})',
  'tour.s3': '\n3. import into an empty folder (first part is enough)',
  'tour.imported': '   blobs: written {written}, skipped {skipped}',
  'tour.again': '   again: written {written}, skipped {skipped}',
  'tour.s4': '\n4. verify the installed copy',
  'tour.counts': '   ok: {ok}, missing: {missing}, corrupt: {corrupt}',
  'tour.s5': '\n5. damage one byte of a blob, then verify',
  'tour.s6': '\n6. damage one byte inside a part, then import elsewhere',
  'tour.refused': '   refused: blob {digest}... is damaged',
  'tour.refused_other': '   refused: {first}',
  'tour.files': '   files written to the target: {value}',
  'tour.ok': 'tour: ok',
  'tour.failed': 'tour failed: a damaged part was accepted',
  // Library errors: bundle index.
  'bundle.json_invalid':
      'carry.json is not valid JSON; is this a bundle made by ollama-carry?',
  'bundle.not_object': 'carry.json is not a JSON object',
  'bundle.format':
      'unsupported bundle format "{format}" (this version reads '
      '"{supported}"); update ollama-carry on this machine',
  'bundle.missing_fields': 'carry.json is missing "models" or "blobs"',
  'bundle.bad_model': 'carry.json has an invalid model entry',
  'bundle.bad_blob': 'carry.json has an invalid blob entry',
  'digest.invalid':
      'invalid digest "{raw}": expected sha256:<64 hex characters>',
  // Library errors: export.
  'export.no_models':
      'give at least one model name, e.g. `ollama-carry export llama3 -o '
      'bundle.carry.tar`',
  'export.size_conflict':
      '{digest} has two different sizes in the manifests; the store is '
      'inconsistent. Run `ollama-carry verify`.',
  'export.blob_missing':
      'blob {digest} is missing from {dir}. Run `ollama-carry verify` and pull '
      'the model again on this machine.',
  'export.blob_size':
      'blob {digest} has {actual} bytes but the manifest says {expected}. Run '
      '`ollama-carry verify`.',
  'export.exists':
      '{path} already exists. Choose another -o name or delete the old bundle '
      'first.',
  'export.blob_changed':
      'blob {digest} in the store does not match its digest (it is damaged or '
      'changed while exporting). Nothing was exported. Run '
      '`ollama-carry verify` and pull the model again.',
  // Library errors: import.
  'import.not_bundle':
      'this is not an ollama-carry bundle (the first entry must be carry.json)',
  'import.index_large': 'carry.json is unreasonably large; refusing',
  'import.conflicts':
      'these models already exist with different content: {names}. Nothing was '
      'written. Use --force to replace them.',
  'import.not_plain':
      'refusing bundle: entry "{name}" is not a plain file (type "{type}"); '
      'links and special files are not allowed',
  'import.duplicate': 'refusing bundle: duplicate entry "{name}"',
  'import.manifest_unlisted':
      'refusing bundle: manifest "{name}" is not listed in carry.json',
  'import.manifest_mismatch':
      'refusing bundle: manifest "{name}" does not match carry.json (size or '
      'SHA-256 differs)',
  'import.unexpected_entry':
      'refusing bundle: unexpected entry "{name}". Allowed: carry.json, '
      'manifests/<host>/<namespace>/<model>/<tag>, blobs/sha256-<64 hex>',
  'import.blob_unlisted':
      'refusing bundle: blob "{name}" is not listed in carry.json or its size '
      'differs ({actual} vs {expected})',
  'import.blob_damaged':
      'blob {digest} is damaged in the bundle (its content hashes to '
      '{actual}).\n{where}\nNothing was written to {path}.',
  'import.incomplete_manifest':
      'bundle is incomplete: manifest of {name} is missing. Copy all parts '
      'again.',
  'import.incomplete_blob':
      'bundle is incomplete: blob {digest} is missing. Copy all parts again.',
  'import.ref_mismatch':
      'refusing bundle: {manifest} references {digest} which carry.json does '
      'not list with the same size',
  'import.tar': '{problem} (at byte {offset} of the bundle).\n{where}',
  'import.copy_incomplete': 'copy to {path} was incomplete',
  // Which part of a split bundle holds a problem.
  'problem.damaged_one':
      'the data is in part {parts}.\npart {damaged}: checksum does NOT match '
      'the .sha256 list - copy this part again.',
  'problem.damaged_many':
      'the data is in part {parts}.\npart {damaged}: checksum does NOT match '
      'the .sha256 list - copy these parts again.',
  'problem.unchecked':
      'the data is in part {parts}.\nno .sha256 list found next to the bundle, '
      'so the damaged part cannot be named; copy all parts again.',
  'problem.exported_bad':
      'the data is in part {parts}.\nall those parts match the .sha256 list, '
      'so the bundle was already damaged when it was exported; export it '
      'again.',
  // Library errors: manifests, mock, names, sizes, parts, store.
  'manifest.not_json': '{source} is not valid JSON',
  'manifest.not_object': '{source} is not a JSON object',
  'manifest.no_layers': '{source} has no "layers" list',
  'manifest.layer_not_object': '{source} has a layer that is not an object',
  'manifest.layer_incomplete': '{source} has a layer without digest and size',
  'mock.size': 'weights size must be at least 1 byte',
  'mock.not_empty':
      '{path} already contains models; choose an empty folder for the practice '
      'models',
  'model.empty': 'model name is empty',
  'model.invalid':
      'invalid model name "{name}": use [host/][namespace/]model[:tag]',
  'model.bad_path':
      'invalid manifest path "{path}": expected '
      'manifests/<host>/<namespace>/<model>/<tag>',
  'model.bad_entry': 'invalid manifest entry name "{name}"',
  'model.bad_part':
      'invalid model name "{name}": each part must use only letters, digits, '
      '"." "_" "-" and must not be empty or start with "."',
  'size.invalid':
      'invalid size "{text}": use a number with an optional K, M or G (for '
      'example 512K or 3.9G) or "fat32"',
  'size.small': 'size "{text}" is too small; the minimum part size is 1K',
  'parts.not_found':
      'bundle not found: {path} (also looked for {first}). Pass the first '
      'part, for example bundle.carry.tar.000',
  'parts.first_missing':
      'part {name} is missing; copy all parts of the bundle into the same '
      'folder',
  'parts.gap':
      'part {name} is missing (found {found} but not the part before it); copy '
      'that part again',
  'parts.listed_missing':
      '{name} is listed in {list} but is not in this folder; copy it again',
  'store.no_home':
      'cannot find your home folder; pass --models <folder> or set '
      'OLLAMA_MODELS',
  'store.not_installed':
      'model "{name}" is not installed in {path}. Run `ollama-carry list` to '
      'see installed models.',
  'store.not_installed_hint':
      'model "{name}" is not installed in {path}. Run `ollama-carry list` to '
      'see installed models, or pass --models <folder>.',
  // Library errors: tar.
  'tar.pax_large': 'PAX header is too large',
  'tar.pax_size': 'invalid PAX size record',
  'tar.no_end':
      'bundle ends without an end-of-archive marker; a part file is probably '
      'missing or truncated',
  'tar.mid_header': 'bundle ends in the middle of a header',
  'tar.mid_entry':
      'bundle ends in the middle of an entry; a part file is probably missing '
      'or truncated',
  'tar.early': 'bundle ends early',
  'tar.checksum': 'invalid tar header checksum (the data is damaged)',
  'tar.size_field': 'invalid size field',
  'tar.pax_header': 'invalid PAX header',
};

const Map<String, String> _ko = {
  'usage.main': '''
ollama-carry {version} - Ollama 모델을 오프라인으로 다른 컴퓨터에 옮깁니다.

사용법: ollama-carry <명령> [옵션]

명령:
  where                         사용하는 모델 폴더와 선택 이유를 보여 줍니다.
  list                          설치된 모델과 크기를 나열합니다.
  export <model>... -o <file>   모델을 tar 하나로 묶습니다(공유 blob 은 한 번만).
                                --split 512K | 3.9G | fat32 로 나눌 수 있습니다.
  import <file|file.000>        모든 blob 을 SHA-256 으로 검증한 뒤 설치합니다.
                                --dry-run 은 미리보기, --force 는 모델 교체입니다.
  verify [<model>...]           설치된 blob 을 검사합니다(정상 / 누락 / 손상).
                                --json 은 기계가 읽는 출력을 냅니다.
  mock <dir>                    가짜 가중치로 연습용(mock) 모델을 만듭니다.
  tour                          임시 폴더의 연습 데이터로 전체 흐름을 실행합니다.

where/list/export/import/verify 옵션: --models <dir>
  (기본값: OLLAMA_MODELS, 없으면 OS 기본 폴더).

언어: --lang en|ko, 없으면 OLLAMA_CARRY_LANG, LC_ALL, LC_MESSAGES, LANG 순
  (한국어가 아니면 영어로 출력합니다).

종료 코드: 0 정상, 1 무결성 문제, 2 사용법 오류 또는 없는 모델,
3 모델 이름 충돌(--force 사용).
''',
  'cmd.where': '사용법: ollama-carry where [옵션]',
  'cmd.list': '사용법: ollama-carry list [옵션]',
  'cmd.export': '사용법: ollama-carry export <model>... -o <file> [옵션]',
  'cmd.import': '사용법: ollama-carry import <file|file.000> [옵션]',
  'cmd.verify': '사용법: ollama-carry verify [<model>...] [옵션]',
  'cmd.mock': '사용법: ollama-carry mock <dir> [옵션]',
  'cmd.tour': '사용법: ollama-carry tour [옵션]',
  'opt.help': '이 도움말을 보여 줍니다.',
  'opt.lang': '출력 언어: en 또는 ko.',
  'opt.output': '만들 번들 파일.',
  'opt.split': '조각 크기(512K, 3.9G, "fat32" 등). 기본값: 파일 하나.',
  'opt.dry_run': '실행 결과만 보여 주고 아무것도 쓰지 않습니다.',
  'opt.force': '내용이 다른 모델을 교체합니다.',
  'opt.json': 'JSON 출력.',
  'opt.weights_size': '가짜 가중치 크기(바이트, K/M/G 사용 가능).',
  'opt.models': 'Ollama 모델 폴더.',
  'word.yes': '예',
  'word.no': '아니요',
  'word.some': '일부 있음',
  'word.none': '없음',
  'status.ok': '정상',
  'status.missing': '누락',
  'status.corrupt': '손상',
  'error.prefix': '오류: ',
  'error.fs': '{message}: {path} ({os}). 경로와 권한을 확인하세요.',
  'error.fs_generic': '파일 시스템 오류',
  'error.unknown_command':
      '알 수 없는 명령: "{command}". `ollama-carry --help` 를 실행하세요.',
  'error.export_no_output':
      '-o <file> 이 없습니다. 예: `ollama-carry export llama3 -o '
      '/path/llama3.carry.tar`',
  'error.import_one': '번들을 정확히 하나 지정하세요: `ollama-carry import <file|file.000>`',
  'error.mock_one': '빈 폴더를 하나 지정하세요: `ollama-carry mock <dir>`',
  'args.no_option': '"{name}" 옵션이 없습니다.',
  'args.no_flag': '"{name}" 옵션이나 플래그가 없습니다.',
  'args.no_short': '"{name}" 짧은 옵션이 없습니다.',
  'args.missing_value': '"{name}" 옵션에 값이 없습니다.',
  'args.bad_value': '"{name}" 옵션에 허용되지 않는 값: "{value}"',
  'args.with_usage': '{problem}\n{usage}',
  'args.flag_value': '"{name}" 플래그는 값을 받지 않습니다.',
  'where.folder': '모델 폴더: {path}',
  'where.reason': '선택 근거: {reason}',
  'where.exists': '존재 여부: {value}',
  'where.models': '모델 수: {count}',
  'reason.models_option': '--models 옵션',
  'reason.env': 'OLLAMA_MODELS 환경 변수',
  'reason.service': '리눅스 서비스 폴더(manifests/ 가 있음)',
  'reason.default': '{os} 기본 폴더 (~/.ollama/models)',
  'list.empty': '모델이 없습니다: {path} (`ollama-carry where` 참고)',
  'list.summary':
      '모델 {count}개, 합계 {listed}, 디스크 사용량 {disk} (공유 blob 은 한 번만 계산)',
  'export.start': '내보내는 곳: {path}',
  'export.wrote_part': '기록: {path}  {size}',
  'export.wrote_sums': '기록: {path}  (sha256sum 형식)',
  'export.summary':
      '모델 {models}개, 고유 blob {blobs}개, {bytes}; 공유로 절약한 크기 {saved}',
  'export.log_blob': '  blob {digest}  {size}',
  'import.start': '설치 대상 폴더: {path}',
  'import.start_dry': '미리보기: 설치 대상 폴더 {path}',
  'import.note_prune':
      '참고: 가져오는 동안 Ollama 서버를 멈추거나 OLLAMA_NOPRUNE=1 을 설정하세요. '
      '아직 매니페스트가 없는 blob 을 서버가 지울 수 있습니다.',
  'import.models': '모델: {names}',
  'import.counts': '모델: 새로 {new}, 변경 없음 {unchanged}, 교체 {replaced}',
  'import.blobs': 'blob: 기록 {count} ({bytes}), 건너뜀 {skipped}',
  'import.blobs_dry': 'blob: 기록 예정 {count} ({bytes}), 건너뜀 {skipped}',
  'import.dry_note':
      '미리보기: blob 내용은 해시하지 않았습니다. --dry-run 없이 실행하면 '
      '검증하고 설치합니다.',
  'import.chown_hint':
      '힌트: Ollama 가 "ollama" 사용자로 실행된다면 {path} 폴더의 소유자를 '
      '그 사용자로 바꾸세요 (chown -R ollama:ollama)',
  'import.log_skip': '  건너뜀  {digest}  (설치되어 있음, 번들 사본 해시 확인)',
  'import.log_hash': '  해시 확인 {digest}  {size}  (임시 보관)',
  'mock.created':
      '연습용(mock) 모델을 만들었습니다: {path} - 가짜 가중치, Ollama 와 같은 '
      '구조와 해시 규칙입니다. 다음을 실행해 보세요:',
  'verify.invalid': '손상됨  매니페스트 {name}: {why}',
  'verify.sum_ok': '정상: {count}',
  'verify.sum_missing': '누락: {count}',
  'verify.sum_corrupt': '손상: {count}',
  'verify.d_missing': '없는 위치: {path}',
  'verify.d_size': '실제 크기 {actual}, 매니페스트 기록 {expected}',
  'verify.d_hash': '내용이 해시와 다릅니다',
  'tour.intro': '둘러보기: 연습용(mock) 모델, 가짜 가중치 - `ollama run` 으로는 실행되지 않습니다',
  'tour.s1': '\n1. 연습용 모델 폴더 만들기',
  'tour.model': '   {name}  {size}',
  'tour.s2': '\n2. tiny:latest 와 tiny:chat 을 512K 조각으로 내보내기',
  'tour.exported':
      '   조각 {parts}개, 고유 blob {blobs}개, 공유 blob 은 한 번만 저장 '
      '(절약 {saved})',
  'tour.s3': '\n3. 빈 폴더로 가져오기 (첫 조각만 지정하면 됩니다)',
  'tour.imported': '   blob: 기록 {written}, 건너뜀 {skipped}',
  'tour.again': '   다시 실행: 기록 {written}, 건너뜀 {skipped}',
  'tour.s4': '\n4. 설치된 사본 검증하기',
  'tour.counts': '   정상: {ok}, 누락: {missing}, 손상: {corrupt}',
  'tour.s5': '\n5. blob 한 바이트를 망가뜨린 뒤 검증하기',
  'tour.s6': '\n6. 조각 안의 한 바이트를 망가뜨린 뒤 다른 곳으로 가져오기',
  'tour.refused': '   거부됨: blob {digest}... 손상',
  'tour.refused_other': '   거부됨: {first}',
  'tour.files': '   대상 폴더에 기록된 파일: {value}',
  'tour.ok': '둘러보기: 성공',
  'tour.failed': '둘러보기 실패: 손상된 조각을 받아들였습니다',
  'bundle.json_invalid':
      'carry.json 이 올바른 JSON 이 아닙니다. ollama-carry 로 만든 번들이 맞나요?',
  'bundle.not_object': 'carry.json 이 JSON 객체가 아닙니다',
  'bundle.format':
      '지원하지 않는 번들 형식: "{format}" (이 버전은 "{supported}" 만 읽습니다). '
      '이 컴퓨터의 ollama-carry 를 업데이트하세요',
  'bundle.missing_fields': 'carry.json 에 "models" 또는 "blobs" 가 없습니다',
  'bundle.bad_model': 'carry.json 에 잘못된 모델 항목이 있습니다',
  'bundle.bad_blob': 'carry.json 에 잘못된 blob 항목이 있습니다',
  'digest.invalid': '잘못된 다이제스트 "{raw}": sha256:<16진수 64자> 형식이어야 합니다',
  'export.no_models':
      '모델 이름을 하나 이상 지정하세요. 예: `ollama-carry export llama3 -o '
      'bundle.carry.tar`',
  'export.size_conflict':
      '{digest}: 매니페스트마다 크기가 다릅니다. 저장소가 일관되지 않습니다. '
      '`ollama-carry verify` 를 실행하세요.',
  'export.blob_missing':
      'blob 없음: {digest} (폴더: {dir}). `ollama-carry verify` 를 실행하고 '
      '이 컴퓨터에서 모델을 다시 받으세요.',
  'export.blob_size':
      'blob {digest}: 실제 {actual} 바이트, 매니페스트 기록 {expected} 바이트. '
      '`ollama-carry verify` 를 실행하세요.',
  'export.exists': '이미 있음: {path}. 다른 -o 이름을 쓰거나 이전 번들을 먼저 삭제하세요.',
  'export.blob_changed':
      '저장소의 blob {digest}: 해시가 다릅니다(손상되었거나 내보내는 중에 '
      '바뀌었습니다). 아무것도 내보내지 않았습니다. `ollama-carry verify` 를 '
      '실행하고 모델을 다시 받으세요.',
  'import.not_bundle': 'ollama-carry 번들이 아닙니다(첫 항목이 carry.json 이어야 합니다)',
  'import.index_large': 'carry.json 이 비정상적으로 커서 거부합니다',
  'import.conflicts':
      '이미 있는 모델과 내용이 다릅니다: {names}. 아무것도 기록하지 않았습니다. '
      '교체하려면 --force 를 사용하세요.',
  'import.not_plain':
      '번들 거부: 일반 파일이 아닌 항목: "{name}" (유형 "{type}"). '
      '링크와 특수 파일은 허용하지 않습니다',
  'import.duplicate': '번들 거부: 중복된 항목 "{name}"',
  'import.manifest_unlisted': '번들 거부: carry.json 에 없는 매니페스트: "{name}"',
  'import.manifest_mismatch':
      '번들 거부: carry.json 과 다른 매니페스트: "{name}" (크기 또는 SHA-256)',
  'import.unexpected_entry':
      '번들 거부: 예상하지 못한 항목 "{name}". 허용: carry.json, '
      'manifests/<host>/<namespace>/<model>/<tag>, blobs/sha256-<16진수 64자>',
  'import.blob_unlisted':
      '번들 거부: carry.json 에 없거나 크기가 다른 blob: "{name}" '
      '({actual} / {expected})',
  'import.blob_damaged':
      '번들 안의 blob 손상: {digest} (내용의 해시: {actual}).\n'
      '{where}\n{path} 에는 아무것도 기록하지 않았습니다.',
  'import.incomplete_manifest':
      '번들이 불완전합니다: {name} 매니페스트가 없습니다. 모든 조각을 다시 복사하세요.',
  'import.incomplete_blob': '번들이 불완전합니다: blob {digest} 누락. 모든 조각을 다시 복사하세요.',
  'import.ref_mismatch':
      '번들 거부: 참조 불일치 - 매니페스트: {manifest}, blob: {digest} '
      '(carry.json 에 같은 크기로 등록되어 있지 않습니다)',
  'import.tar': '{problem} (번들의 {offset} 번째 바이트).\n{where}',
  'import.copy_incomplete': '복사가 끝까지 되지 않았습니다: {path}',
  'problem.damaged_one':
      '데이터 위치: 조각 {parts}.\n조각 {damaged}: 체크섬이 .sha256 목록과 '
      '다릅니다 - 이 조각을 다시 복사하세요.',
  'problem.damaged_many':
      '데이터 위치: 조각 {parts}.\n조각 {damaged}: 체크섬이 .sha256 목록과 '
      '다릅니다 - 이 조각들을 다시 복사하세요.',
  'problem.unchecked':
      '데이터 위치: 조각 {parts}.\n번들 옆에 .sha256 목록이 없어 손상된 조각을 '
      '특정할 수 없습니다. 모든 조각을 다시 복사하세요.',
  'problem.exported_bad':
      '데이터 위치: 조각 {parts}.\n해당 조각은 모두 .sha256 목록과 일치합니다. '
      '내보낼 때 이미 번들이 손상되어 있었으니 다시 내보내세요.',
  'manifest.not_json': '{source}: 올바른 JSON 이 아닙니다',
  'manifest.not_object': '{source}: JSON 객체가 아닙니다',
  'manifest.no_layers': '{source}: "layers" 목록이 없습니다',
  'manifest.layer_not_object': '{source}: 객체가 아닌 layer 가 있습니다',
  'manifest.layer_incomplete': '{source}: digest 와 size 가 없는 layer 가 있습니다',
  'mock.size': '가중치 크기는 1바이트 이상이어야 합니다',
  'mock.not_empty': '이미 모델이 있는 폴더입니다: {path}. 연습용 모델은 빈 폴더에 만드세요',
  'model.empty': '모델 이름이 비어 있습니다',
  'model.invalid':
      '잘못된 모델 이름 "{name}": [host/][namespace/]model[:tag] 형식으로 쓰세요',
  'model.bad_path':
      '잘못된 매니페스트 경로 "{path}": '
      'manifests/<host>/<namespace>/<model>/<tag> 형식이어야 합니다',
  'model.bad_entry': '잘못된 매니페스트 항목 이름 "{name}"',
  'model.bad_part':
      '잘못된 모델 이름 "{name}": 각 부분은 영문자, 숫자, "." "_" "-" 만 쓸 수 '
      '있고 비어 있거나 "." 로 시작하면 안 됩니다',
  'size.invalid':
      '잘못된 크기 "{text}": 숫자에 K, M, G 를 붙이거나(예: 512K, 3.9G) '
      '"fat32" 를 쓰세요',
  'size.small': '크기가 너무 작습니다: "{text}". 조각의 최소 크기는 1K 입니다',
  'parts.not_found':
      '번들을 찾을 수 없습니다: {path} (다음 이름도 찾아봤습니다: {first}). '
      '첫 조각을 지정하세요. 예: bundle.carry.tar.000',
  'parts.first_missing': '조각 누락: {name}. 번들의 모든 조각을 같은 폴더에 복사하세요',
  'parts.gap':
      '조각 누락: {name} (찾은 파일: {found}, 그 앞 조각이 없음). '
      '해당 조각을 다시 복사하세요',
  'parts.listed_missing': '{name}: {list} 에 적혀 있지만 이 폴더에 없습니다. 다시 복사하세요',
  'store.no_home':
      '홈 폴더를 찾을 수 없습니다. --models <folder> 를 지정하거나 '
      'OLLAMA_MODELS 를 설정하세요',
  'store.not_installed':
      '설치되지 않은 모델: "{name}" ({path}). `ollama-carry list` 로 설치된 '
      '모델을 확인하세요.',
  'store.not_installed_hint':
      '설치되지 않은 모델: "{name}" ({path}). `ollama-carry list` 로 설치된 '
      '모델을 확인하거나 --models <folder> 를 지정하세요.',
  'tar.pax_large': 'PAX 헤더가 너무 큽니다',
  'tar.pax_size': 'PAX 크기 레코드가 잘못되었습니다',
  'tar.no_end': '번들이 끝 표시 없이 끝났습니다. 조각 파일이 없거나 잘렸을 수 있습니다',
  'tar.mid_header': '번들이 헤더 중간에서 끝났습니다',
  'tar.mid_entry': '번들이 항목 중간에서 끝났습니다. 조각 파일이 없거나 잘렸을 수 있습니다',
  'tar.early': '번들이 예상보다 일찍 끝났습니다',
  'tar.checksum': 'tar 헤더 체크섬이 잘못되었습니다(데이터 손상)',
  'tar.size_field': '크기 필드가 잘못되었습니다',
  'tar.pax_header': 'PAX 헤더가 잘못되었습니다',
};
