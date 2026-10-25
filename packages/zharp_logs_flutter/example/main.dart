import 'package:flutter/material.dart';
import 'package:zharp_logs_flutter/zharp_logs_flutter.dart';

/// Run with: flutter run --dart-define=ZHARP_API_KEY=your-ingest-only-key
void main() {
  ZharpFlutter.init(service: 'example-app', environment: 'development');
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ElevatedButton(
                onPressed: () => ZharpLogger.info('Button pressed', {'screen': 'home'}),
                child: const Text('Send a log'),
              ),
              ElevatedButton(
                // Thrown in a callback, so PlatformDispatcher.onError sends it.
                onPressed: () => throw StateError('Something broke'),
                child: const Text('Throw an error'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
