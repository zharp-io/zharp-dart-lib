import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:zharp_core/zharp_core.dart';

/// Records a screen view — a root span named `screen <route name>` — each time a page route is
/// shown, and tags everything recorded meanwhile with `app.screen.name`.
///
/// ```dart
/// MaterialApp(navigatorObservers: [ZharpNavigatorObserver()], …)
/// // go_router: GoRouter(observers: [ZharpNavigatorObserver()], …)
/// ```
///
/// The span lasts while the screen loads: until its first frame is drawn and the requests made
/// meanwhile have finished (then `screenIdleTimeout` without new ones; at most
/// `screenMaxDuration`). Requests made then join its trace. With `tracing: false` only the screen
/// name is kept (on logs and errors); no span is recorded.
///
/// Routes are named by their `RouteSettings.name` (`Navigator.pushNamed`, go_router's paths).
/// Unnamed routes are skipped unless [nameExtractor] names them. Only page routes count by
/// default — dialogs and bottom sheets don't; pass [routeFilter] to change that.
class ZharpNavigatorObserver extends NavigatorObserver {
  ZharpNavigatorObserver({this.nameExtractor, this.routeFilter});

  /// The screen name for a route, or null to skip it. Defaults to `settings.name`.
  final String? Function(RouteSettings settings)? nameExtractor;

  /// Which routes are screens. Defaults to [PageRoute]s.
  final bool Function(Route<dynamic> route)? routeFilter;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _view(route, previousRoute, 'push');

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => _view(newRoute, oldRoute, 'replace');

  /// Going back shows the route underneath again: a view of that one.
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _view(previousRoute, route, 'pop');

  void _view(Route<dynamic>? route, Route<dynamic>? from, String action) {
    try {
      final core = ZharpCore.instance;
      if (core == null || route == null || !_isScreen(route)) return;
      final name = _nameOf(route);
      if (name == null) return;
      final fromName = from != null && _isScreen(from) ? _nameOf(from) : null;
      // On pop the route underneath was the screen all along; only the name it shows changes.
      core.setScreen(name);
      // Logs-only mode: the screen name still tags logs and errors; no screen-view span.
      if (!core.options.tracing) return;
      final view = core.tracer.startIdle(
        'screen $name',
        idleTimeout: core.options.screenIdleTimeout,
        maxDuration: core.options.screenMaxDuration,
        attributes: {
          'app.screen.name': name,
          'zharp.navigation.action': action,
          if (fromName != null) 'zharp.navigation.from': fromName,
        },
      );
      // Open at least until the screen has been drawn once.
      final release = view.hold();
      SchedulerBinding.instance.addPostFrameCallback((_) => release());
      SchedulerBinding.instance.ensureVisualUpdate();
    } catch (_) {
      // Navigation must never fail because of monitoring.
    }
  }

  bool _isScreen(Route<dynamic> route) => routeFilter?.call(route) ?? route is PageRoute;

  String? _nameOf(Route<dynamic> route) {
    final name = nameExtractor != null ? nameExtractor!(route.settings) : route.settings.name;
    final trimmed = name?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
