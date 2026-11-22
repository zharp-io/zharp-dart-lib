import 'package:flutter_web_plugins/flutter_web_plugins.dart';

/// The web has no native side: everything runs in Dart. Declared so Flutter (and pub.dev) know
/// the plugin supports the web.
class ZharpFlutterWeb {
  static void registerWith(Registrar registrar) {}
}
