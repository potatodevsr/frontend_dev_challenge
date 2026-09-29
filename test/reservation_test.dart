import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:rescu/feature/cart/cart_controller.dart';
import 'package:rescu/feature/cart/cart_screen.dart';
import 'package:rescu/repository/order_repo.dart';
import 'package:rescu/service/api_exception.dart';
import 'package:rescu/service/cart_service.dart';
import 'package:rescu/service/flash_sale_clock.dart';

import 'flash_sale_test.dart' show dealWithDeadline;
import 'support/reservation_api.dart';

void main() {
  late DateTime now;
  late FlashSaleClock clock;
  late ReservationApi api;
  late CartService cart;
  late CartController controller;

  Future<void> mount(WidgetTester tester, {bool bag = false}) async {
    now = DateTime.utc(2026, 9, 29, 12);
    Get.testMode = true;
    clock = Get.put(FlashSaleClock(now: () => now));
    api = ReservationApi(now: () => now);
    final repo = OrderRepo(api: api);
    cart = Get.put(CartService(clock: clock, orderRepo: repo));
    controller = Get.put(CartController(cartService: cart, orderRepo: repo));
    await tester.pumpWidget(GetMaterialApp(
      home: bag ? const CartScreen() : const Scaffold(body: Text('Home')),
    ));
    await tester.pump();
  }

  void reservationTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        // Drain queued notices without waiting on the image shimmer.
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(seconds: 4));
          await tester.pump(const Duration(milliseconds: 400));
        }
        await tester.pumpWidget(const SizedBox.shrink());
        cart.onDelete();
        clock.onDelete();
        await tester.pump();
        Get.reset();
      }
    });
  }

  Future<void> held(WidgetTester tester, int id) async {
    cart.add(dealWithDeadline(id, null));
    api.succeed(api.requests.length - 1);
    await tester.pump();
  }

  reservationTest('instant add, pending checkout gate, confirmed countdown',
      (tester) async {
    await mount(tester, bag: true);
    cart.add(dealWithDeadline(1, null));
    expect(cart.itemCount.value, 1);
    expect(cart.total, 50);
    expect(cart.items.single.reservation, isNull);
    await tester.pump();
    expect(find.text('Holding your items…'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    await controller.checkout();
    expect(api.checkouts, isEmpty);
    api.succeed(0);
    await tester.pump();
    expect(find.text('05:00'), findsOneWidget);
    expect(cart.items.single.reservation!.id, 'hold_0');
    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('04:59'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
  });

  reservationTest('409 rolls back count and total with clear feedback',
      (tester) async {
    await mount(tester);
    cart.add(dealWithDeadline(1, null));
    api.requests.single.result
        .completeError(const ApiException('server detail', statusCode: 409));
    await tester.pumpAndSettle();
    expect(cart.items, isEmpty);
    expect(cart.itemCount.value, 0);
    expect(cart.total, 0);
    expect(find.text('Could not hold this item'), findsOneWidget);
    expect(find.textContaining('server detail'), findsNothing);
  });

  reservationTest(
      'unexpected reservation error rolls back without stuck pending',
      (tester) async {
    await mount(tester);
    cart.add(dealWithDeadline(1, null));
    api.requests.single.result.completeError(StateError('offline'));
    await tester.pump();
    expect(cart.items, isEmpty);
    expect(cart.hasPendingReservations, isFalse);
  });

  reservationTest(
      'rapid edits coalesce, release before replacement, match quantity',
      (tester) async {
    await mount(tester);
    final deal = dealWithDeadline(1, null);
    cart.add(deal);
    cart.add(deal);
    cart.add(deal);
    cart.decrement(1);
    expect(cart.itemCount.value, 2);
    expect(api.requests.length, 1);
    api.releaseResult = Completer<void>();
    api.succeed(0);
    await tester.pump();
    expect(api.released, ['hold_0']);
    expect(api.requests.length, 1);
    api.releaseResult!.complete();
    await tester.pump();
    expect(api.requests.last.quantity, 2);
    api.succeed(1);
    await tester.pump();
    expect(cart.items.single.reservation!.quantity, 2);
    expect(cart.hasPendingReservations, isFalse);
  });

  reservationTest('reducing confirmed quantity replaces hold; zero releases it',
      (tester) async {
    await mount(tester);
    cart.add(dealWithDeadline(1, null));
    cart.add(dealWithDeadline(1, null));
    api.succeed(0);
    await tester.pump();
    api.succeed(1);
    await tester.pump();
    cart.decrement(1);
    expect(cart.itemCount.value, 1);
    expect(cart.hasPendingReservations, isTrue);
    await tester.pump();
    expect(api.released, ['hold_0', 'hold_1']);
    expect(api.requests.last.quantity, 1);
    api.succeed(2);
    await tester.pump();
    cart.decrement(1);
    expect(cart.items, isEmpty);
    expect(api.released.last, 'hold_2');
  });

  reservationTest(
      'failed replacement removes entire line after releasing old hold',
      (tester) async {
    await mount(tester);
    await held(tester, 1);
    cart.add(dealWithDeadline(1, null));
    await tester.pump();
    api.requests.last.result
        .completeError(const ApiException('busy', statusCode: 409));
    await tester.pump();
    expect(api.released, ['hold_0']);
    expect(cart.items, isEmpty);
  });

  reservationTest('remove and re-add cannot be overwritten by a late response',
      (tester) async {
    await mount(tester);
    cart.add(dealWithDeadline(1, null));
    cart.remove(1);
    cart.add(dealWithDeadline(1, null));
    api.succeed(1);
    await tester.pump();
    api.succeed(0);
    await tester.pump();
    expect(cart.items.single.reservation!.id, 'hold_1');
    expect(api.released, ['hold_0']);
  });

  reservationTest('clear releases confirmed and late pending holds',
      (tester) async {
    await mount(tester);
    await held(tester, 1);
    cart.add(dealWithDeadline(2, null));
    cart.clear();
    api.succeed(1);
    await tester.pump();
    expect(cart.items, isEmpty);
    expect(api.released, ['hold_0', 'hold_1']);
  });

  reservationTest(
      'exact expiry offscreen removes only expired holds with notice',
      (tester) async {
    await mount(tester);
    await held(tester, 1);
    now = now.add(const Duration(minutes: 1));
    await held(tester, 2);
    now = now.add(const Duration(minutes: 4));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(cart.items.single.deal.id, 2);
    expect(cart.total, 50);
    expect(api.released, ['hold_0']);
    expect(find.text('Your hold ended'), findsOneWidget);
    expect(api.requests.length, 2); // No automatic renewal.
  });

  reservationTest('resume removes holds that expired while backgrounded',
      (tester) async {
    await mount(tester);
    await held(tester, 1);
    clock.didChangeAppLifecycleState(AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 6));
    clock.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(cart.items, isEmpty);
    expect(api.released, ['hold_0']);
  });

  reservationTest(
      'between-tick expiry stops checkout for review of remaining bag',
      (tester) async {
    await mount(tester);
    await held(tester, 1);
    now = now.add(const Duration(minutes: 1));
    await held(tester, 2);
    now = now.add(const Duration(minutes: 4));
    await controller.checkout();
    expect(api.checkouts, isEmpty);
    expect(cart.items.single.deal.id, 2);
    expect(controller.isCheckingOut.value, isFalse);
  });

  reservationTest('checkout sends ids, locks edits and duplicate submissions',
      (tester) async {
    await mount(tester, bag: true);
    await held(tester, 1);
    final checkout = controller.checkout();
    await controller.checkout();
    expect(api.checkouts.single, [
      {'dealId': 1, 'quantity': 1, 'reservationId': 'hold_0'}
    ]);
    expect(cart.add(dealWithDeadline(2, null)), isFalse);
    cart.decrement(1);
    cart.remove(1);
    cart.clear();
    await tester.pump();
    expect(cart.itemCount.value, 1);
    expect(
        tester
            .widgetList<IconButton>(find.byType(IconButton))
            .every((button) => button.onPressed == null),
        isTrue);
    api.confirmOrder();
    await checkout;
    expect(cart.items, isEmpty);
    expect(controller.isCheckingOut.value, isFalse);
    expect(api.released, ['hold_0']);
  });

  reservationTest(
      'mid-checkout expiry waits for 410 then clears submitted holds',
      (tester) async {
    await mount(tester);
    await held(tester, 1);
    final checkout = controller.checkout();
    now = now.add(const Duration(minutes: 5));
    await tester.pump(const Duration(seconds: 1));
    expect(cart.itemCount.value, 1);
    expect(api.released, isEmpty);
    api.checkoutResult
        .completeError(const ApiException('expired', statusCode: 410));
    await checkout;
    await tester.pumpAndSettle();
    expect(cart.items, isEmpty);
    expect(controller.isCheckingOut.value, isFalse);
    expect(find.textContaining('Your order was not placed'), findsOneWidget);
    expect(api.checkouts.length, 1);
  });

  reservationTest('server 410 invalidates even locally unexpired holds',
      (tester) async {
    await mount(tester);
    await held(tester, 1);
    await held(tester, 2);
    final checkout = controller.checkout();
    api.checkoutResult
        .completeError(const ApiException('unknown', statusCode: 410));
    await checkout;
    expect(cart.items, isEmpty);
    expect(api.released, ['hold_0', 'hold_1']);
  });

  reservationTest('server success wins over local expiry during checkout',
      (tester) async {
    await mount(tester);
    await held(tester, 1);
    final checkout = controller.checkout();
    now = now.add(const Duration(minutes: 6));
    await tester.pump(const Duration(seconds: 1));
    api.confirmOrder();
    await checkout;
    await tester.pumpAndSettle();
    expect(find.text('Order confirmed'), findsOneWidget);
    expect(find.text('Your hold ended'), findsNothing);
    expect(cart.items, isEmpty);
  });

  reservationTest('other checkout failures unlock and preserve valid holds',
      (tester) async {
    await mount(tester);
    await held(tester, 1);
    final checkout = controller.checkout();
    api.checkoutResult
        .completeError(const ApiException('Payment timeout', statusCode: 502));
    await checkout;
    expect(cart.items.single.reservation!.id, 'hold_0');
    expect(controller.isCheckingOut.value, isFalse);
  });

  reservationTest('unexpected checkout error still unlocks and prunes expiry',
      (tester) async {
    await mount(tester);
    await held(tester, 1);
    final checkout = controller.checkout();
    now = now.add(const Duration(minutes: 6));
    api.checkoutResult.completeError(StateError('offline'));
    await checkout;
    expect(cart.items, isEmpty);
    expect(controller.isCheckingOut.value, isFalse);
  });

  reservationTest('release failure never creates a duplicate replacement hold',
      (tester) async {
    await mount(tester);
    await held(tester, 1);
    api.releaseResult = Completer<void>();
    cart.add(dealWithDeadline(1, null));
    api.releaseResult!.completeError(StateError('offline'));
    await tester.pump();
    expect(cart.items, isEmpty);
    expect(api.requests.length, 1);
  });
}
