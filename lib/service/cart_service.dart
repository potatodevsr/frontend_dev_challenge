import 'package:get/get.dart';

import '../model/cart_item_model.dart';
import '../model/deal_model.dart';
import '../util/log_service.dart';
import 'flash_sale_clock.dart';

/// App-wide cart. Lives for the whole session.
///
/// NOTE: the starter cart is purely local — it does not reserve stock on the
/// backend. See the "Reservations" feature task in PROBLEM.md.
class CartService extends GetxService {
  CartService({required this.clock});

  final FlashSaleClock clock;
  final items = <CartItemModel>[].obs;
  final itemCount = 0.obs;

  @override
  void onInit() {
    super.onInit();
    clock.ticks.addListener(removeExpiredDeals);
  }

  @override
  void onClose() {
    clock.ticks.removeListener(removeExpiredDeals);
    super.onClose();
  }

  /// Also called before checkout, so a tap between ticks cannot buy an
  /// expired flash deal. Returns true when the bag changed.
  bool removeExpiredDeals() {
    final expired = items
        .where((item) => clock.isExpired(item.deal.flashSaleEndsAt))
        .toList();
    if (expired.isEmpty) return false;

    final ids = expired.map((item) => item.deal.id).toSet();
    items.removeWhere((item) => ids.contains(item.deal.id));
    _recount();
    Get.snackbar(
      'Flash sale expired',
      'Removed from your bag: ${expired.map((item) => item.deal.name).join(', ')}.',
      snackPosition: SnackPosition.BOTTOM,
    );
    return true;
  }

  bool add(DealModel deal) {
    if (clock.isExpired(deal.flashSaleEndsAt)) {
      if (!removeExpiredDeals()) {
        Get.snackbar(
          'Flash sale expired',
          'This deal is no longer available.',
          snackPosition: SnackPosition.BOTTOM,
        );
      }
      return false;
    }
    final existing = items.firstWhereOrNull((i) => i.deal.id == deal.id);
    if (existing != null) {
      if (existing.quantity >= deal.quantityLeft) {
        LogService.log('cart: cannot add more of deal ${deal.id}');
        return false;
      }
      existing.quantity++;
      items.refresh();
    } else {
      if (deal.quantityLeft <= 0) return false;
      items.add(CartItemModel(deal: deal));
    }
    _recount();
    return true;
  }

  void decrement(int dealId) {
    final existing = items.firstWhereOrNull((i) => i.deal.id == dealId);
    if (existing == null) return;
    existing.quantity--;
    if (existing.quantity <= 0) {
      items.removeWhere((i) => i.deal.id == dealId);
    } else {
      items.refresh();
    }
    _recount();
  }

  void remove(int dealId) {
    items.removeWhere((i) => i.deal.id == dealId);
    _recount();
  }

  void clear() {
    items.clear();
    _recount();
  }

  num get total => items.fold(0, (sum, i) => sum + i.lineTotal);

  void _recount() {
    itemCount.value = items.fold(0, (sum, i) => sum + i.quantity);
  }
}
