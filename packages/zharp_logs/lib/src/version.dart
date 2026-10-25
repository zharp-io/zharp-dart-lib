/// This package's version.
const String version = '0.1.0';

/// What requests from this SDK say they are, in the `X-Zharp-SDK` header — `dart-logs/0.1.0`.
///
/// `zharp_logs_flutter` sets it to its own name, so the backend can tell which one sent what.
String sdkName = 'dart-logs/$version';
