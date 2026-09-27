import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pull_to_refresh/pull_to_refresh.dart';
import 'package:rescu/feature/home/home_controller.dart';
import 'package:rescu/model/deal_model.dart';
import 'package:rescu/model/paged_response_model.dart';
import 'package:rescu/repository/deal_repo.dart';
import 'package:rescu/service/fake_api_service.dart';

class _Request {
  final int page;
  final result = Completer<PagedResponseModel<DealModel>>();

  _Request(this.page);
}

class _ControlledRepo extends DealRepo {
  _ControlledRepo() : super(api: FakeApiService());

  final requests = <_Request>[];
  final catalog =
      (jsonDecode(File('assets/data/deals.json').readAsStringSync()) as List)
          .map((raw) => DealModel.fromJson({
                ...raw as Map<String, dynamic>,
                'pickupWindow': {
                  'start': '2026-09-27T00:00:00Z',
                  'end': '2026-09-27T12:00:00Z',
                },
              }))
          .toList();

  @override
  Future<PagedResponseModel<DealModel>> fetchDeals({int page = 1}) {
    final request = _Request(page);
    requests.add(request);
    return request.result.future;
  }

  void complete(int index) {
    final request = requests[index];
    request.result.complete(PagedResponseModel(
      items: catalog
          .skip((request.page - 1) * FakeApiService.pageSize)
          .take(FakeApiService.pageSize)
          .toList(),
      page: request.page,
      totalPages: (catalog.length / FakeApiService.pageSize).ceil(),
    ));
  }

  void fail(int index) =>
      requests[index].result.completeError(Exception('Request failed'));
}

void main() {
  late _ControlledRepo repo;
  late HomeController controller;

  setUp(() {
    repo = _ControlledRepo();
    controller = HomeController(dealRepo: repo);
  });
  tearDown(() => controller.onClose());

  Future<void> pumpFrame(WidgetTester tester) async {
    // RefreshController updates its footer in post-frame callbacks.
    tester.binding.scheduleFrame();
    await tester.pump();
  }

  Future<void> seed() async {
    final initial = controller.refreshDeals();
    repo.complete(0);
    await initial;
  }

  Future<void> nextPage() async {
    final next = controller.loadMore();
    repo.complete(repo.requests.length - 1);
    await next;
  }

  for (final refreshFirst in [true, false]) {
    testWidgets('refresh race, refresh completes first: $refreshFirst',
        (tester) async {
      await seed();
      final oldPage = controller.loadMore();
      final refresh = controller.refreshDeals();
      expect(repo.requests.map((r) => r.page), [1, 2, 1]);

      if (refreshFirst) {
        repo.complete(2);
        await refresh;
        repo.complete(1);
        await oldPage;
      } else {
        repo.complete(1);
        await oldPage;
        repo.complete(2);
        await refresh;
      }
      expect(controller.deals.map((d) => d.id),
          repo.catalog.take(20).map((d) => d.id));

      for (var i = 0; controller.hasMore && i < 10; i++) {
        await nextPage();
      }
      expect(controller.hasMore, isFalse);
      expect(controller.deals.map((d) => d.id), repo.catalog.map((d) => d.id));
      await pumpFrame(tester);
    });
  }

  testWidgets('pagination is blocked during refresh and while already loading',
      (tester) async {
    await seed();
    final refresh = controller.refreshDeals();
    await controller.loadMore();
    expect(repo.requests.length, 2);
    repo.complete(1);
    await refresh;
    final next = controller.loadMore();
    await controller.loadMore();
    expect(repo.requests.length, 3);
    repo.complete(2);
    await next;
    await pumpFrame(tester);
  });

  for (final staleFails in [false, true]) {
    testWidgets('stale pagination cannot unlock newer load, fails: $staleFails',
        (tester) async {
      await seed();
      final stale = controller.loadMore();
      final refresh = controller.refreshDeals();
      repo.complete(2);
      await refresh;
      await pumpFrame(tester);

      final current = controller.loadMore();
      expect(repo.requests.length, 4);
      controller.refreshController.footerMode!.value = LoadStatus.loading;
      if (staleFails) {
        repo.fail(1);
      } else {
        repo.complete(1);
      }
      await stale;
      await pumpFrame(tester);
      expect(controller.deals.length, 20);
      expect(controller.refreshController.footerStatus, LoadStatus.loading);
      await controller.loadMore();
      expect(repo.requests.length, 4);
      repo.complete(3);
      await current;
      await nextPage();
      expect(repo.requests.last.page, 3);
      expect(controller.deals.length, 60);
      await pumpFrame(tester);
    });
  }

  testWidgets('failed pagination retries the same page', (tester) async {
    await seed();
    final failed = controller.loadMore();
    repo.fail(1);
    await failed;
    await pumpFrame(tester);
    expect(controller.deals.length, 20);
    expect(controller.refreshController.footerStatus, LoadStatus.failed);
    await nextPage();
    expect(repo.requests.map((r) => r.page), [1, 2, 2]);
    expect(controller.deals.length, 40);
    await pumpFrame(tester);
  });

  testWidgets('failed refresh preserves the committed page and allows retry',
      (tester) async {
    await seed();
    await nextPage();
    final refresh = controller.refreshDeals();
    repo.fail(2);
    await refresh;
    expect(controller.deals.length, 40);
    expect(controller.refreshController.headerStatus, RefreshStatus.failed);
    await nextPage();
    expect(repo.requests.last.page, 3);
    expect(controller.deals.length, 60);
    final retry = controller.refreshDeals();
    repo.complete(4);
    await retry;
    expect(controller.deals.length, 20);
    await pumpFrame(tester);
  });

  testWidgets('older refresh cannot replace the latest refreshed feed',
      (tester) async {
    await seed();
    final older = controller.refreshDeals();
    final newer = controller.refreshDeals();
    repo.complete(2);
    await newer;
    await nextPage();
    repo.complete(1);
    await older;
    expect(controller.deals.length, 40);
    await nextPage();
    expect(repo.requests.last.page, 3);
    await pumpFrame(tester);
  });

  testWidgets('refresh resets an exhausted footer and resumes at page two',
      (tester) async {
    await seed();
    for (var i = 0; controller.hasMore && i < 10; i++) {
      await nextPage();
    }
    await pumpFrame(tester);
    await controller.loadMore();
    await pumpFrame(tester);
    expect(controller.refreshController.footerStatus, LoadStatus.noMore);
    final refresh = controller.refreshDeals();
    repo.complete(repo.requests.length - 1);
    await refresh;
    await pumpFrame(tester);
    expect(controller.refreshController.footerStatus, LoadStatus.idle);
    await nextPage();
    expect(repo.requests.last.page, 2);
    expect(controller.deals.length, 40);
    await pumpFrame(tester);
  });
}
