import 'dart:async';

import 'package:rescu/service/fake_api_service.dart';

class ReserveRequest {
  ReserveRequest(this.dealId, this.quantity);
  final int dealId;
  final int quantity;
  final result = Completer<Map<String, dynamic>>();
}

/// Controlled remote responses: no random latency, contention, or real clock.
class ReservationApi extends FakeApiService {
  ReservationApi({required this.now, this.autoReserve = false});
  final DateTime Function() now;
  final bool autoReserve;
  final requests = <ReserveRequest>[];
  final released = <String>[];
  final checkouts = <List<Map<String, dynamic>>>[];
  final checkoutResult = Completer<Map<String, dynamic>>();
  Completer<void>? releaseResult;

  @override
  Future<Map<String, dynamic>> reserveDeal(int dealId, {int quantity = 1}) {
    final request = ReserveRequest(dealId, quantity);
    requests.add(request);
    if (autoReserve) succeed(requests.length - 1);
    return request.result.future;
  }

  void succeed(int index, {DateTime? expiresAt}) {
    final request = requests[index];
    request.result.complete({
      'id': 'hold_$index',
      'dealId': request.dealId,
      'quantity': request.quantity,
      'expiresAt': (expiresAt ?? now().add(const Duration(minutes: 5)))
          .toIso8601String(),
    });
  }

  @override
  Future<void> releaseReservation(String reservationId) async {
    released.add(reservationId);
    await releaseResult?.future;
  }

  @override
  Future<Map<String, dynamic>> checkout(List<Map<String, dynamic>> items) {
    checkouts.add(items);
    return checkoutResult.future;
  }

  void confirmOrder() => checkoutResult.complete({
        'id': 42,
        'pickupStart': now().toIso8601String(),
        'pickupEnd': now().add(const Duration(hours: 1)).toIso8601String(),
      });
}
