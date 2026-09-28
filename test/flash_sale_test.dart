import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:rescu/feature/cart/cart_controller.dart';
import 'package:rescu/feature/deal/deal_details_controller.dart';
import 'package:rescu/feature/shared_widget/flash_sale_countdown.dart';
import 'package:rescu/model/deal_model.dart';
import 'package:rescu/repository/order_repo.dart';
import 'package:rescu/repository/deal_repo.dart';
import 'package:rescu/service/analytics_service.dart';
import 'package:rescu/service/cart_service.dart';
import 'package:rescu/service/fake_api_service.dart';
import 'package:rescu/service/flash_sale_clock.dart';

DealModel dealWithDeadline(int id, DateTime? deadline) => DealModel.fromJson({
      'id': id,
      'name': 'Deal $id',
      'price': 50,
      'quantityLeft': 3,
      'pickupWindow': {
        'start': '2026-09-28T10:00:00Z',
        'end': '2026-09-28T23:00:00Z',
      },
      'flashSaleEndsAt': deadline?.toIso8601String(),
    });

void main() {
  late DateTime now;
  late FlashSaleClock clock;
  late CartService cart;

  setUp(() {
    now = DateTime.utc(2026, 9, 28, 12);
    Get.testMode = true;
    clock = FlashSaleClock(now: () => now);
    cart = CartService(clock: clock);
  });

  tearDown(() {
    cart.onDelete();
    clock.onDelete();
    Get.reset();
  });

  Future<void> mount(WidgetTester tester, [Widget? child]) async {
    // Start timers inside the widget test's fake-async zone.
    Get.put(clock);
    Get.put(cart);
    await tester.pumpWidget(GetMaterialApp(
      home: Scaffold(body: child ?? const Text('Home')),
    ));
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester) async {
    Get.closeAllSnackbars();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    cart.onDelete();
    clock.onDelete();
    Get.reset();
  }

  testWidgets('formats hour boundary, fractional seconds and exact expiry',
      (tester) async {
    expect(flashSaleTimeLeft(now.add(const Duration(seconds: 3599)), now),
        '59:59');
    expect(
        flashSaleTimeLeft(now.add(const Duration(hours: 1)), now), '01:00:00');
    expect(flashSaleTimeLeft(now.add(const Duration(seconds: 3601)), now),
        '01:00:01');
    expect(flashSaleTimeLeft(now.add(const Duration(microseconds: 1)), now),
        '00:01');
    expect(flashSaleTimeLeft(now, now), 'Expired');
    expect(flashSaleTimeLeft(now.subtract(const Duration(days: 1)), now),
        'Expired');
    await finish(tester);
  });

  testWidgets('120 countdowns update without rebuilding list or card shells',
      (tester) async {
    final deadline = now.add(const Duration(minutes: 1));
    var listBuilds = 0;
    var cardBuilds = 0;
    await mount(tester, Builder(builder: (context) {
      listBuilds++;
      return Wrap(
          children: List.generate(120, (index) {
        return FlashSaleAvailability(
          endsAt: deadline,
          builder: (context, expired) {
            cardBuilds++;
            return SizedBox(
              width: 65,
              height: 24,
              child: InkWell(
                onTap: expired ? null : () {},
                child: FlashSaleCountdown(endsAt: deadline),
              ),
            );
          },
        );
      }));
    }));
    expect(find.text('01:00'), findsNWidgets(120));
    expect(cardBuilds, 120);

    for (var second = 1; second <= 5; second++) {
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('00:${60 - second}'), findsNWidgets(120));
      expect(cardBuilds, 120);
      expect(listBuilds, 1);
    }

    now = deadline;
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Expired'), findsNWidgets(120));
    expect(cardBuilds, 240); // One availability transition per card.
    expect(listBuilds, 1);
    expect(
        tester
            .widgetList<InkWell>(find.byType(InkWell))
            .every((card) => card.onTap == null),
        isTrue);

    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(cardBuilds, 240);
    await finish(tester);
    // All widget listeners and the shared timer must be disposed safely.
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('cart expires offscreen, updates totals and shows one notice',
      (tester) async {
    await mount(tester);
    final deadline = now.add(const Duration(seconds: 2));
    cart.add(dealWithDeadline(1, deadline));
    cart.add(dealWithDeadline(1, deadline));
    cart.add(dealWithDeadline(2, deadline));
    cart.add(dealWithDeadline(3, null));
    expect(cart.itemCount.value, 4);
    expect(cart.total, 200);

    now = deadline;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 400));
    expect(cart.items.map((item) => item.deal.id), [3]);
    expect(cart.itemCount.value, 1);
    expect(cart.total, 50);
    expect(find.text('Flash sale expired'), findsOneWidget);
    expect(find.text('Removed from your bag: Deal 1, Deal 2.'), findsOneWidget);
    expect(cart.removeExpiredDeals(), isFalse);
    await finish(tester);
  });

  testWidgets('rejects stale add and quantity increase between clock ticks',
      (tester) async {
    await mount(tester);
    final flash = dealWithDeadline(1, now.add(const Duration(seconds: 1)));
    expect(cart.add(flash), isTrue);
    now = now.add(const Duration(seconds: 1));
    // No timer pump: the mutation itself must check the current time.
    expect(cart.add(flash), isFalse);
    expect(cart.items, isEmpty);
    await tester.pump();
    await finish(tester);
  });

  testWidgets('rejects initially expired deals and preserves ordinary deals',
      (tester) async {
    await mount(tester);
    expect(cart.add(dealWithDeadline(1, now)), isFalse);
    expect(cart.add(dealWithDeadline(2, null)), isTrue);
    now = now.add(const Duration(days: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(cart.items.single.deal.id, 2);
    await finish(tester);
  });

  testWidgets('resume catches up countdown, disabled state and bag immediately',
      (tester) async {
    final deadline = now.add(const Duration(seconds: 30));
    await mount(
        tester,
        FlashSaleAvailability(
          endsAt: deadline,
          builder: (context, expired) => FilledButton(
            onPressed: expired ? null : () {},
            child: FlashSaleCountdown(endsAt: deadline),
          ),
        ));
    cart.add(dealWithDeadline(1, deadline));
    clock.didChangeAppLifecycleState(AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 2));
    clock.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('Expired'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    expect(cart.items, isEmpty);
    await finish(tester);
  });

  testWidgets('checkout stops to let user review a bag changed by expiry',
      (tester) async {
    await mount(tester);
    cart.add(dealWithDeadline(1, now.add(const Duration(seconds: 1))));
    cart.add(dealWithDeadline(2, null));
    now = now.add(const Duration(seconds: 1));
    final controller = CartController(
      cartService: cart,
      // Uninitialized backend: any unintended request fails the test.
      orderRepo: OrderRepo(api: FakeApiService()),
    );
    await controller.checkout();
    expect(cart.items.single.deal.id, 2);
    expect(controller.isCheckingOut.value, isFalse);
    await finish(tester);
  });

  testWidgets('detail action cannot show Added to bag for an expired deal',
      (tester) async {
    await mount(tester);
    final controller = DealDetailsController(
      dealRepo: DealRepo(api: FakeApiService()),
      cartService: cart,
      analytics: AnalyticsService(),
    );
    controller.deal.value = dealWithDeadline(1, now);
    controller.addToCart();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(cart.items, isEmpty);
    expect(find.text('Flash sale expired'), findsOneWidget);
    expect(find.text('Added to bag'), findsNothing);
    await finish(tester);
  });

  testWidgets('reused countdown responds to a new deadline and normal deals',
      (tester) async {
    DateTime? deadline = now;
    late StateSetter update;
    await mount(tester, StatefulBuilder(builder: (context, setState) {
      update = setState;
      return FlashSaleAvailability(
        endsAt: deadline,
        builder: (context, expired) => FilledButton(
          onPressed: expired ? null : () {},
          child: deadline == null
              ? const Text('Ordinary deal')
              : FlashSaleCountdown(endsAt: deadline!),
        ),
      );
    }));
    expect(find.text('Expired'), findsOneWidget);
    update(() => deadline = now.add(const Duration(seconds: 5)));
    await tester.pump();
    expect(find.text('00:05'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('00:04'), findsOneWidget);
    update(() => deadline = null);
    await tester.pump();
    now = now.add(const Duration(days: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Ordinary deal'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
    await finish(tester);
  });
}
