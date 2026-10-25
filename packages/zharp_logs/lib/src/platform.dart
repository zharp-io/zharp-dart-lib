// What differs between platforms with dart:io (servers, CLIs, mobile, desktop) and without it
// (the web): environment variables, runtime context, and ending the process after a crash.
export 'platform_web.dart' if (dart.library.io) 'platform_io.dart';
