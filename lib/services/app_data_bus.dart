import 'dart:async';

class AppDataBus {
  AppDataBus._();

  static final StreamController<int> _controller =
      StreamController<int>.broadcast();

  static Stream<int> get stream => _controller.stream;

  static void notify() {
    _controller.add(DateTime.now().millisecondsSinceEpoch);
  }

  static void dispose() {
    _controller.close();
  }
}