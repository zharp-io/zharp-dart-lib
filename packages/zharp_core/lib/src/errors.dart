/// Turning a Dart error and its stack into the `exception.*` attributes Zharp reads.
library;

/// Frames from the SDK itself, left out of stacks the SDK had to capture on the caller's behalf.
final RegExp _sdkFrame = RegExp(r'package:zharp_(core|flutter|dio)/');

/// An error as Zharp files it.
class ExceptionDescription {
  ExceptionDescription(this.type, this.message, this.stacktrace);

  /// `StateError`, `SocketException`, `_TypeError`…
  final String type;

  /// The error's own text, e.g. `Bad state: cart is empty`.
  final String message;

  /// `Type: message` then the Dart frames (`#0 main (package:app/main.dart:5:3)`).
  final String stacktrace;

  Map<String, Object> attributes({required bool handled}) => {
        'exception.type': type,
        'exception.message': message,
        'exception.stacktrace': stacktrace,
        'zharp.handled': handled ? 'true' : 'false',
      };
}

/// Describe [error]. The stack is, in order: [stackTrace] when it has frames, the stack an
/// `Error` was thrown with, or — an `Exception` carries none — where this was called, without
/// the SDK's own frames.
ExceptionDescription describeError(Object error, StackTrace? stackTrace) {
  final type = _typeOf(error);
  final message = _messageOf(error);
  var frames = _framesOf(stackTrace);
  if (frames.isEmpty && error is Error) frames = _framesOf(error.stackTrace);
  if (frames.isEmpty) {
    frames = _framesOf(StackTrace.current).where((line) => !_sdkFrame.hasMatch(line)).toList();
  }
  final header = message.isEmpty ? type : '$type: ${message.split('\n').first}';
  return ExceptionDescription(type, message, [header, ...frames].join('\n'));
}

String _typeOf(Object error) {
  try {
    final type = error.runtimeType.toString();
    // `Exception('x')` is a private _Exception; it reads best as what was written.
    return type == '_Exception' ? 'Exception' : type;
  } catch (_) {
    return 'Object';
  }
}

String _messageOf(Object error) {
  try {
    final text = error.toString();
    // `FormatException: bad json`, `Exception: x`: the type is already said; don't say it twice.
    final prefix = '${_typeOf(error)}: ';
    return text.startsWith(prefix) ? text.substring(prefix.length) : text;
  } catch (_) {
    return '';
  }
}

List<String> _framesOf(StackTrace? stackTrace) {
  if (stackTrace == null) return const [];
  final text = stackTrace.toString();
  if (text.trim().isEmpty) return const [];
  return text.split('\n').where((line) => line.trim().isNotEmpty).toList();
}

/// Errors already sent, so the same error object isn't reported twice — e.g. once by the span it
/// escaped from and again by the uncaught-error handler.
final Expando<bool> _reported = Expando<bool>('zharp.reported');

void markReported(Object error) {
  try {
    _reported[error] = true;
  } catch (_) {
    // Strings, numbers and booleans can't carry an Expando; those are never deduplicated.
  }
}

bool wasReported(Object error) {
  try {
    return _reported[error] ?? false;
  } catch (_) {
    return false;
  }
}
