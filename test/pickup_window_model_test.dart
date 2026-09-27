import 'package:flutter_test/flutter_test.dart';
import 'package:rescu/model/pickup_window_model.dart';

PickupWindowModel window(String start, String end) =>
    PickupWindowModel.fromJson({'start': start, 'end': end});

void main() {
  group('Bangkok pickup labels', () {
    test('morning bakery uses market time across the UTC date boundary', () {
      final pickup = window(
        '2026-01-31T23:00:00Z',
        '2026-02-01T02:30:00Z',
      );

      expect(pickup.label, '06:00 – 09:30');
      expect(pickup.start, DateTime.utc(2026, 1, 31, 23));
      expect(pickup.end, DateTime.utc(2026, 2, 1, 2, 30));
      expect(pickup.start.isUtc, isTrue);
      expect(pickup.end.isUtc, isTrue);
      expect(pickup.end.difference(pickup.start),
          const Duration(hours: 3, minutes: 30));
    });

    test('overnight window wraps the displayed end time', () {
      final pickup = window(
        '2026-12-31T15:00:00Z',
        '2026-12-31T18:00:00Z',
      );

      expect(pickup.label, '22:00 – 01:00');
      expect(pickup.end.difference(pickup.start), const Duration(hours: 3));
    });

    test('formatting is independent of the DateTime representation', () {
      final pickup = PickupWindowModel(
        start: DateTime.utc(2026, 2, 1, 10, 30).toLocal(),
        end: DateTime.utc(2026, 2, 1, 14).toLocal(),
      );

      expect(pickup.label, '17:30 – 21:00');
    });
  });

  group('Pickup today uses the full Bangkok start date', () {
    final cases = [
      (
        name: 'morning pickup starts on the previous UTC day',
        start: '2026-01-31T23:00:00Z',
        now: '2026-02-01T01:00:00Z',
        expected: true,
      ),
      (
        name: 'Bangkok is already tomorrow while UTC is still yesterday',
        start: '2026-02-01T10:00:00Z',
        now: '2026-01-31T18:00:00Z',
        expected: true,
      ),
      (
        name: 'same UTC day can mean pickup is tomorrow in Bangkok',
        start: '2026-02-01T23:00:00Z',
        now: '2026-02-01T12:00:00Z',
        expected: false,
      ),
      (
        name: 'last instant before Bangkok midnight remains today',
        start: '2026-02-01T10:00:00Z',
        now: '2026-02-01T16:59:59.999999Z',
        expected: true,
      ),
      (
        name: 'exact Bangkok midnight starts a new day',
        start: '2026-02-01T10:00:00Z',
        now: '2026-02-01T17:00:00Z',
        expected: false,
      ),
      (
        name: 'same day number in another month is not today',
        start: '2026-02-01T03:00:00Z',
        now: '2026-03-01T03:00:00Z',
        expected: false,
      ),
      (
        name: 'same month and day in another year is not today',
        start: '2025-02-01T03:00:00Z',
        now: '2026-02-01T03:00:00Z',
        expected: false,
      ),
      (
        name: 'morning pickup at the year boundary',
        start: '2025-12-31T23:00:00Z',
        now: '2026-01-01T01:00:00Z',
        expected: true,
      ),
      (
        name: 'leap day pickup',
        start: '2024-02-28T23:00:00Z',
        now: '2024-02-29T01:00:00Z',
        expected: true,
      ),
      (
        name: 'overnight window belongs to its start date',
        start: '2026-02-01T15:00:00Z',
        now: '2026-02-01T17:30:00Z',
        expected: false,
      ),
    ];

    for (final example in cases) {
      test(example.name, () {
        final start = DateTime.parse(example.start);
        final pickup = PickupWindowModel(
          start: start,
          end: start.add(const Duration(hours: 3)),
        );
        final now = DateTime.parse(example.now);

        expect(pickup.isTodayAt(now), example.expected);
        expect(pickup.isTodayAt(now.toLocal()), example.expected);
      });
    }
  });
}
