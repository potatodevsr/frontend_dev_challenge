import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rescu/feature/search/search_deals_controller.dart';
import 'package:rescu/model/deal_model.dart';
import 'package:rescu/repository/deal_repo.dart';
import 'package:rescu/service/fake_api_service.dart';

class _SearchRequest {
  _SearchRequest(this.query);
  final String query;
  final result = Completer<List<DealModel>>();
}

class _SearchRepo extends DealRepo {
  _SearchRepo() : super(api: FakeApiService());
  final requests = <_SearchRequest>[];

  @override
  Future<List<DealModel>> search(String query) {
    final request = _SearchRequest(query);
    requests.add(request);
    return request.result.future;
  }
}

DealModel _deal(int id) => DealModel.fromJson({
      'id': id,
      'pickupWindow': {
        'start': '2026-09-29T10:00:00Z',
        'end': '2026-09-29T11:00:00Z',
      },
    });

void main() {
  late _SearchRepo repo;
  late SearchDealsController controller;

  void searchTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      repo = _SearchRepo();
      controller = SearchDealsController(dealRepo: repo)..onStart();
      try {
        await body(tester);
      } finally {
        controller.onDelete();
      }
    });
  }

  searchTest('late response cannot replace results for the latest query',
      (tester) async {
    controller.onQueryChanged('s');
    await tester.pump(const Duration(milliseconds: 500));
    controller.onQueryChanged('sushi');
    await tester.pump(const Duration(milliseconds: 500));
    expect(repo.requests.map((r) => r.query), ['s', 'sushi']);
    repo.requests[1].result.complete([_deal(2)]);
    await tester.pump();
    repo.requests[0].result.complete([_deal(1)]);
    await tester.pump();
    expect(controller.results.map((d) => d.id), [2]);
    expect(controller.isLoading.value, isFalse);
  });

  searchTest('input invalidates in-flight results before next debounce fires',
      (tester) async {
    controller.onQueryChanged('s');
    await tester.pump(const Duration(milliseconds: 500));
    controller.onQueryChanged('sushi');
    repo.requests.single.result.complete([_deal(1)]);
    await tester.pump();
    expect(controller.results, isEmpty);
    expect(controller.isLoading.value, isTrue);
    await tester.pump(const Duration(milliseconds: 500));
    repo.requests.last.result.complete([_deal(2)]);
    await tester.pump();
    expect(controller.results.single.id, 2);
  });

  searchTest('clearing input immediately resets and rejects a late success',
      (tester) async {
    controller.onQueryChanged('sushi');
    await tester.pump(const Duration(milliseconds: 500));
    controller.onQueryChanged('   ');
    expect(controller.hasSearched.value, isFalse);
    expect(controller.isLoading.value, isFalse);
    expect(controller.results, isEmpty);
    repo.requests.single.result.complete([_deal(1)]);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.results, isEmpty);
    expect(repo.requests.length, 1);
  });

  searchTest('rapid typing sends only the latest trimmed query',
      (tester) async {
    controller.onQueryChanged('s');
    await tester.pump(const Duration(milliseconds: 300));
    controller.onQueryChanged('su');
    await tester.pump(const Duration(milliseconds: 300));
    controller.onQueryChanged(' sushi ');
    await tester.pump(const Duration(milliseconds: 499));
    expect(repo.requests, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(repo.requests.single.query, 'sushi');
    repo.requests.single.result.complete([]);
    await tester.pump();
    expect(controller.hasSearched.value, isTrue);
    expect(controller.isLoading.value, isFalse);
  });

  searchTest('stale failure cannot stop the current loading indicator',
      (tester) async {
    controller.onQueryChanged('s');
    await tester.pump(const Duration(milliseconds: 500));
    controller.onQueryChanged('sushi');
    await tester.pump(const Duration(milliseconds: 500));
    repo.requests.first.result.completeError(Exception('old failure'));
    await tester.pump();
    expect(controller.isLoading.value, isTrue);
    repo.requests.last.result.completeError(Exception('current failure'));
    await tester.pump();
    expect(controller.isLoading.value, isFalse);
    expect(controller.results, isEmpty);
  });

  searchTest('repeating a query does not revive its older request',
      (tester) async {
    controller.onQueryChanged('sushi');
    await tester.pump(const Duration(milliseconds: 500));
    controller.onQueryChanged('bakery');
    controller.onQueryChanged('sushi');
    await tester.pump(const Duration(milliseconds: 500));
    repo.requests.first.result.complete([_deal(1)]);
    await tester.pump();
    expect(controller.results, isEmpty);
    expect(controller.isLoading.value, isTrue);
    repo.requests.last.result.complete([_deal(2)]);
    await tester.pump();
    expect(controller.results.single.id, 2);
  });

  searchTest('closing cancels debounce and ignores outstanding responses',
      (tester) async {
    controller.onQueryChanged('s');
    await tester.pump(const Duration(milliseconds: 500));
    controller.onQueryChanged('sushi');
    controller.onDelete();
    final loadingAtClose = controller.isLoading.value;
    repo.requests.first.result.complete([_deal(1)]);
    await tester.pump(const Duration(seconds: 1));
    expect(repo.requests.length, 1);
    expect(controller.results, isEmpty);
    expect(controller.isLoading.value, loadingAtClose);
    controller.onQueryChanged('after close');
    await tester.pump(const Duration(seconds: 1));
    expect(repo.requests.length, 1);
  });
}
