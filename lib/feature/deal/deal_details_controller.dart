import 'package:get/get.dart';

import '../../model/deal_model.dart';
import '../../repository/deal_repo.dart';
import '../../service/analytics_service.dart';
import '../../service/cart_service.dart';
import '../../util/log_service.dart';

class DealDetailsController extends GetxController {
  final DealRepo dealRepo;
  final CartService cartService;
  final AnalyticsService analytics;

  DealDetailsController({
    required this.dealRepo,
    required this.cartService,
    required this.analytics,
  });

  // ข้อมูลยังว่างได้ระหว่างรอ backend
  final deal = Rxn<DealModel>();
  final isLoading = false.obs;
  final loadError = RxnString();

  final _quantityLeft = RxnInt();
  int? get quantityLeft => _quantityLeft.value;

  Worker? _cartWorker;

  late final DealModel? _argumentDeal;
  late final int? _dealId;
  late final String _source;

  @override
  void onInit() {
    super.onInit();

    // เก็บข้อมูลของเส้นทางนี้ก่อนเริ่มโหลด
    final arguments = Get.arguments;
    _argumentDeal = arguments is DealModel ? arguments : null;
    _dealId = int.tryParse(Get.parameters['id'] ?? '');
    _source = Get.parameters['source'] ?? 'unknown';

    loadDeal();
  }

  Future<void> loadDeal() async {
    if (isClosed || isLoading.value || deal.value != null) return;

    isLoading.value = true;
    loadError.value = null;

    try {
      final id = _dealId ?? _argumentDeal?.id;

      if (id == null) {
        loadError.value = 'This link has no valid deal ID.';
        return;
      }

      final initialDeal = _argumentDeal;

      // ใช้ข้อมูลจาก Home ถ้าตรงกับ id
      // ถ้าไม่มี ให้ขอข้อมูลจาก backend
      final loadedDeal = initialDeal != null && initialDeal.id == id
          ? initialDeal
          : await dealRepo.fetchById(id);

      // ผู้ใช้อาจออกจากหน้านี้ระหว่างรอข้อมูล
      if (isClosed) return;

      _quantityLeft.value = loadedDeal.quantityLeft;

      analytics.logEvent('deal_details_view', {
        'deal_id': loadedDeal.id,
        'source': _source,
      });

      deal.value = loadedDeal;

      _cartWorker ??= ever(
        cartService.itemCount,
        (_) => _recheckAvailability(),
      );
    } catch (e) {
      if (isClosed) return;

      LogService.error('load deal failed', e);
      loadError.value = 'Could not load this deal. Please try again.';
    } finally {
      if (!isClosed) {
        isLoading.value = false;
      }
    }
  }

  Future<void> _recheckAvailability() async {
    final currentDeal = deal.value;
    if (currentDeal == null || isClosed) return;

    try {
      LogService.log(
        're-checking availability for deal ${currentDeal.id}',
      );

      final fresh = await dealRepo.fetchById(currentDeal.id);

      if (!isClosed) {
        _quantityLeft.value = fresh.quantityLeft;
      }
    } catch (e) {
      LogService.error('re-check availability failed', e);
    }
  }

  void addToCart() {
    final currentDeal = deal.value;
    if (currentDeal == null || isClosed) return;

    cartService.add(currentDeal);

    Get.snackbar(
      'Added to bag',
      '${currentDeal.name} — pick up ${currentDeal.pickupWindow.label}',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
  }

  @override
  void onClose() {
    _cartWorker?.dispose();
    super.onClose();
  }
}