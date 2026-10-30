import 'ids.dart';

/// The `session.id` every span and log carries, so one person's visit can be followed.
///
/// A session ends — and the next record starts a new one — when the app has been in the
/// background for [timeout] (30 minutes by default), when nothing at all was recorded for that
/// long while in the foreground, and when the user signs out (`clearUser`).
class SessionManager {
  SessionManager({this.timeout = const Duration(minutes: 30), DateTime Function()? clock})
      : _clock = clock ?? DateTime.now {
    _start();
  }

  final Duration timeout;
  final DateTime Function() _clock;

  late String _id;
  late DateTime _lastActivity;
  DateTime? _backgroundedAt;

  /// Called with the new ID whenever a session starts (not for the first).
  void Function(String id)? onNewSession;

  /// The current session ID, without counting as activity.
  String get id => _id;

  /// The session ID for a record made now: a new one if the old one has expired.
  String touch() {
    final now = _clock();
    if (_backgroundedAt == null && now.difference(_lastActivity) >= timeout) _rotate();
    _lastActivity = now;
    return _id;
  }

  /// The app left the foreground.
  void background() {
    _backgroundedAt ??= _clock();
  }

  /// The app is back in the foreground: a new session if it was away for [timeout] or more.
  void foreground() {
    final since = _backgroundedAt;
    _backgroundedAt = null;
    final now = _clock();
    if (since != null && now.difference(since) >= timeout) _rotate();
    _lastActivity = now;
  }

  /// End the session now and start another, e.g. on sign-out.
  void reset() => _rotate();

  void _start() {
    _id = newUuid();
    _lastActivity = _clock();
  }

  void _rotate() {
    _start();
    try {
      onNewSession?.call(_id);
    } catch (_) {
      // A listener's failure is not ours to surface.
    }
  }
}
