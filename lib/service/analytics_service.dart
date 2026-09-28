import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../util/log_service.dart';
import 'fake_api_service.dart';

class AnalyticsEvent {
  final String name;
  final Map<String, dynamic> properties;
  final DateTime at;

  AnalyticsEvent(this.name, this.properties, {DateTime? at})
      : at = at ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'name': name,
        'properties': properties,
        'at': at.toIso8601String(),
      };
}

/// Session deduplication, debug history and batched analytics delivery.
class AnalyticsService extends GetxService {
  AnalyticsService({required this.api, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final FakeApiService api;
  final DateTime Function() _now;
  final events = <AnalyticsEvent>[].obs;
  final routeObserver = RouteObserver<ModalRoute<dynamic>>();
  final _impressedDeals = <int>{};
  final _pending = <AnalyticsEvent>[];
  Timer? _flushTimer;
  bool _sending = false;
  bool _backingOff = false;

  bool hasImpression(int dealId) => _impressedDeals.contains(dealId);

  void recordImpression({
    required int dealId,
    required String source,
    required int position,
  }) {
    if (isClosed || !_impressedDeals.add(dealId)) return;
    logEvent('deal_impression', {
      'deal_id': dealId,
      'source': source,
      'position': position,
    });
  }

  void logEvent(String name, [Map<String, dynamic> properties = const {}]) {
    if (isClosed) return;
    final event =
        AnalyticsEvent(name, Map.unmodifiable(properties), at: _now());
    events.add(event);
    _pending.add(event);
    LogService.log('analytics: $name $properties');
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (isClosed || _sending || _backingOff || _pending.isEmpty) return;
    if (_pending.length >= 10) {
      unawaited(_flush());
      return;
    }

    // This deadline belongs to the first unsent event, not the last arrival.
    final remaining =
        const Duration(seconds: 15) - _now().difference(_pending.first.at);
    _flushTimer ??= Timer(remaining.isNegative ? Duration.zero : remaining, () {
      _flushTimer = null;
      unawaited(_flush());
    });
  }

  Future<void> _flush() async {
    if (isClosed || _sending || _pending.isEmpty) return;
    _flushTimer?.cancel();
    _flushTimer = null;
    _sending = true;
    final batch = _pending.take(10).toList();
    _pending.removeRange(0, batch.length);
    var failed = false;
    try {
      await api
          .sendAnalyticsBatch(batch.map((event) => event.toJson()).toList());
    } catch (error) {
      failed = true;
      if (!isClosed) _pending.insertAll(0, batch);
      LogService.error('analytics batch failed', error);
    } finally {
      _sending = false;
      if (!isClosed) {
        if (failed) {
          // Preserve the original events and retry without a tight loop.
          _backingOff = true;
          _flushTimer = Timer(const Duration(seconds: 5), () {
            _flushTimer = null;
            _backingOff = false;
            unawaited(_flush());
          });
        } else {
          // Events received during the request keep their original deadline.
          _scheduleFlush();
        }
      }
    }
  }

  @override
  void onClose() {
    _flushTimer?.cancel();
    _pending.clear();
    super.onClose();
  }
}
