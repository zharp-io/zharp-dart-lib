// Run with your app key (never commit one):
//   flutter run --dart-define=ZHARP_KEY=zpk_… --dart-define=ZHARP_ENDPOINT=http://10.0.2.2:3000/api/v1/otlp
import 'package:flutter/material.dart';
import 'package:zharp_flutter/zharp_flutter.dart';

const _key = String.fromEnvironment('ZHARP_KEY');
const _endpoint = String.fromEnvironment('ZHARP_ENDPOINT');

final api = ZharpHttpClient();

Future<void> main() async {
  await Zharp.init(ZharpOptions(
    key: _key,
    service: 'zharp-flutter-example',
    environment: 'development',
    endpoint: _endpoint.isEmpty ? null : _endpoint,
    tracingOrigins: ['jsonplaceholder.typicode.com'],
    debug: true,
  ));
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Zharp example',
        navigatorObservers: [ZharpNavigatorObserver()],
        initialRoute: '/',
        routes: {
          '/': (_) => const HomeScreen(),
          '/posts': (_) => const PostsScreen(),
        },
      );
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Zharp example')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            FilledButton(
              onPressed: () => Zharp.setUser(id: 'user-42', email: 'demo@example.com'),
              child: const Text('Sign in as user-42'),
            ),
            const OutlinedButton(onPressed: Zharp.clearUser, child: Text('Sign out')),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => Navigator.pushNamed(context, '/posts'),
              child: const Text('Open a screen that loads data'),
            ),
            OutlinedButton(
              onPressed: () => Zharp.log.info('Button tapped', {'button': 'log'}),
              child: const Text('Send a log'),
            ),
            OutlinedButton(
              onPressed: () {
                try {
                  throw StateError('Something went wrong (caught)');
                } catch (error, stack) {
                  Zharp.captureError(error, stackTrace: stack);
                }
              },
              child: const Text('Report a caught error'),
            ),
            OutlinedButton(
              onPressed: () => throw StateError('Something went wrong (uncaught)'),
              child: const Text('Throw an uncaught error'),
            ),
            OutlinedButton(
              onPressed: () => Zharp.startSpan('checkout', (span) async {
                span.setAttribute('cart.items', 3);
                await api.get(Uri.parse('https://jsonplaceholder.typicode.com/todos/1'));
              }),
              child: const Text('Trace a checkout'),
            ),
          ],
        ),
      );
}

class PostsScreen extends StatefulWidget {
  const PostsScreen({super.key});

  @override
  State<PostsScreen> createState() => _PostsScreenState();
}

class _PostsScreenState extends State<PostsScreen> {
  String _status = 'Loading…';

  @override
  void initState() {
    super.initState();
    // Joins this screen's trace: the screen-view span is open while it loads.
    api.get(Uri.parse('https://jsonplaceholder.typicode.com/posts')).then(
          (response) => setState(() => _status = 'HTTP ${response.statusCode}'),
          onError: (Object error) => setState(() => _status = 'Failed: $error'),
        );
  }

  @override
  Widget build(BuildContext context) =>
      Scaffold(appBar: AppBar(title: const Text('Posts')), body: Center(child: Text(_status)));
}
