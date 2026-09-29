import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:rescu/feature/home/home_controller.dart';
import 'package:rescu/feature/home/home_screen.dart';
import 'package:rescu/feature/shared_widget/deal_card.dart';
import 'package:rescu/feature/shared_widget/the_network_image.dart';
import 'package:rescu/model/deal_model.dart';
import 'package:rescu/model/paged_response_model.dart';
import 'package:rescu/repository/deal_repo.dart';
import 'package:rescu/service/analytics_service.dart';
import 'package:rescu/service/fake_api_service.dart';
import 'package:rescu/service/flash_sale_clock.dart';
import 'package:visibility_detector/visibility_detector.dart';

class _Repo extends DealRepo {
  _Repo() : super(api: FakeApiService());

  @override
  Future<List<DealModel>> fetchFlashDeals() async => [];

  @override
  Future<PagedResponseModel<DealModel>> fetchDeals({int page = 1}) async =>
      PagedResponseModel(
          items: List.generate(
              122,
              (index) => DealModel.fromJson({
                    'id': index + 1,
                    'name': 'Deal ${index + 1}',
                    'quantityLeft': 3,
                    'pickupWindow': {
                      'start': '2026-09-29T10:00:00Z',
                      'end': '2026-09-29T11:00:00Z',
                    },
                  })),
          page: 1,
          totalPages: 1);
}

void main() {
  testWidgets('scroll does not rebuild the first still-visible deal card',
      (tester) async {
    Get.testMode = true;
    final previousInterval =
        VisibilityDetectorController.instance.updateInterval;
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    final clock = Get.put(FlashSaleClock());
    final analytics = Get.put(AnalyticsService(api: FakeApiService()));
    final home = Get.put(HomeController(dealRepo: _Repo()));
    var firstCardRebuilds = 0;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      final widget = element.widget;
      if (widget is DealCard && widget.deal.id == 1) {
        firstCardRebuilds++;
      }
    };
    try {
      await tester.pumpWidget(GetMaterialApp(
        navigatorObservers: [analytics.routeObserver],
        home: const HomeScreen(),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      firstCardRebuilds = 0;
      for (final offset in [10.0, 20.0, 30.0, 40.0]) {
        home.scrollController.jumpTo(offset);
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.byKey(const ValueKey(1)), findsOneWidget);
      expect(firstCardRebuilds, 0);
      expect(tester.widget<AppBar>(find.byType(AppBar)).elevation, 2);
      home.scrollController.jumpTo(900);
      await tester.pump();
      expect(find.byType(FloatingActionButton), findsOneWidget);
      home.scrollController.jumpTo(0);
      await tester.pump();
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(tester.widget<AppBar>(find.byType(AppBar)).elevation, 0);
    } finally {
      debugOnRebuildDirtyWidget = null;
      await tester.pumpWidget(const SizedBox.shrink());
      VisibilityDetectorController.instance.notifyNow();
      home.onDelete();
      analytics.onDelete();
      clock.onDelete();
      Get.reset();
      VisibilityDetectorController.instance.updateInterval = previousInterval;
    }
  });

  testWidgets('image decode width follows finite layout width and pixel ratio',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(devicePixelRatio: 2),
        child: Center(
            child: SizedBox(
                width: 200,
                child: TheNetworkImage(
                  url: '',
                  width: double.infinity,
                  height: 160,
                ))),
      ),
    ));
    expect(
        tester
            .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
            .memCacheWidth,
        400);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
