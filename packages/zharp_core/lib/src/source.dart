// The app's own code with each error: read where a dart:io program runs; nothing on the web.
export 'source_web.dart' if (dart.library.io) 'source_io.dart';
