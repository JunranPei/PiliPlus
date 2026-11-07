import 'package:flutter/widgets.dart';
import 'package:PiliPlus/plugin/pl_player/android_pip_controller.dart';
import 'package:get/get_navigation/src/routes/default_route.dart' show GetPageRoute;

final routeObserver = _PlaybackRouteObserver();

class _PlaybackRouteObserver extends RouteObserver<GetPageRoute> {
  final _pages = <Route<dynamic>>[];
  Route<dynamic>? _publishedPage;
  bool _published = false;

  void _publish() {
    final page = _pages.isEmpty ? null : _pages.last;
    if (_published && identical(page, _publishedPage)) return;
    _published = true;
    _publishedPage = page;
    AndroidPipController.instance.setPlaybackRoute(
      page?.settings.name,
    );
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) _pages.add(route);
    _publish();
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _pages.remove(route);
    _publish();
    super.didPop(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _pages.remove(route);
    _publish();
    super.didRemove(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _pages.indexOf(oldRoute);
    if (index >= 0) {
      _pages.removeAt(index);
      if (newRoute is PageRoute) _pages.insert(index, newRoute);
    } else if (newRoute is PageRoute) {
      _pages.add(newRoute);
    }
    _publish();
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }
}

mixin RouteAwareMixin<T extends StatefulWidget> on State<T>, RouteAware {
  bool _isSubscribed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isSubscribed) {
      final route = ModalRoute.of(context);
      if (route is GetPageRoute) {
        routeObserver.subscribe(this, route);
        _isSubscribed = true;
      }
    }
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }
}
