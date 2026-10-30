import 'package:dio/dio.dart';
import 'package:zharp_core/zharp_core.dart';
import 'package:zharp_dio/zharp_dio.dart';

// In a Flutter app, `Zharp.init` from zharp_flutter starts the SDK; ZharpCore.start is the same
// thing without Flutter.
Future<void> main() async {
  final zharp = ZharpCore.start(const ZharpOptions(
    key: String.fromEnvironment('ZHARP_KEY'),
    service: 'example',
    tracingOrigins: ['api.example.com'],
  ));
  final dio = Dio()..interceptors.add(ZharpDioInterceptor());
  try {
    await dio.get<dynamic>('https://api.example.com/orders');
  } on DioException catch (_) {
    // Recorded on the request's span.
  }
  await zharp?.close();
}
