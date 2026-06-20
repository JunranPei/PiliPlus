import 'package:flutter/widgets.dart';
import 'package:get/get_navigation/src/routes/default_route.dart' show GetPageRoute;

final routeObserver = RouteObserver<GetPageRoute>();

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
