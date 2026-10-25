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

String? _encode(Object value) {
  try {
    return jsonEncode(value, toEncodable: _toEncodable);
  } catch (_) {
    return null;
  }
}

Object? _toEncodable(Object? value) {
  if (value is DateTime) return value.toUtc().toIso8601String();
  if (value is Duration) return value.inMilliseconds;
  if (value is Uri) return value.toString();
  if (value is Set) return value.toList();
  if (value is Enum) return value.name;
  return value.toString();
}
