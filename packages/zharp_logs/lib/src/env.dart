import 'platform.dart';

/// Values compiled in with `--dart-define=ZHARP_API_KEY=…`. The only kind of configuration a
/// Flutter app or a web build can be given without code.
const Map<String, String> _defines = {
  'ZHARP_API_KEY': String.fromEnvironment('ZHARP_API_KEY'),
  'ZHARP_SERVICE': String.fromEnvironment('ZHARP_SERVICE'),
  'OTEL_SERVICE_NAME': String.fromEnvironment('OTEL_SERVICE_NAME'),
  'ZHARP_ENV': String.fromEnvironment('ZHARP_ENV'),
  'ZHARP_VERSION': String.fromEnvironment('ZHARP_VERSION'),
  'ZHARP_SOURCE': String.fromEnvironment('ZHARP_SOURCE'),
  'ZHARP_ENDPOINT': String.fromEnvironment('ZHARP_ENDPOINT'),
  'ZHARP_CAPTURE_PRINT': String.fromEnvironment('ZHARP_CAPTURE_PRINT'),
  'ZHARP_DISABLED': String.fromEnvironment('ZHARP_DISABLED'),
};

/// A setting from the environment: a `--dart-define`, then the process's environment variable.
String? envValue(String name) => pick([_defines[name], processEnv(name)]);

/// The first value that is non-blank text — explicit option, then each fallback in turn.
String? pick(List<String?> values) {
  for (final value in values) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

/// `ZHARP_DISABLED=true` (or `1`, `yes`, `on`): start nothing, whatever the code asks for.
bool disabledByEnv() {
  final value = envValue('ZHARP_DISABLED');
  return value != null && RegExp(r'^(true|1|yes|on)$', caseSensitive: false).hasMatch(value);
}

bool? flagOf(String? value) {
  if (value == null) return null;
  if (RegExp(r'^(true|1|yes|on|all)$', caseSensitive: false).hasMatch(value)) return true;
  if (RegExp(r'^(false|0|no|off|none)$', caseSensitive: false).hasMatch(value)) return false;
  return null;
}

/// `service "checkout-api", environment "production"` — what the startup line reports.
String describeTarget(String service, String? environment) =>
    'service "$service", ${environment != null ? 'environment "$environment"' : 'no environment set'}';

/// Startup output. One prefix, so it can be searched for — and left out of print capture.
void announce(String message) => print('[Zharp] $message');
