import 'package:zharp_core/zharp_core.dart' show newUuid;

String? _id;

/// On the web: one ID per page load. (A browser has no install; the session ID does the work.)
Future<String> fallbackInstallId(String service) async => _id ??= newUuid();
