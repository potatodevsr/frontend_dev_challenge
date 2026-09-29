import 'dart:async';

import 'package:get/get.dart';

import '../../model/deal_model.dart';
import '../../repository/deal_repo.dart';
import '../../util/log_service.dart';

class SearchDealsController extends GetxController {
  final DealRepo dealRepo;

  SearchDealsController({required this.dealRepo});

  final results = <DealModel>[].obs;
  final isLoading = false.obs;
  final hasSearched = false.obs;
  final query = ''.obs;

  Timer? _debounce;
  int _generation = 0;

  void onQueryChanged(String value) {
    if (isClosed) return;
    // Invalidate on input, not when the next request eventually starts.
    final generation = ++_generation;
    _debounce?.cancel();
    query.value = value;
    results.clear();
    final searchQuery = value.trim();
    hasSearched.value = searchQuery.isNotEmpty;
    isLoading.value = searchQuery.isNotEmpty;
    if (searchQuery.isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 500),
        () => _search(searchQuery, generation));
  }

  bool _isCurrent(int generation) => !isClosed && generation == _generation;

  Future<void> _search(String query, int generation) async {
    if (!_isCurrent(generation)) return;
    try {
      final found = await dealRepo.search(query);
      if (_isCurrent(generation)) results.assignAll(found);
    } catch (e) {
      if (_isCurrent(generation)) LogService.error('search failed', e);
    } finally {
      if (_isCurrent(generation)) isLoading.value = false;
    }
  }

  @override
  void onClose() {
    _generation++;
    _debounce?.cancel();
    super.onClose();
  }
}
