// A hands-off run on a device or emulator: starts Zharp, opens a screen that makes a request,
// logs, reports a caught and an uncaught error, then goes to the background (which flushes).
//
//   flutter run -t lib/smoke.dart --dart-define=ZHARP_KEY=zpk_… \
//     --dart-define=ZHARP_ENDPOINT=http://10.0.2.2:3000/api/v1/otlp
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zharp_flutter/zharp_flutter.dart';

import 'main.dart' show PostsScreen, api;

Future<void> main() async {
  await Zharp.init(const ZharpOptions(
    key: String.fromEnvironment('ZHARP_KEY'),
    service: 'zharp-flutter-smoke',
    environment: 'smoke',
    endpoint: String.fromEnvironment('ZHARP_ENDPOINT'),
    tracingOrigins: ['jsonplaceholder.typicode.com'],
    debug: true,
  ));
  Zharp.setUser(id: 'smoke-user', email: 'smoke@zharp.test');
  final navigator = GlobalKey<NavigatorState>();
  runApp(MaterialApp(
    navigatorKey: navigator,
    navigatorObservers: [ZharpNavigatorObserver()],
    routes: {
      '/': (_) => const Scaffold(body: Center(child: Text('home'))),
      '/posts': (_) => const PostsScreen(),
    },
  ));
  await Future<void>.delayed(const Duration(seconds: 1));
  unawaited(navigator.currentState!.pushNamed('/posts'));
  await Future<void>.delayed(const Duration(seconds: 3));
  Zharp.log.info('Smoke log', {'step': 'after posts'});
  try {
    throw StateError('smoke caught error');
  } catch (error, stack) {
    Zharp.captureError(error, stackTrace: stack);
  }
  Timer.run(() => throw StateError('smoke uncaught error'));
  await Future<void>.delayed(const Duration(seconds: 1));
  await api.get(Uri.parse('https://jsonplaceholder.typicode.com/todos/1'));
  await Zharp.flush();
  debugPrint('[smoke] done, session ${Zharp.sessionId}');
}
