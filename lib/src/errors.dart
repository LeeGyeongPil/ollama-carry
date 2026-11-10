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
  CarryException(this.message, {this.exitCode = exitIntegrity});

  /// Human readable message (printed after `error: `).
  final String message;

  /// Process exit code for this failure.
  final int exitCode;

  @override
  String toString() => message;
}
