import 'package:get/get.dart';

import '../../repository/order_repo.dart';
import '../../service/api_exception.dart';
import '../../service/cart_service.dart';
import '../../util/log_service.dart';

class CartController extends GetxController {
  final CartService cartService;
  final OrderRepo orderRepo;

  CartController({required this.cartService, required this.orderRepo});

  RxBool get isCheckingOut => cartService.isCheckingOut;

  Future<void> checkout() async {
    final submitted = cartService.beginCheckout();
    if (submitted == null) return;
    var clearSubmitted = false;
    try {
      final order = await orderRepo.checkout(submitted);
      clearSubmitted = true;
      Get.snackbar(
        'Order confirmed',
        'Order #${order.id} — pick up soon!',
        snackPosition: SnackPosition.BOTTOM,
      );
    } on ApiException catch (e) {
      LogService.error('checkout failed', e);
      if (e.statusCode == 410) {
        // The API does not identify which hold was rejected. Invalidate the
        // entire submitted set rather than retrying an unknown reservation.
        clearSubmitted = true;
        Get.snackbar(
          'Your hold ended',
          'Your order was not placed. Please add the items again to check availability.',
          snackPosition: SnackPosition.BOTTOM,
        );
      } else {
        Get.snackbar('Checkout failed', e.message,
            snackPosition: SnackPosition.BOTTOM);
      }
    } catch (error) {
      LogService.error('checkout failed', error);
      Get.snackbar('Could not confirm your order',
          'Please check your orders before trying again.',
          snackPosition: SnackPosition.BOTTOM);
    } finally {
      cartService.finishCheckout(clearSubmitted: clearSubmitted);
    }
  }
}
