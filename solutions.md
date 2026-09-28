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

## F-2 — Impression tracking

### Implementation and decisions

One shared `DealImpression` widget measures each card's content surface,
excluding its outside margin, using the installed `visibility_detector`.
It starts a one-second, one-shot dwell timer at 50% visibility or above.
A rendered dip below 50%, leaving/covering the route, backgrounding the app,
disposing the card, or reusing the element for another deal cancels the dwell.
Returning to visibility requires a new continuous second. Position is the
zero-based index in the currently displayed list, including search results
and the filtered home list.

The existing session-wide `AnalyticsService` owns the set of impressed deal
IDs. The first qualifying instance wins across `home_feed`, `flash_rail`, and
`search`, even when two copies qualify together. The debug history receives
one `deal_impression` with `deal_id`, `source`, and `position`; revisiting a
screen or retrying delivery does not add another impression. A fresh app
session creates a fresh set.

All analytics events, including the pre-existing screen/detail events, now use
the same delivery queue. `FakeApiService.sendAnalyticsBatch` receives batches
of up to 10, triggered by 10 queued events or 15 seconds from the first unsent
event. Later arrivals do not postpone that deadline. Requests are serialized;
new events stay queued while a request is in flight and are checked against
their original deadline when it finishes. Failure restores the original batch
ahead of newer events and retries after five seconds without re-recording it
in debug history. A backend acknowledgement/idempotency contract would be
needed for exactly-once network delivery after ambiguous transport failures;
the app guarantees once-per-session impression recording, not that stronger
server-side property. The queue is in memory and is not persisted across
process termination.

Visibility callbacks run at the end of each changed frame (`updateInterval =
Duration.zero`) so brief rendered dips below half a card are not hidden by the
package's default 500 ms coalescing interval. Callbacks manage timers rather
than rebuilding cards. After recording, that detector's callbacks are disabled;
the child widget retains its identity during this one wrapper update.

Rejected alternatives:

- Tracking in a card's `build`: build does not establish that it was visible,
  and would count rebuilds rather than a continuous viewing interval.
- A deduplication flag on each widget: it is lost on disposal and cannot dedupe
  the same deal across home, rail, and search.
- Resetting the 15-second timer on every arrival: steady traffic below the
  size threshold could postpone delivery indefinitely.
- Relying on geometry alone: covered routes and background time are not valid
  viewing time, so route/lifecycle callbacks cancel the dwell explicitly.

### Verification and limits

On 2026-09-28, all **33 tests** passed, including 14 new F-2 tests. These use real
clipping geometry for the 49%/50% boundary, a 16 ms interruption, route changes,
backgrounding, disposal, element reuse, and concurrent copies. Queue tests
cover the two flush triggers, in-flight arrivals, ordering, retries and shutdown.
The 120-visible-card test records 120 impressions, sends 12 batches of 10,
leaves child build counts at 120, and confirms that completed detectors stop
requesting visibility callbacks. Targeted static analysis passed.

The iPhone simulator's actual **Analytics debug** screen was inspected and
showed deal 1 at `flash_rail` position 0, deal 5 at `flash_rail` position 1, and
deal 2 at `home_feed` position 1. Deal 1 was not counted again in the home feed.
Runtime logs showed the first event at 23:15:33 and
`POST /analytics/batch events=4` at 23:15:48, including the existing screen event.

Route overlays conservatively interrupt dwell even when only part of a card
is covered. As documented by the visibility package, arbitrary sibling
occlusion and opacity are not pixel-perfect visibility measurements. The app's
normal clipped vertical/horizontal lists, route changes, and lifecycle are
handled. No real-device frame-time comparison has been performed; the rebuild
test is not an FPS claim, and the independent RES-105 work remains outstanding.

## AI usage log for this work

Codex inspected the repository, implemented F-1 and F-2, wrote and ran tests, checked
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
F-2 implementation and verification took approximately 10 minutes on the same
date, including the simulator/debug-screen check.

With another day: capture real-device DevTools evidence, address RES-105's
independent scroll/image issues, and exercise lifecycle/background scenarios
on physical Android and iOS devices. F-3 is not implemented here.
