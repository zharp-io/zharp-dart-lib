import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'install_id.dart';

/// The channel to the plugin's Android and iOS code.
const MethodChannel deviceChannel = MethodChannel('io.zharp/flutter');

/// Device, OS and app context for the resource: `device.id`, `device.model.name`,
/// `device.model.identifier`, `device.manufacturer`, `os.name`, `os.version` — plus the app's
/// version, used as the release when none is set.
///
/// Android and iOS ask the plugin; elsewhere (desktop, web, tests) what Dart knows is used, and
/// the install ID is kept in a file (desktop) or for this run only (web).
Future<({Map<String, Object> resource, String? release})> collectDeviceContext(String service) async {
  Map<Object?, Object?>? native;
  try {
    native = await deviceChannel
        .invokeMapMethod<Object?, Object?>('deviceInfo')
        .timeout(const Duration(seconds: 30), onTimeout: () => null);
  } catch (_) {
    // MissingPluginException on platforms without native code, or a plugin failure: fall back.
  }
  String? text(String key) {
    final value = native?[key];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  final resource = <String, Object>{};
  final model = text('model');
  final manufacturer = text('manufacturer');
  if (model != null) {
    resource['device.model.identifier'] = model;
    resource['device.model.name'] = modelName(manufacturer, model);
  }
  if (manufacturer != null) resource['device.manufacturer'] = manufacturer;
  final osName = text('osName');
  final osVersion = text('osVersion');
  if (osName != null) resource['os.name'] = osName;
  if (osVersion != null) resource['os.version'] = osVersion;
  resource['device.id'] = text('installId') ?? await fallbackInstallId(service);
  if (kIsWeb) resource['os.name'] = 'web';

  final appId = text('appId');
  final version = text('appVersion');
  final build = text('appBuild');
  final release = version == null ? null : '${appId != null ? '$appId@' : ''}$version${build != null ? '+$build' : ''}';
  return (resource: resource, release: release);
}

/// "Google Pixel 8", "samsung SM-S911B" — the manufacturer once, then the model.
String modelName(String? manufacturer, String model) {
  if (manufacturer == null || model.toLowerCase().startsWith(manufacturer.toLowerCase())) return model;
  if (manufacturer == 'Apple') return model;
  return '$manufacturer $model';
}
