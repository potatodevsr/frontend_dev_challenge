import 'dart:async';

import 'package:get/get.dart';

import '../model/cart_item_model.dart';
import '../model/deal_model.dart';
import '../model/reservation_model.dart';
import '../repository/order_repo.dart';
import '../util/log_service.dart';
import 'flash_sale_clock.dart';

/// Session-wide owner of optimistic quantities and their server stock holds.
class CartService extends GetxService {
  CartService({required this.clock, required this.orderRepo});

  final FlashSaleClock clock;
  final OrderRepo orderRepo;
  final items = <CartItemModel>[].obs;
  final itemCount = 0.obs;
  final isCheckingOut = false.obs;

  bool get hasPendingReservations => items.any((item) => item.isReserving);

  @override
  void onInit() {
    super.onInit();
    clock.ticks.addListener(removeExpiredDeals);
  }

  @override
  void onClose() {
    clock.ticks.removeListener(removeExpiredDeals);
    // Submitted holds belong to the checkout request until its result arrives.
    if (!isCheckingOut.value) clear();
    super.onClose();
  }

  /// Checks both deadlines, including between timer ticks and on app resume.
  /// During checkout the server decides expiry; never release its input early.
  bool removeExpiredDeals() {
    if (isCheckingOut.value) return false;
    final flashExpired = items
        .where((item) => clock.isExpired(item.deal.flashSaleEndsAt))
        .toList();
    final holdExpired = items
        .where((item) =>
            !flashExpired.contains(item) &&
            clock.isExpired(item.reservation?.expiresAt))
        .toList();
    for (final item in [...flashExpired, ...holdExpired]) {
      _remove(item);
    }
    if (flashExpired.isNotEmpty) {
      _notice('Flash sale expired',
          'Removed from your bag: ${flashExpired.map((i) => i.deal.name).join(', ')}.');
    }
    if (holdExpired.isNotEmpty) {
      _notice('Your hold ended',
          'Removed from your bag: ${holdExpired.map((i) => i.deal.name).join(', ')}. Add them again to check availability.');
    }
    return flashExpired.isNotEmpty || holdExpired.isNotEmpty;
  }

  bool add(DealModel deal) {
    if (isCheckingOut.value || isClosed) return false;
    if (clock.isExpired(deal.flashSaleEndsAt)) {
      if (!removeExpiredDeals()) {
        _notice('Flash sale expired', 'This deal is no longer available.');
      }
      return false;
    }
    removeExpiredDeals();
    var item = items.firstWhereOrNull((i) => i.deal.id == deal.id);
    if (deal.quantityLeft <= 0 ||
        (item != null && item.quantity >= deal.quantityLeft)) {
      return false;
    }
    if (item == null) {
      item = CartItemModel(deal: deal);
      items.add(item);
    } else {
      item.quantity++;
    }
    _recount();
    unawaited(_sync(item));
    return true;
  }

  void decrement(int dealId) {
    if (isCheckingOut.value) return;
    removeExpiredDeals();
    final item = items.firstWhereOrNull((i) => i.deal.id == dealId);
    if (item == null) return;
    if (item.quantity == 1) {
      _remove(item);
    } else {
      item.quantity--;
      _recount();
      unawaited(_sync(item));
    }
  }

  void remove(int dealId) {
    if (isCheckingOut.value) return;
    final item = items.firstWhereOrNull((i) => i.deal.id == dealId);
    if (item != null) _remove(item);
  }

  void clear() {
    if (isCheckingOut.value) return;
    for (final item in items.toList()) {
      _remove(item);
    }
  }

  void _remove(CartItemModel item) {
    items.remove(item);
    final hold = item.reservation;
    item.reservation = null;
    if (hold != null) unawaited(_release(hold));
    _recount();
  }

  /// One worker per line coalesces rapid edits. Object identity prevents a late
  /// reply from restoring a removed line (including remove then re-add).
  Future<void> _sync(CartItemModel item) async {
    if (item.isReserving) {
      items.refresh();
      return;
    }
    item.isReserving = true;
    items.refresh();
    while (items.contains(item) && !isClosed) {
      final quantity = item.quantity;
      final previous = item.reservation;
      item.reservation = null;
      if (previous != null && !await _release(previous)) {
        if (items.contains(item)) {
          _remove(item);
          _notice('Could not update your bag',
              '${item.deal.name} was removed. Please try again after its current hold ends.');
        }
        return;
      }
      if (!items.contains(item) || isClosed) return;
      try {
        final hold = await orderRepo.reserve(item.deal.id, quantity: quantity);
        if (!items.contains(item) || isClosed) {
          await _release(hold);
          return;
        }
        item.reservation = hold;
        removeExpiredDeals();
        if (!items.contains(item)) return;
        if (item.quantity != quantity) continue;
        item.isReserving = false;
        items.refresh();
        return;
      } catch (error) {
        LogService.error('reserve failed', error);
        if (!items.contains(item) || isClosed) return;
        // A failed obsolete quantity does not cancel the latest user intent.
        if (item.quantity != quantity) continue;
        _remove(item);
        _notice('Could not hold this item',
            '${item.deal.name} was removed from your bag. It may no longer be available. Please try adding it again.');
        return;
      }
    }
  }

  Future<bool> _release(ReservationModel hold) async {
    try {
      await orderRepo.releaseReservation(hold.id);
      return true;
    } catch (error) {
      LogService.error('release reservation failed', error);
      if (!isClosed) {
        _notice('Your hold will end shortly',
            'We could not release the hold right now. It will end automatically within five minutes.');
      }
      return false;
    }
  }

  /// Freeze fully held quantities before the first checkout await.
  List<CartItemModel>? beginCheckout() {
    if (isCheckingOut.value || isClosed) return null;
    if (removeExpiredDeals() || items.isEmpty || hasPendingReservations) {
      return null;
    }
    if (items.any((i) =>
        i.reservation == null || i.reservation!.quantity != i.quantity)) {
      return null;
    }
    isCheckingOut.value = true;
    return [
      for (final item in items)
        CartItemModel(
            deal: item.deal,
            quantity: item.quantity,
            reservation: item.reservation),
    ];
  }

  void finishCheckout({bool clearSubmitted = false}) {
    if (clearSubmitted) {
      for (final item in items.toList()) {
        _remove(item);
      }
    }
    isCheckingOut.value = false;
    removeExpiredDeals();
  }

  num get total => items.fold(0, (sum, i) => sum + i.lineTotal);

  void _recount() {
    itemCount.value = items.fold(0, (sum, i) => sum + i.quantity);
  }

  void _notice(String title, String message) {
    Get.snackbar(title, message, snackPosition: SnackPosition.BOTTOM);
  }
}
