import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// One clock for countdowns and bag expiry throughout the app session.
class FlashSaleClock extends GetxService with WidgetsBindingObserver {
  FlashSaleClock({DateTime Function()? now}) : _readNow = now ?? DateTime.now {
    ticks = ValueNotifier(this.now);
  }

  final DateTime Function() _readNow;
  late final ValueNotifier<DateTime> ticks;
  Timer? _timer;

  DateTime get now => _readNow();

  bool isExpired(DateTime? endsAt) => endsAt != null && !endsAt.isAfter(now);

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      ticks.value = now;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Recompute from wall time; never count missed timer callbacks.
      ticks.value = now;
      _start();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _timer?.cancel();
    }
  }

  @override
  void onClose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    ticks.dispose();
    super.onClose();
  }
}
