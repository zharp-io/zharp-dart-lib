import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zharp_logs_flutter/zharp_logs_flutter.dart';

/// Try zharp_logs_flutter by hand: every log level, caught and uncaught errors, Flutter errors.
///
/// Run with your Ingest-only key (it stays out of the code):
///
///   flutter run -d windows --dart-define=ZHARP_API_KEY=your-ingest-only-key
///
/// Then open Logs on zharp.io and pick the "zharp-logs-demo" service.
void main() {
  ZharpFlutter.init(
    service: 'zharp-logs-demo',
    environment: 'development',
    appVersion: '1.0.0',
    // So the debugPrint button is sent too.
    capturePrint: true,
  );
  runApp(const DemoApp());
}

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Zharp logs demo',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF3BD671), useMaterial3: true, brightness: Brightness.dark),
      home: const DemoPage(),
    );
  }
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  int _sent = 0;
  bool _overflow = false;
  bool _brokenImage = false;

  /// Runs [action] and says what it did at the bottom of the screen.
  void _do(String what, void Function() action) {
    action();
    setState(() => _sent++);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(what), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final active = ZharpLogger.isActive;
    return Scaffold(
      appBar: AppBar(title: const Text('Zharp logs demo')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusCard(active: active, actions: _sent),
          const SizedBox(height: 16),

          _Section(
            title: 'Log levels',
            subtitle: 'debug, info and warn go out in the next batch (within 5 s); error and fatal at once.',
            children: [
              _button('debug', Icons.bug_report_outlined, () => _do('debug sent', () {
                    ZharpLogger.debug('Cache miss', {'key': 'user:42', 'store': 'memory'});
                  })),
              _button('info', Icons.info_outline, () => _do('info sent', () {
                    ZharpLogger.info('User signed in', {'userId': 42, 'method': 'password'});
                  })),
              _button('warn', Icons.warning_amber_outlined, () => _do('warn sent', () {
                    ZharpLogger.warn('Slow network detected', {'latencyMs': 3200});
                  })),
              _button('error', Icons.error_outline, () => _do('error sent', () {
                    ZharpLogger.error('Payment failed', {'orderId': 99, 'reason': 'insufficient_funds'});
                  })),
              _button('fatal', Icons.dangerous_outlined, () => _do('fatal sent', () {
                    ZharpLogger.fatal('Database connection lost', {'host': 'db-1'});
                  })),
            ],
          ),

          _Section(
            title: 'More ways to log',
            children: [
              _button('Caught exception', Icons.healing_outlined, () => _do('caught exception sent', () {
                    try {
                      throw const FormatException('Row 12: missing price');
                    } catch (e, stack) {
                      ZharpLogger.captureException(e, stack, metadata: {'row': 12});
                    }
                  })),
              _button('As another service', Icons.swap_horiz, () => _do('sent as "payment-service"', () {
                    ZharpLogger.log(LogLevel.info, 'Charge created', service: 'payment-service', metadata: {'amount': 500});
                  })),
              _button('Set user context', Icons.person_outline, () => _do('user u-7 added to every log from now on', () {
                    ZharpLogger.setContext({'userId': 'u-7', 'plan': 'pro'});
                  })),
              _button('debugPrint', Icons.terminal, () => _do('debugPrint sent (capturePrint is on)', () {
                    debugPrint('Cart has 3 items');
                  })),
              _button('Burst of 120', Icons.bolt_outlined, () => _do('120 info logs queued — sent in batches', () {
                    for (var i = 1; i <= 120; i++) {
                      ZharpLogger.info('Burst log $i of 120', {'i': i});
                    }
                  })),
              _button('Send now', Icons.send_outlined, () => _do('everything queued sent', () {
                    unawaited(ZharpLogger.flushAll());
                  })),
            ],
          ),

          _Section(
            title: 'Crashes and errors',
            subtitle: 'Nothing here is logged by hand — each one is caught by the SDK.',
            children: [
              _button('Throw in a tap', Icons.touch_app_outlined, () {
                // Flutter catches errors in gesture callbacks and reports them to FlutterError.onError.
                throw StateError('Button handler blew up');
              }),
              _button('Uncaught async error', Icons.timer_outlined, () {
                // Nothing awaits this Future, so its error reaches PlatformDispatcher.onError.
                Future<void>.delayed(const Duration(milliseconds: 100), () => throw TimeoutException('Order sync timed out'));
                _do('async error thrown — watch for it in Logs', () {});
              }),
              _button('Error in build', Icons.broken_image_outlined, () {
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const _BrokenPage()));
              }),
              _button('Layout overflow', Icons.view_column_outlined, () {
                setState(() => _overflow = !_overflow);
              }),
              _button('Broken image (silent)', Icons.image_not_supported_outlined, () {
                setState(() => _brokenImage = !_brokenImage);
              }),
            ],
          ),

          if (_overflow)
            // Wider than the screen: Flutter reports a RenderFlex overflow.
            const Row(children: [SizedBox(width: 4000, height: 20, child: ColoredBox(color: Colors.orange))]),
          if (_brokenImage)
            // An image that can't load is reported as a "silent" error — sent as warn.
            Image.network('https://zharp.io/this-image-does-not-exist.png', height: 40),
        ],
      ),
    );
  }

  Widget _button(String label, IconData icon, VoidCallback onPressed) =>
      FilledButton.tonalIcon(onPressed: onPressed, icon: Icon(icon, size: 18), label: Text(label));
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.active, required this.actions});

  final bool active;
  final int actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(active ? Icons.check_circle : Icons.cancel, color: active ? const Color(0xFF3BD671) : Colors.redAccent),
              const SizedBox(width: 8),
              Text(active ? 'Sending to Zharp' : 'Not sending', style: theme.textTheme.titleMedium),
            ]),
            const SizedBox(height: 8),
            if (active) ...[
              const Text('Service: zharp-logs-demo  •  environment: development'),
              SelectableText('Session: ${ZharpLogger.sessionId}', style: theme.textTheme.bodySmall),
              Text('Actions this run: $actions', style: theme.textTheme.bodySmall),
            ] else
              const Text('No API key. Run with --dart-define=ZHARP_API_KEY=your-ingest-only-key'),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, this.subtitle, required this.children});

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle!, style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: children),
        ],
      ),
    );
  }
}

/// A page whose build throws: Flutter shows its error screen and reports to FlutterError.onError.
class _BrokenPage extends StatelessWidget {
  const _BrokenPage();

  @override
  Widget build(BuildContext context) {
    throw ArgumentError('Product price was null while building the checkout page');
  }
}
