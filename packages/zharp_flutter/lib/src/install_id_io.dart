import 'dart:io';

import 'package:zharp_core/zharp_core.dart' show newUuid;

/// Where Android and iOS have no plugin answer (desktop, tests): an ID kept in a file in the
/// user's app-data folder, per service, so it survives restarts. If the file can't be written,
/// an ID for this run.
Future<String> fallbackInstallId(String service) async {
  final id = newUuid();
  try {
    final dir = _dataDir();
    if (dir == null) return id;
    final safe = service.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final file = File([dir, 'Zharp', safe, 'install_id'].join(Platform.pathSeparator));
    if (await file.exists()) {
      final existing = (await file.readAsString()).trim();
      if (existing.isNotEmpty) return existing;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(id, flush: true);
  } catch (_) {
    // Read-only home, sandbox: an ID for this run.
  }
  return id;
}

String? _dataDir() {
  final env = Platform.environment;
  if (Platform.isWindows) return env['LOCALAPPDATA'] ?? env['APPDATA'];
  final home = env['HOME'];
  if (Platform.isMacOS) return home == null ? null : '$home/Library/Application Support';
  if (Platform.isLinux) return env['XDG_DATA_HOME'] ?? (home == null ? null : '$home/.local/share');
  return null;
}
