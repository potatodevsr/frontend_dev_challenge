import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../service/flash_sale_clock.dart';

String flashSaleTimeLeft(DateTime endsAt, DateTime now) {
  final remaining = endsAt.difference(now).inMicroseconds;
  if (remaining <= 0) return 'Expired';

  // Round up so a still-purchasable deal never displays 00:00.
  final seconds = (remaining / Duration.microsecondsPerSecond).ceil();
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  final minutes = twoDigits((seconds ~/ 60) % 60);
  final tail = '$minutes:${twoDigits(seconds % 60)}';
  return seconds >= 3600 ? '${twoDigits(seconds ~/ 3600)}:$tail' : tail;
}

/// Only this Text rebuilds each second, not its parent badge/card/list.
class FlashSaleCountdown extends StatefulWidget {
  const FlashSaleCountdown({super.key, required this.endsAt, this.style});

  final DateTime endsAt;
  final TextStyle? style;

  @override
  State<FlashSaleCountdown> createState() => _FlashSaleCountdownState();
}

class _FlashSaleCountdownState extends State<FlashSaleCountdown> {
  late final FlashSaleClock _clock;
  late String _label;

  @override
  void initState() {
    super.initState();
    _clock = Get.find<FlashSaleClock>();
    _label = flashSaleTimeLeft(widget.endsAt, _clock.now);
    _clock.ticks.addListener(_update);
  }

  void _update() {
    final next = flashSaleTimeLeft(widget.endsAt, _clock.now);
    if (next != _label) setState(() => _label = next);
  }

  @override
  void didUpdateWidget(covariant FlashSaleCountdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    _label = flashSaleTimeLeft(widget.endsAt, _clock.now);
  }

  @override
  void dispose() {
    _clock.ticks.removeListener(_update);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(_label, style: widget.style);
}

/// Rebuilds the surrounding controls only when availability changes.
class FlashSaleAvailability extends StatefulWidget {
  const FlashSaleAvailability({
    super.key,
    required this.endsAt,
    required this.builder,
  });

  final DateTime? endsAt;
  final Widget Function(BuildContext context, bool expired) builder;

  @override
  State<FlashSaleAvailability> createState() => _FlashSaleAvailabilityState();
}

class _FlashSaleAvailabilityState extends State<FlashSaleAvailability> {
  late final FlashSaleClock _clock;
  late bool _expired;

  @override
  void initState() {
    super.initState();
    _clock = Get.find<FlashSaleClock>();
    _expired = _clock.isExpired(widget.endsAt);
    _clock.ticks.addListener(_update);
  }

  void _update() {
    final next = _clock.isExpired(widget.endsAt);
    if (next != _expired) setState(() => _expired = next);
  }

  @override
  void didUpdateWidget(covariant FlashSaleAvailability oldWidget) {
    super.didUpdateWidget(oldWidget);
    _expired = _clock.isExpired(widget.endsAt);
  }

  @override
  void dispose() {
    _clock.ticks.removeListener(_update);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _expired);
}
