/// Turning a Dart error and its stack into the `exception.*` attributes Zharp reads.
library;

/// Frames from the SDK itself, left out of stacks the SDK had to capture on the caller's behalf.
final RegExp _sdkFrame = RegExp(r'package:zharp_(core|flutter|dio)/');

/// What an obfuscated / `--split-debug-info` build's stack says about itself, in the header the
/// Dart VM writes above its frames:
///
/// ```
/// *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
/// pid: 7032, tid: 7072, name 1.ui
/// os: android arch: arm64 comp: yes sim: no
/// build_id: '7d9b1e3c0a6f4e2b8c5d1a9e3f7b2c4d'
/// isolate_dso_base: 7a4cdc4000, vm_dso_base: 7a4cdc4000
/// isolate_instructions: 7a4ce90000, vm_instructions: 7a4ce81000
///     #00 abs 0000007a4cf3a20b virt 000000000017620b _kDartIsolateSnapshotInstructions+0xa620b
/// ```
///
/// Zharp finds the build's symbols (`zharp dart-symbols upload`) by the build ID and arch, and
/// reads the frames' addresses against them — so the stack is sent exactly as the VM wrote it.
class DartBuildInfo {
  const DartBuildInfo({this.buildId, this.os, this.arch});

  final String? buildId;
  final String? os;
  final String? arch;

  static final RegExp _header = RegExp(r'^\*\*\* \*\*\* \*\*\*', multiLine: true);
  static final RegExp _buildId = RegExp(r"^build_id: '([0-9a-fA-F]+)'", multiLine: true);
  static final RegExp _osArch = RegExp(r'^os: (\S+) arch: (\S+)', multiLine: true);

  /// The header's facts, or null for an ordinary (symbolic) stack.
  static DartBuildInfo? parse(String stack) {
    if (!_header.hasMatch(stack)) return null;
    final osArch = _osArch.firstMatch(stack);
    return DartBuildInfo(
      buildId: _buildId.firstMatch(stack)?.group(1)?.toLowerCase(),
      os: osArch?.group(1),
      arch: osArch?.group(2),
    );
  }

  Map<String, Object> attributes() => {
        if (buildId != null) 'zharp.dart_build_id': buildId!,
        if (os != null) 'zharp.dart_os': os!,
        if (arch != null) 'zharp.dart_arch': arch!,
      };
}

/// An error as Zharp files it.
class ExceptionDescription {
  ExceptionDescription(this.type, this.message, this.stacktrace, [this.build]);

  /// `StateError`, `SocketException`, `_TypeError`…
  final String type;

  /// The error's own text, e.g. `Bad state: cart is empty`.
  final String message;

  /// `Type: message` then the Dart frames (`#0 main (package:app/main.dart:5:3)`); for an
  /// obfuscated build, the VM's raw stack as it wrote it, header and all (see [DartBuildInfo]).
  final String stacktrace;

  /// Set when the stack is an obfuscated build's.
  final DartBuildInfo? build;

  /// Where an error is thrown from: its first frame (the header and `***` lines aren't frames).
  String get firstFrame =>
      stacktrace.split('\n').skip(1).firstWhere((line) => _frameLine.hasMatch(line), orElse: () => '');

  Map<String, Object> attributes({required bool handled}) => {
        'exception.type': type,
        'exception.message': message,
        'exception.stacktrace': stacktrace,
        'zharp.handled': handled ? 'true' : 'false',
        ...?build?.attributes(),
      };
}

/// Describe [error]. The stack is, in order: [stackTrace] when it has frames, the stack an
/// `Error` was thrown with, or — an `Exception` carries none — where this was called, without
/// the SDK's own frames.
ExceptionDescription describeError(Object error, StackTrace? stackTrace) {
  final type = _typeOf(error);
  final message = _messageOf(error);
  var frames = _framesOf(stackTrace);
  if (frames.isEmpty && error is Error) frames = _framesOf(error.stackTrace);
  if (frames.isEmpty) {
    frames = _framesOf(StackTrace.current).where((line) => !_sdkFrame.hasMatch(line)).toList();
  }
  final header = message.isEmpty ? type : '$type: ${message.split('\n').first}';
  final stack = [header, ...frames].join('\n');
  return ExceptionDescription(type, message, stack, DartBuildInfo.parse(stack));
}

final RegExp _frameLine = RegExp(r'^\s*#\d+\s');

String _typeOf(Object error) {
  try {
    final type = error.runtimeType.toString();
    // `Exception('x')` is a private _Exception; it reads best as what was written.
    return type == '_Exception' ? 'Exception' : type;
  } catch (_) {
    return 'Object';
  }
}

String _messageOf(Object error) {
  try {
    final text = error.toString();
    // `FormatException: bad json`, `Exception: x`: the type is already said; don't say it twice.
    final prefix = '${_typeOf(error)}: ';
    return text.startsWith(prefix) ? text.substring(prefix.length) : text;
  } catch (_) {
    return '';
  }
}

/// The stack's lines as the VM wrote them (indentation, an obfuscated build's header,
/// `<asynchronous suspension>`); only empty lines are dropped. Nothing is demangled or
/// reformatted: an obfuscated build's frames are addresses that read back only as written.
List<String> _framesOf(StackTrace? stackTrace) {
  if (stackTrace == null) return const [];
  final text = stackTrace.toString();
  if (text.trim().isEmpty) return const [];
  return text.split('\n').where((line) => line.trim().isNotEmpty).toList();
}

/// Errors already sent, so the same error object isn't reported twice — e.g. once by the span it
/// escaped from and again by the uncaught-error handler.
final Expando<bool> _reported = Expando<bool>('zharp.reported');

void markReported(Object error) {
  try {
    _reported[error] = true;
  } catch (_) {
    // Strings, numbers and booleans can't carry an Expando; those are never deduplicated.
  }
}

bool wasReported(Object error) {
  try {
    return _reported[error] ?? false;
  } catch (_) {
    return false;
  }
}
