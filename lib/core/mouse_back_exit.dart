/// 鼠标侧键后退的全局状态退出注册表：后注册的先响应，
/// 处理器返回 false 视为已失效并移除。
class MouseBackExit {
  MouseBackExit._();

  static final List<bool Function()> _handlers = [];
  static final Map<String, List<bool Function()>> _routeHandlers = {};

  static void register(bool Function() handler) {
    if (_handlers.contains(handler)) return;
    _handlers.add(handler);
  }

  static void unregister(bool Function() handler) {
    _handlers.remove(handler);
  }

  static bool consume() {
    while (_handlers.isNotEmpty) {
      final handler = _handlers.removeLast();
      if (handler()) return true;
    }
    return false;
  }

  static void registerRoute(String route, bool Function() handler) {
    final handlers = _routeHandlers.putIfAbsent(route, () => []);
    if (!handlers.contains(handler)) handlers.add(handler);
  }

  static void unregisterRoute(String route, bool Function() handler) {
    final handlers = _routeHandlers[route];
    if (handlers == null) return;
    handlers.remove(handler);
    if (handlers.isEmpty) _routeHandlers.remove(route);
  }

  static bool consumeRoute(String route) {
    final handlers = _routeHandlers[route];
    if (handlers == null) return false;
    for (var index = handlers.length - 1; index >= 0; index--) {
      if (handlers[index]()) return true;
    }
    return false;
  }
}
