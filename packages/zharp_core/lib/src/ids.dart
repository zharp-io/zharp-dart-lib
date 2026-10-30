import 'dart:math';

final Random _random = _secureOrFallback();

Random _secureOrFallback() {
  try {
    return Random.secure();
  } catch (_) {
    // A platform without a secure source: IDs only need to be unique, not secret.
    return Random();
  }
}

String _hex(int bytes) {
  final buffer = StringBuffer();
  for (var i = 0; i < bytes; i++) {
    buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

String _nonZeroHex(int bytes) {
  while (true) {
    final id = _hex(bytes);
    if (!_allZeros.hasMatch(id)) return id;
  }
}

final RegExp _allZeros = RegExp(r'^0+$');

/// A W3C trace ID: 32 lowercase hex characters, never all zeros.
String newTraceId() => _nonZeroHex(16);

/// A W3C span ID: 16 lowercase hex characters, never all zeros.
String newSpanId() => _nonZeroHex(8);

/// A random (version 4) UUID, for session and install IDs.
String newUuid() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// A number in [0, 1), for sampling.
double randomUnit() => _random.nextDouble();

final RegExp _traceIdPattern = RegExp(r'^[0-9a-f]{32}$');
final RegExp _spanIdPattern = RegExp(r'^[0-9a-f]{16}$');

bool isValidTraceId(String id) => _traceIdPattern.hasMatch(id) && !_allZeros.hasMatch(id);
bool isValidSpanId(String id) => _spanIdPattern.hasMatch(id) && !_allZeros.hasMatch(id);
