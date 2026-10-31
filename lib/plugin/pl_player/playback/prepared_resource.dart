import 'dart:async';

/// Exactly one recipient may take an in-flight resource. Cancellation owns and
/// disposes a late result; taking transfers that responsibility to the caller.
class PreparedResource<T> {
  PreparedResource({
    required Future<T> Function() load,
    required this.dispose,
    this.onReleased,
  }) : _value = Future<T>.sync(load) {
    _value.ignore();
  }

  final Future<T> _value;
  final Future<void> Function(T) dispose;
  final void Function()? onReleased;
  bool _available = true;
  bool _released = false;

  void _release() {
    if (_released) return;
    _released = true;
    onReleased?.call();
  }

  Future<T?> take() async {
    if (!_available) return null;
    _available = false;
    try {
      return await _value;
    } catch (_) {
      return null;
    } finally {
      _release();
    }
  }

  Future<void> cancel() async {
    if (!_available) return;
    _available = false;
    try {
      await dispose(await _value);
    } catch (_) {
      // Failed preparation owns no result; cancellation must still release it.
    } finally {
      _release();
    }
  }
}
