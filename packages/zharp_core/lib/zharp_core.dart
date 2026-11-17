/// The engine behind `zharp_flutter` and `zharp_dio`: spans, logs, errors and sessions encoded
/// as OTLP/HTTP JSON and sent to Zharp in batches.
///
/// Flutter apps use `zharp_flutter`, which starts this and wires in Flutter's errors, lifecycle
/// and navigation. It works on its own in any Dart program:
///
/// ```dart
/// final zharp = ZharpCore.start(ZharpOptions(key: 'zpk_…', service: 'tool'))!;
/// zharp.log.info('Started');
/// await zharp.close();
/// ```
library;

export 'src/bodies.dart'
    show
        BodyMode,
        BodySettings,
        CaptureBodies,
        bodyAttributes,
        bytesAttributes,
        describedAttributes,
        fileLabel,
        isEventStream,
        isTextual,
        redactQuery;
export 'src/core.dart' show ZharpCore, ZharpLog, ZharpUser, normalizeEndpoint;
export 'src/ids.dart' show newUuid;
export 'src/errors.dart' show ExceptionDescription, describeError, markReported, wasReported;
export 'src/http_tracing.dart' show HttpSpan, ZharpHttpClient, redactUrl, startHttpSpan;
export 'src/options.dart' show ZharpOptions, defaultEndpoint;
export 'src/output.dart'
    show
        ParsedLine,
        alreadySent,
        captureMessage,
        flushCapturedOutput,
        parseLine,
        quietly,
        rememberSent,
        resetOutputCapture,
        runCapturingOutput,
        stripAnsi;
export 'src/otlp.dart' show Severity, SpanKind, SpanStatusCode;
export 'src/propagation.dart' show formatTraceparent, parseTraceparent, formatBaggage, parseBaggage, shouldPropagate;
export 'src/session.dart' show SessionManager;
export 'src/span.dart' show ZharpSpan;
export 'src/tracer.dart' show IdleSpan, Tracer;
export 'src/version.dart' show sdkVersion;
