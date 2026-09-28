import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../service/analytics_service.dart';

/// Measures the card surface; does not rebuild it while scrolling or waiting.
class DealImpression extends StatefulWidget {
  const DealImpression({
    super.key,
    required this.dealId,
    required this.source,
    required this.position,
    required this.child,
  });

  final int dealId;
  final String source;
  final int position;
  final Widget child;

  @override
  State<DealImpression> createState() => _DealImpressionState();
}

class _DealImpressionState extends State<DealImpression>
    with WidgetsBindingObserver, RouteAware {
  late final AnalyticsService _analytics;
  Key _detectorKey = UniqueKey();
  ModalRoute<dynamic>? _route;
  Timer? _dwellTimer;
  double _visibleFraction = 0;
  bool _routeVisible = true;
  bool _foreground = true;
  bool _recorded = false;

  @override
  void initState() {
    super.initState();
    _analytics = Get.find<AnalyticsService>();
    _recorded = _analytics.hasImpression(widget.dealId);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != _route) {
      _cancel();
      _analytics.routeObserver.unsubscribe(this);
      _route = route;
      _routeVisible = route?.isCurrent ?? true;
      if (route != null) _analytics.routeObserver.subscribe(this, route);
    }
  }

  bool get _eligible =>
      mounted &&
      _foreground &&
      _routeVisible &&
      (_route?.isCurrent ?? true) &&
      _visibleFraction >= 0.5 &&
      !_analytics.hasImpression(widget.dealId);

  void _visibilityChanged(VisibilityInfo info) {
    if (_analytics.hasImpression(widget.dealId)) {
      _cancel();
      if (!_recorded) setState(() => _recorded = true);
      return;
    }
    _visibleFraction = info.visibleFraction;
    _consider();
  }

  void _consider() {
    if (!_eligible) {
      _cancel();
    } else {
      _dwellTimer ??= Timer(const Duration(seconds: 1), () {
        // Apply any pending hide event before qualifying the dwell.
        VisibilityDetectorController.instance.notifyNow();
        if (_eligible) {
          _analytics.recordImpression(
            dealId: widget.dealId,
            source: widget.source,
            position: widget.position,
          );
        }
        if (mounted && _analytics.hasImpression(widget.dealId)) {
          // Disable further geometry callbacks once this deal is counted.
          // widget.child keeps its identity, so the card does not rebuild.
          setState(() => _recorded = true);
        }
        _dwellTimer = null;
      });
    }
  }

  void _cancel() {
    _dwellTimer?.cancel();
    _dwellTimer = null;
  }

  @override
  void didPush() {
    _routeVisible = _route?.isCurrent ?? true;
    _consider();
  }

  @override
  void didPushNext() {
    _routeVisible = false;
    _cancel();
  }

  @override
  void didPop() {
    _routeVisible = false;
    _cancel();
  }

  @override
  void didPopNext() {
    _routeVisible = true;
    _consider();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _consider();
  }

  @override
  void didUpdateWidget(covariant DealImpression oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dealId != widget.dealId ||
        oldWidget.source != widget.source) {
      _cancel();
      VisibilityDetectorController.instance.forget(_detectorKey);
      _detectorKey = UniqueKey();
      _visibleFraction = 0;
      _recorded = _analytics.hasImpression(widget.dealId);
    }
  }

  @override
  void dispose() {
    _cancel();
    _analytics.routeObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    VisibilityDetectorController.instance.forget(_detectorKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => VisibilityDetector(
        key: _detectorKey,
        onVisibilityChanged: _recorded ? null : _visibilityChanged,
        child: widget.child,
      );
}
