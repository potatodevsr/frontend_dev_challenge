# Solutions

## F-1 — Live flash-sale countdowns

### Implementation and decisions

The starter rendered static badges and allowed flash deals to stay in the bag
after their deadline. `FlashSaleClock` now provides one session-wide one-second
timer. Countdown text derives its remaining duration from the absolute
`flashSaleEndsAt` instant and current wall time, rather than decrementing a
counter. This also works across UTC/local representations of the same instant.

The flash rail, home/search cards, and details screen share
`FlashSaleCountdown`. Only its text rebuilds when the displayed second changes.
`FlashSaleAvailability` separately observes whether the deadline has passed;
its card/button builder runs again only when that boolean changes (or its
parent updates). Expired cards are dimmed and cannot be opened; the details
button becomes disabled and reads **Expired**. A synchronous deadline check
also guards card taps that arrive between timer callbacks.

`CartService` owns expiry enforcement, independent of mounted screens. It
removes all quantities of expired lines, updates totals/counts, and gives one
visible snackbar listing the removed deals. Direct adds and quantity increases
check the current time, so stale buttons cannot add expired deals. `add` now
reports success; details show **Added to bag** only after a successful add.
The existing quantity limit is preserved, and zero-stock deals are rejected.

Checkout prunes expired deals before submitting. If pruning changes the bag,
it stops so the user can review the new total and press checkout again. A
request already submitted before expiry is allowed to finish: the simulated
backend has no cancellation contract, so the client cannot retract an accepted
order. Expiry still removes its bag line while the request is in flight.

When the app is backgrounded, the shared timer pauses. On resume it publishes
the current time immediately, updating countdowns and cleaning the bag. Widget
listeners are removed on disposal and the service cancels its timer on close.

Rejected alternatives:

- One timer per card: unnecessary scheduling/lifecycle work with 100+ cards.
- An `Obx` around the whole list observing the current second: this would
  rebuild cards and the list every second, violating the requirement.
- Disable only the details button: the bag's quantity-increase path and
  between-tick taps could still add expired deals.

### Edge cases and boundaries

- At the deadline or later, display **Expired**; no negative countdowns.
- Positive fractional seconds round up, so an active deal does not show 00:00.
- Durations of an hour or longer use hh:mm:ss; shorter durations use mm:ss.
- Already-expired data, refreshed deadlines on reused widgets, non-flash
  deals, multiple lines expiring together, and returning from background are
  covered in automated tests.
- No changes to the fake backend, seed data, dependencies, or toolchain.
- The device clock is trusted; server clock synchronization is outside F-1.
- The pre-existing RES-105 scroll-wide rebuild and image-size issues remain.
  F-1 adds no per-second parent rebuild, but this is not a claim that RES-105
  is fixed or that frame timing on a real device has been measured.

### Verification

`test/flash_sale_test.dart` uses an injected clock to exercise formatting,
exact expiry, stale actions, background/resume, bag removal and its visible
notice, checkout gating, and controller feedback.

The 120-countdown widget test records:

| Observation | Initial | After five one-second ticks | At expiry |
| --- | ---: | ---: | ---: |
| List builder executions | 1 | 1 | 1 |
| Card-shell builder executions (total) | 120 | 120 | 240 |
| Countdown widgets displaying the expected text | 120 | 120 | 120 |

The expiry column includes the single required disabled-state transition for
each card. A later tick causes no additional card-shell rebuild. This harness
proves rebuild isolation; it is **not** an FPS, image-memory, or DevTools
benchmark of the actual feed.

Targeted static analysis of changed implementation files passed. Full-project
analysis found pre-existing annotation diagnostics in
`lib/feature/order/widget/pickup_countdown.dart`.

Final validation on 2026-09-28: `flutter test --reporter expanded` passed all
19 tests (9 for F-1), and targeted `dart analyze` passed for all changed Dart
files. The iPhone 17 Pro / iOS 26.5 simulator debug build launched successfully;
a simulator screenshot showed matching live times on the same deal in the
flash rail and home feed. This is a functional smoke check, not a profile run.

The full test run initially exposed a stale assertion in `model_test.dart`
that expected a UTC pickup value, predating RES-106's local conversion. That
test now checks local representation and preservation of the original UTC
instant. No RES-106 production code was changed for F-1.

Real-device profile-mode DevTools frame/memory capture with 100+ countdowns
remains outstanding. To reproduce: keep the same device/data before and after,
record idle ticks and scrolling separately, enable widget-build tracking, and
confirm that only countdown text builds each second. Record actual timings
and memory rather than extrapolating them from these widget tests.

## AI usage log for this work

Codex inspected the repository, implemented F-1, wrote and ran tests, checked
static analysis, and documented the limits of the evidence. The user worked
through earlier tickets interactively; this document does not invent timings
or test outcomes for those earlier changes.

Two concrete incorrect AI assumptions caught during F-1 testing:

1. The initial tests created the periodic clock in ordinary `setUp`, outside
   the widget test's fake-time zone. Advancing a widget test did not advance
   that timer, so countdown and bag-expiry assertions failed. Service startup
   was moved into the mounted widget-test setup inside that zone.
2. The initial cleanup assumed `Get.reset()` would call service `onClose`.
   Pending-timer failures and inspection of the installed GetX implementation
   showed that reset only clears registrations. Tests now invoke the service
   lifecycle deletion callbacks explicitly after unmounting widgets.

## Design questions

**Q1.** A `GetxController` follows GetX dependency/route ownership; widget
`State` follows mounting and disposal of that widget. They need not disappear
at the same time. RES-102's widget-owned pickup timer must stop when its State
is disposed; relying on a controller's lifecycle is insufficient. Likewise,
F-1's bag expiry belongs to a session service, not a card's State.

**Q2.** An `Obx` around a large subtree makes every observable it reads a
reason to rebuild that entire builder. Scope subscriptions to what changes:
countdown text every second, disabled controls at expiry, and the list only
when list data changes. A fast-changing timestamp must not become a dependency
of the entire home screen.

**Q3.** Test RES-106 using fixed UTC inputs that cross midnight in Bangkok,
plus equal day numbers in different months/years. Inject the reference `now`
and make timezone conversion explicit (or run tests under a known timezone)
so the machine's clock/zone cannot make them nondeterministic. Assert both the
display label and the today filter. Verify conversion preserves the instant.

## Time and next steps

F-1 assisted implementation and verification took approximately 15 minutes on
2026-09-28. Earlier user work was not timed here.

With another day: capture real-device DevTools evidence, address RES-105's
independent scroll/image issues, and exercise lifecycle/background scenarios
on physical Android and iOS devices. F-2 and F-3 are not implemented here.
