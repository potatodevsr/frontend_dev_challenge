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

  @override

  void onInit() {
    super.onInit();

  debounce(
  query,
  (value) => _search(value),
      time: const Duration(milliseconds: 500),
    );
   }

  void onQueryChanged(String value) {
  query.value = value;
  }  

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      results.clear();
      hasSearched.value = false;
      return;
    }
    isLoading.value = true;
    hasSearched.value = true;
    try {
      final found = await dealRepo.search(query);
      results.assignAll(found);
    } catch (e) {
      LogService.error('search failed', e);
    }
    isLoading.value = false;
  }
}
