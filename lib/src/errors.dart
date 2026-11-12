import 'i18n.dart';

/// Exit codes used by the CLI.
const int exitOk = 0;

/// Integrity problem: hash mismatch, missing blob, refused bundle.
const int exitIntegrity = 1;

/// Usage error or unknown model.
const int exitUsage = 2;

/// A different manifest with the same model name already exists.
const int exitConflict = 3;

/// An error with a message that tells the user how to fix it.
class CarryException implements Exception {
  /// Creates an exception that the CLI maps to [exitCode].
  ///
  /// [code] and [params] are optional: when set, the CLI prints the message
  /// in the chosen language; [message] stays English.
  CarryException(
    this.message, {
    this.exitCode = exitIntegrity,
    this.code,
    this.params = const {},
  });

  /// Creates an exception from a message [code] (see `i18n.dart`); [message]
  /// is the English text.
  factory CarryException.coded(
    String code, {
    Map<String, Object?> params = const {},
    int exitCode = exitIntegrity,
  }) => CarryException(
    tr('en', code, params),
    exitCode: exitCode,
    code: code,
    params: params,
  );

  /// Human readable message (printed after `error: `).
  final String message;

  /// Process exit code for this failure.
  final int exitCode;

  /// Message code for translation, or null for a plain message.
  final String? code;

  /// Values for the `{name}` markers of [code].
  final Map<String, Object?> params;

  /// The message in [lang] (`en` or `ko`); plain messages stay as they are.
  String localized(String lang) =>
      code == null ? message : tr(lang, code!, params);

  /// This error as a nested message (or its plain text).
  Object asMsg() => code == null ? message : Msg(code!, params);

  @override
  String toString() => message;
}
