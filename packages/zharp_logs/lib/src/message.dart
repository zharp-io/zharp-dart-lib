import 'dart:convert';

/// A log message as text.
///
/// Callers pass whatever they have — an exception, a map, `null` from a field that was not set.
/// The backend refuses an entry whose message is not non-empty text, so every path coerces here.
///
/// Returns `'(empty message)'` when there is nothing to show.
String toMessage(Object? value) {
  final String text;
  if (value == null) {
    text = '';
  } else if (value is String) {
    text = value;
  } else if (value is Map || value is List) {
    text = _encode(value) ?? value.toString();
  } else {
    // Exceptions and Errors read best through their own toString().
    text = value.toString();
  }
  return text.trim().isEmpty ? '(empty message)' : text;
}

/// Metadata as plain JSON values, copied now so a later change to the caller's map doesn't
/// change a log already waiting to be sent. Values JSON can't hold become text.
Map<String, Object?> toJsonMap(Map<String, Object?>? metadata) {
  if (metadata == null || metadata.isEmpty) return {};
  final encoded = _encode(metadata);
  if (encoded == null) return {'metadata': metadata.toString()};
  return (jsonDecode(encoded) as Map).cast<String, Object?>();
}

/// An error as plain fields: its type, its text, and — for an `Error` — where it was thrown.
Map<String, Object?> errorFields(Object error) => {
      'name': error.runtimeType.toString(),
      'message': error.toString(),
      if (error is Error && error.stackTrace != null) 'stack': error.stackTrace.toString(),
    };

/// The stack an error log should carry, found without the caller passing one: an `Error`'s own
/// (where it was thrown), else — an `Exception` carries none — where it was logged, starting at
/// the caller's code rather than inside this package.
String stackFor(Object error) {
  if (error is Error && error.stackTrace != null) return error.stackTrace.toString();
  return StackTrace.current
      .toString()
      .split('\n')
      .where((frame) => !frame.contains('package:zharp_logs/') && !frame.contains('package:zharp_logs_flutter/'))
      .join('\n');
}

String? _encode(Object value) {
  try {
    return jsonEncode(value, toEncodable: _toEncodable);
  } catch (_) {
    return null;
  }
}

Object? _toEncodable(Object? value) {
  // An error as its type, text and (for an Error) the stack it was thrown with — not just text.
  if (value is Error || value is Exception) return errorFields(value!);
  if (value is DateTime) return value.toUtc().toIso8601String();
  if (value is Duration) return value.inMilliseconds;
  if (value is Uri) return value.toString();
  if (value is Set) return value.toList();
  if (value is Enum) return value.name;
  return value.toString();
}
