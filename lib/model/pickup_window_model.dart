import 'package:intl/intl.dart';

/// A store's pickup window. The API sends instants as ISO-8601 UTC strings.
class PickupWindowModel {
  // The catalog serves Bangkok (UTC+7), independently of the device timezone.
  static const _marketUtcOffset = Duration(hours: 7);

  final DateTime start;
  final DateTime end;

  const PickupWindowModel({required this.start, required this.end});

  factory PickupWindowModel.fromJson(Map<String, dynamic> json) {
    return PickupWindowModel(
      start: DateTime.parse(json['start'] as String? ?? ''),
      end: DateTime.parse(json['end'] as String? ?? ''),
    );
  }

  // Calendar/formatting values only; keep start/end as instants for arithmetic.
  static DateTime _marketTime(DateTime instant) =>
      instant.toUtc().add(_marketUtcOffset);

  /// Human readable Bangkok time, e.g. "17:30 – 21:00".
  String get label => '${DateFormat('HH:mm').format(_marketTime(start))} – '
      '${DateFormat('HH:mm').format(_marketTime(end))}';

  /// Whether pickup starts today in Bangkok.
  bool get isToday => isTodayAt(DateTime.now());

  /// Accepts an explicit current instant for deterministic date-boundary tests.
  bool isTodayAt(DateTime now) {
    final pickupDate = _marketTime(start);
    final today = _marketTime(now);
    return pickupDate.year == today.year &&
        pickupDate.month == today.month &&
        pickupDate.day == today.day;
  }

  /// Whether the store is currently accepting pickups.
  bool get isOpenNow {
    final now = DateTime.now();
    return now.isAfter(start) && now.isBefore(end);
  }

  Duration get untilStart => start.difference(DateTime.now());
}
