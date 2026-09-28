import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:rescu/feature/shared_widget/deal_impression.dart';
import 'package:rescu/service/analytics_service.dart';
import 'package:rescu/service/fake_api_service.dart';
import 'package:visibility_detector/visibility_detector.dart';

class _AnalyticsApi extends FakeApiService {
  final requests = <List<Map<String, dynamic>>>[];
  final responses = <Completer<void>>[];
  bool holdRequests = false;
  bool failNext = false;

  @override
  Future<void> sendAnalyticsBatch(List<Map<String, dynamic>> events) async {
    requests.add(events);
    if (failNext) {
      failNext = false;
      throw Exception('Simulated analytics failure');
    }
    if (holdRequests) {
      final response = Completer<void>();
      responses.add(response);
      await response.future;
    }
  }
}

class _BuildCounter extends StatelessWidget {
  const _BuildCounter(this.onBuild);
  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return const SizedBox(width: 60, height: 24, child: Text('Deal'));
  }
}

void main() {
  late DateTime now;
  late _AnalyticsApi api;
  late AnalyticsService analytics;
  late Duration previousInterval;

  setUp(() {
    now = DateTime.utc(2026, 9, 28, 12);
    api = _AnalyticsApi();
    analytics = AnalyticsService(api: api, now: () => now);
    Get.testMode = true;
    previousInterval = VisibilityDetectorController.instance.updateInterval;
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  tearDown(() {
    analytics.onDelete();
    Get.reset();
    VisibilityDetectorController.instance.updateInterval = previousInterval;
  });

  Future<void> advance(WidgetTester tester, Duration elapsed) async {
    now = now.add(elapsed);
    await tester.pump(elapsed);
  }

  Future<void> mount(WidgetTester tester, Widget child) async {
    Get.put(analytics);
    await tester.pumpWidget(GetMaterialApp(
      navigatorObservers: [analytics.routeObserver],
      home: Scaffold(body: child),
    ));
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    VisibilityDetectorController.instance.notifyNow();
    analytics.onDelete();
  }

  Widget clippedCard(double height,
      {int id = 42, String source = 'home_feed', int position = 0}) {
    return Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 200,
        height: height,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minHeight: 200,
            maxHeight: 200,
            child: DealImpression(
              dealId: id,
              source: source,
              position: position,
              child: const SizedBox(width: 200, height: 200),
            ),
          ),
        ),
      ),
    );
  }

  void record(int id, {String source = 'home_feed', int position = 0}) {
    analytics.recordImpression(dealId: id, source: source, position: position);
  }

  testWidgets('49% never qualifies; exactly 50% requires a full second',
      (tester) async {
    var height = 98.0;
    late StateSetter update;
    await mount(tester, StatefulBuilder(builder: (context, setState) {
      update = setState;
      return clippedCard(height, position: 3);
    }));
    await advance(tester, const Duration(seconds: 2));
    expect(analytics.events, isEmpty);
    update(() => height = 100);
    await tester.pump();
    await advance(tester, const Duration(milliseconds: 999));
    expect(analytics.events, isEmpty);
    await advance(tester, const Duration(milliseconds: 1));
    expect(analytics.events.single.name, 'deal_impression');
    expect(analytics.events.single.properties,
        {'deal_id': 42, 'source': 'home_feed', 'position': 3});
    await finish(tester);
  });

  testWidgets('a brief dip below 50% resets the continuous dwell',
      (tester) async {
    var height = 200.0;
    late StateSetter update;
    await mount(tester, StatefulBuilder(builder: (context, setState) {
      update = setState;
      return clippedCard(height);
    }));
    await advance(tester, const Duration(milliseconds: 700));
    update(() => height = 98);
    await tester.pump();
    await advance(tester, const Duration(milliseconds: 16));
    update(() => height = 200);
    await tester.pump();
    await advance(tester, const Duration(milliseconds: 999));
    expect(analytics.events, isEmpty);
    await advance(tester, const Duration(milliseconds: 1));
    expect(analytics.events, hasLength(1));
    await finish(tester);
  });

  testWidgets('simultaneous copies and other screens record a deal only once',
      (tester) async {
    await mount(
        tester,
        Row(children: [
          SizedBox(width: 200, child: clippedCard(200)),
          SizedBox(
              width: 200,
              child: clippedCard(200, source: 'flash_rail', position: 4)),
        ]));
    await advance(tester, const Duration(seconds: 1));
    expect(analytics.events, hasLength(1));
    record(42, source: 'search', position: 9);
    expect(analytics.events, hasLength(1));
    expect(analytics.events.single.properties['source'], 'home_feed');
    await finish(tester);
  });

  testWidgets('disposing before dwell completes never records an impression',
      (tester) async {
    await mount(tester, clippedCard(200));
    await advance(tester, const Duration(milliseconds: 700));
    await tester.pumpWidget(const SizedBox.shrink());
    await advance(tester, const Duration(seconds: 2));
    expect(analytics.events, isEmpty);
    await finish(tester);
  });

  testWidgets('background time does not count toward the continuous second',
      (tester) async {
    await mount(tester, clippedCard(200));
    await advance(tester, const Duration(milliseconds: 700));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await advance(tester, const Duration(seconds: 10));
    expect(analytics.events, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await advance(tester, const Duration(milliseconds: 999));
    expect(analytics.events, isEmpty);
    await advance(tester, const Duration(milliseconds: 1));
    expect(analytics.events, hasLength(1));
    await finish(tester);
  });

  testWidgets('a covering route cancels dwell and returning starts over',
      (tester) async {
    await mount(tester, clippedCard(200));
    await advance(tester, const Duration(milliseconds: 700));
    final context = tester.element(find.byType(DealImpression));
    unawaited(Navigator.of(context).push(PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, __, ___) => const Scaffold(body: Text('Other page')),
    )));
    await tester.pump();
    await advance(tester, const Duration(seconds: 2));
    expect(analytics.events, isEmpty);
    Navigator.of(tester.element(find.text('Other page'))).pop();
    await tester.pump();
    await tester.pump();
    await advance(tester, const Duration(milliseconds: 999));
    expect(analytics.events, isEmpty);
    await advance(tester, const Duration(milliseconds: 1));
    expect(analytics.events, hasLength(1));
    await finish(tester);
  });

  testWidgets('reusing an element for another deal restarts visibility dwell',
      (tester) async {
    var id = 1;
    late StateSetter update;
    await mount(tester, StatefulBuilder(builder: (context, setState) {
      update = setState;
      return clippedCard(200, id: id, source: 'search', position: 2);
    }));
    await advance(tester, const Duration(milliseconds: 700));
    update(() => id = 2);
    await tester.pump();
    await advance(tester, const Duration(milliseconds: 999));
    expect(analytics.events, isEmpty);
    await advance(tester, const Duration(milliseconds: 1));
    expect(analytics.events.single.properties,
        {'deal_id': 2, 'source': 'search', 'position': 2});
    await finish(tester);
  });

  testWidgets('120 visible cards qualify without rebuilding their children',
      (tester) async {
    var cardBuilds = 0;
    await mount(
        tester,
        Wrap(
            children: List.generate(120, (id) {
          return DealImpression(
            dealId: id,
            source: 'home_feed',
            position: id,
            child: _BuildCounter(() => cardBuilds++),
          );
        })));
    expect(cardBuilds, 120);
    await advance(tester, const Duration(seconds: 1));
    await tester.pump();
    expect(analytics.events, hasLength(120));
    expect(cardBuilds, 120);
    expect(api.requests, hasLength(12));
    expect(api.requests.every((batch) => batch.length == 10), isTrue);
    expect(
        tester
            .widgetList<VisibilityDetector>(find.byType(VisibilityDetector))
            .every((detector) => detector.onVisibilityChanged == null),
        isTrue);
    await finish(tester);
  });

  testWidgets('ten events flush immediately and preserve all properties',
      (tester) async {
    for (var id = 0; id < 9; id++) {
      record(id, source: 'search', position: id);
    }
    expect(api.requests, isEmpty);
    record(9, source: 'search', position: 9);
    expect(api.requests.single, hasLength(10));
    expect(api.requests.single.last['properties'],
        {'deal_id': 9, 'source': 'search', 'position': 9});
    await tester.pump();
    await advance(tester, const Duration(seconds: 15));
    expect(api.requests, hasLength(1));
    analytics.onDelete();
  });

  testWidgets('15-second flush deadline does not slide with later events',
      (tester) async {
    record(1);
    await advance(tester, const Duration(seconds: 14));
    record(2);
    expect(api.requests, isEmpty);
    await advance(tester, const Duration(milliseconds: 999));
    expect(api.requests, isEmpty);
    await advance(tester, const Duration(milliseconds: 1));
    expect(api.requests.single, hasLength(2));
    analytics.onDelete();
  });

  testWidgets('events arriving during a request keep their own deadline',
      (tester) async {
    api.holdRequests = true;
    for (var id = 0; id < 10; id++) {
      record(id);
    }
    await advance(tester, const Duration(seconds: 2));
    record(10);
    await advance(tester, const Duration(seconds: 3));
    api.responses.first.complete();
    await tester.pump();
    await advance(tester, const Duration(seconds: 11));
    expect(api.requests, hasLength(1));
    await advance(tester, const Duration(seconds: 1));
    expect(api.requests, hasLength(2));
    expect(api.requests.last.single['properties']['deal_id'], 10);
    api.responses.last.complete();
    await tester.pump();
    analytics.onDelete();
  });

  testWidgets('in-flight batches serialize without dropping newer events',
      (tester) async {
    api.holdRequests = true;
    for (var id = 0; id < 25; id++) {
      record(id);
    }
    expect(api.requests, hasLength(1));
    api.responses[0].complete();
    await tester.pump();
    expect(api.requests, hasLength(2));
    api.responses[1].complete();
    await tester.pump();
    await advance(tester, const Duration(seconds: 15));
    expect(api.requests.map((batch) => batch.length), [10, 10, 5]);
    expect(
        api.requests
            .expand((batch) => batch)
            .map((event) => event['properties']['deal_id']),
        List.generate(25, (id) => id));
    api.responses[2].complete();
    await tester.pump();
    analytics.onDelete();
  });

  testWidgets('failed delivery retries without recording impressions twice',
      (tester) async {
    api.failNext = true;
    for (var id = 0; id < 10; id++) {
      record(id);
    }
    await tester.pump();
    record(0, source: 'flash_rail');
    record(10);
    await advance(tester, const Duration(seconds: 4));
    expect(api.requests, hasLength(1));
    await advance(tester, const Duration(seconds: 1));
    expect(api.requests, hasLength(2));
    expect(api.requests[1], api.requests[0]);
    expect(analytics.events, hasLength(11));
    await advance(tester, const Duration(seconds: 10));
    expect(api.requests, hasLength(3));
    expect(api.requests.last.single['properties']['deal_id'], 10);
    analytics.onDelete();
  });

  testWidgets('closing the service cancels timers and ignores late delivery',
      (tester) async {
    api.holdRequests = true;
    for (var id = 0; id < 11; id++) {
      record(id);
    }
    analytics.onDelete();
    api.responses.first.complete();
    await advance(tester, const Duration(seconds: 30));
    expect(api.requests, hasLength(1));
    record(12);
    expect(analytics.events, hasLength(11));
  });
}
