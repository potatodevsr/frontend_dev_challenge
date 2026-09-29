// Development-only entry point for reproducible DevTools captures.
// flutter run --debug -t tool/profile_app.dart
import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:rescu/feature/home/home_controller.dart';
import 'package:rescu/main.dart' as app;

Future<void> main() async {
  await app.main();
  registerExtension('ext.rescu.homeProfile', (method, parameters) async {
    final home = Get.find<HomeController>();
    switch (parameters['action']) {
      case 'load':
        while (home.isLoading.value) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        while (home.hasMore) {
          await home.loadMore();
        }
      case 'scroll':
        final target = parameters['to'] == 'bottom'
            ? home.scrollController.position.maxScrollExtent
            : 0.0;
        await home.scrollController.animateTo(target,
            duration: const Duration(seconds: 4), curve: Curves.linear);
      case 'snapshot':
        break;
    }
    final cache = PaintingBinding.instance.imageCache;
    return ServiceExtensionResponse.result(jsonEncode({
      'deals': home.deals.length,
      'offset': home.scrollController.offset,
      'image_cache_bytes': cache.currentSizeBytes,
      'cached_images': cache.currentSize,
      'live_images': cache.liveImageCount,
      'pending_images': cache.pendingImageCount,
    }));
  });
}
