import 'deal_model.dart';
import 'reservation_model.dart';

class CartItemModel {
  final DealModel deal;
  int quantity;

  /// Confirmed stock hold; null while a new hold is being requested.
  ReservationModel? reservation;
  bool isReserving = false;

  CartItemModel({required this.deal, this.quantity = 1, this.reservation});

  num get lineTotal => deal.price * quantity;
}
