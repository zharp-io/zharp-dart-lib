import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zharp_logs_demo/main.dart';
import 'package:zharp_logs_flutter/zharp_logs_flutter.dart';

/// Taps every button against a fake Zharp API and checks what each one sent.
void main() {
  final requests = <http.Request>[];
  final client = MockClient((request) async {
    requests.add(request);
    return http.Response('{}', 202);
  });
  List<Map<String, dynamic>> logs() =>
      [for (final r in requests) ...(jsonDecode(r.body)['logs'] as List).cast<Map<String, dynamic>>()];

  Future<void> tap(WidgetTester tester, String label) async {
    final button = find.text(label);
    await tester.scrollUntilVisible(button, 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(button);
    await tester.pump();
  }

  testWidgets('every button sends what it says', (tester) async {
    tester.view.physicalSize = const Size(1400, 2400);
    addTearDown(tester.view.resetPhysicalSize);
    ZharpFlutter.init(
      apiKey: 'test-key',
      service: 'zharp-logs-demo',
      environment: 'development',
      appVersion: '1.0.0',
      capturePrint: true,
      httpClient: client,
      flushInterval: const Duration(minutes: 1),
    );
    await tester.pumpWidget(const DemoApp());
    expect(find.text('Sending to Zharp'), findsOneWidget);

    for (final label in ['debug', 'info', 'warn', 'error', 'fatal', 'Caught exception', 'As another service', 'Set user context', 'debugPrint']) {
      await tap(tester, label);
    }
    await tap(tester, 'Throw in a tap');
    expect(tester.takeException(), isA<StateError>());
    await tester.runAsync(ZharpLogger.flushAll);

    final byMessage = {for (final l in logs()) l['message'] as String: l};
    expect(byMessage['Cache miss']!['level'], 'debug');
    expect(byMessage['User signed in']!['level'], 'info');
    expect(byMessage['Slow network detected']!['level'], 'warn');
    expect(byMessage['Payment failed']!['level'], 'error');
    expect(byMessage['Database connection lost']!['level'], 'fatal');
    expect((byMessage['FormatException: Row 12: missing price']!['metadata'] as Map)['stack'], isNotEmpty);
    expect(byMessage['Charge created']!['service'], 'payment-service');
    expect((byMessage['Cart has 3 items']!['metadata'] as Map)['origin'], 'debugPrint');
    final crash = byMessage['Bad state: Button handler blew up']!;
    expect((crash['metadata'] as Map)['type'], 'flutterError');
    // Set user context came before the crash, so the crash carries the user.
    expect(((crash['metadata'] as Map)['context'] as Map)['userId'], 'u-7');
    expect(requests.first.headers['x-zharp-sdk'], startsWith('flutter-logs/'));

    await tester.runAsync(ZharpFlutter.close);
  });
}
