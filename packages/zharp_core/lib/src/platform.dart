// What differs between dart:io platforms (mobile, desktop, servers) and the web.
export 'platform_web.dart' if (dart.library.io) 'platform_io.dart';
