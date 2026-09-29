# Solutions

This write-up covers the changes present in this branch. Earlier Part A
explanations are reconstructed from the starter-to-current diff and commit
history; alternatives below are assessed against the current implementation.
Historical test/device observations are identified separately from the latest
F-3 validation. A passing suite does not establish coverage for every ticket.

| Ticket | Current status |
| --- | --- |
| RES-101 | Request generation and debounce lifecycle fixed; seven regression tests |
| RES-102 | Timer cancellation implemented; dedicated regression test missing |
| RES-103 | Worker disposal implemented; dedicated regression test missing |
| RES-104 | Request ownership fixed; nine controller regression tests |
| RES-105 | Scroll/image fixes and diagnostic before/after evidence; real-device profile still outstanding |
| RES-106 | Device-local conversion and full-date comparison implemented; deterministic timezone/filter coverage incomplete |
| RES-107 | Argument-free deal loading implemented; dedicated deep-link regression test missing |
| F-1 | Implemented and tested; real-device performance profiling outstanding |
| F-2 | Implemented and tested; real-device performance profiling outstanding |
| F-3 | Implemented with 18 reservation tests |

## RES-101 — Search results for the wrong query

**Root cause.** `_search` accepted every asynchronous response unconditionally.
The backend deliberately makes shorter, broader queries slower, so an older
request could finish last and overwrite the latest results. The original
500 ms debounce reduced requests but did not establish response ownership.
Loading state could also be cleared by an obsolete request.

**Why this fix.** Every input change immediately advances a generation number,
cancels the previous debounce timer, and clears results for the old query.
Only the current generation may publish results/errors or clear loading state.
Nonempty input shows loading during the existing 500 ms debounce; empty or
whitespace input returns to the initial state immediately. `onClose` cancels
the timer and invalidates outstanding work. No API cancellation is required.
Increasing the debounce delay was rejected: it makes the race less frequent
but never prevents it. Comparing only query strings was also rejected because
an A→B→A edit must not revive the first A request.

**Edges and verification.** Before the fix, the controlled late-response test
failed with deal `[1]` replacing expected deal `[2]`. All seven tests in
`test/search_controller_test.dart` pass after the fix: reversed completion,
invalidation before the next debounce fires, clearing input, rapid typing and
trimming, stale failure versus current loading, repeated query values, and
closing with both a debounce and request pending. Current request failures keep
the existing empty-results behavior and are logged; a dedicated search-error
UI and transport cancellation remain outside this ticket.

## RES-102 — Crash after leaving My orders

**Root cause.** `PickupCountdown.State.initState` created a periodic timer
without retaining or cancelling it. Its closure kept calling `setState` after
the widget was disposed. The orders controller did not own that timer, so
controller cleanup could not end the widget's callback lifetime.

**Why this fix.** Retain the `Timer` in the State and cancel it in `dispose`
before calling `super.dispose()`. Resource lifetime now matches the widget
that uses it. Checking `mounted` in each callback alone is rejected: it might
avoid the exception but leaves the timer and captured State alive. Moving all
pickup timers to a controller is unnecessary for this local ownership fix.

**Edges and limits.** Each countdown cancels its own timer, including removal
of one order while the screen remains open. Remaining time is calculated from
the timestamp, so rebuilding with a different pickup time reads the new value.
A dedicated mount/unmount-and-advance-time regression test is still missing.
The current file also retains a misplaced `@override` above `_timer` instead
of `initState`, reported by the earlier full-project analysis; the functional
cancellation fix is not a claim that this file is lint-clean. Consolidating
pickup timers and pausing them in the background were not part of this fix.

## RES-103 — Availability requests accumulate after browsing

**Root cause.** `ever(cartService.itemCount, ...)` subscribed each details
controller to the session-long cart observable, but its returned `Worker` was
ignored. Closing the route did not dispose that subscription, leaving old
controllers reacting to later bag changes and fetching previously viewed deals.

**Why this fix.** Retain `_cartWorker` and dispose it in `onClose`. The current
loading flow registers it only after a deal is available and uses `??=` to
avoid duplicate registration. `isClosed` checks prevent results arriving after
closure from updating availability. Merely debouncing the requests is rejected
because it leaves the leaked listeners alive; removing live availability checks
entirely would discard intended behavior on the active screen.

**Edges and limits.** Failure and retry during initial load must not create
multiple workers; closing during a fetch must not publish a late result. The
fix ends subscriptions but cannot cancel an already-sent request through this
API. Multiple availability fetches from the same still-open controller are not
serialized or ordered; resolving that separate race is deferred. No dedicated
worker-lifecycle regression test is currently present.

## RES-104 — Duplicate deals after refresh races pagination

**Root cause.** `loadMore` incremented `_page` before its request succeeded.
Refresh reset `_page` to 1 without invalidating the pending page. When refresh
completed first, the old page appended to the new feed while `_page` remained
1, causing the next load to request page 2 again. The historical write-up in
commit `3823b87` records a controlled reproduction of 142 cards for 122 unique
deals, with IDs 21–40 repeated; that write-up was subsequently deferred.

**Why this fix.** Each refresh advances `_epoch`. Feed requests check their
captured epoch before applying data, handling errors, or clearing flags.
Pagination is blocked during refresh and while another current page is loading.
Only a successful current response commits its page number, and refresh resets
the exhausted footer. Controller closure invalidates pending feed requests.
Deduplicating IDs is rejected as the fix: it hides the repeated cards while
leaving page progression, retry behavior, and request ownership incorrect.

**Edges and verification.** `test/home_controller_test.dart` covers both race
completion orders through the catalog, duplicate pagination calls, stale
success/failure during a newer load, overlapping refreshes, retries of the same
page, failed refresh preserving committed data, and footer reset after
exhaustion. These nine tests passed in the latest 60-test run. Already-sent
requests finish but obsolete outcomes are ignored; transport cancellation and
an automated physical-device pull gesture are outside this change.

## RES-105 — Home scrolling and image memory

**Root causes.** `HomeController._onScroll` published every offset to the
observable read by the outer `HomeScreen` `Obx`, rebuilding the Scaffold/feed
although only elevation and the jump-to-top button needed threshold changes.
A regression test against that code measured four builds of the same visible
card for four small scroll changes. The feed also constructed every card widget
with a spread into `ListView(children: ...)` whenever that builder ran (this
does not mean Flutter mounted every offscreen element). `TheNetworkImage`
decoded the 1600×1200 source image without a display-size hint, even for smaller
rail cards and thumbnails. A native simulator capture measured 46,080,000 bytes
for six decoded cache entries at the top of Home.

**Why this fix.** Publish only `hasScrolled` and `showScrollToTop` threshold
booleans and observe them in the app bar and button. The feed observes data and
filter changes independently, using a `SliverChildBuilderDelegate` to construct
cards lazily. Deal-ID keys and index lookup preserve card state across filter
changes. `TheNetworkImage` derives `memCacheWidth` from finite layout width and
device pixel ratio, keeping aspect ratio and leaving the original disk image
available to larger views. Unbounded widths fall back to the original decode.
There are no cache-limit increases, dependency upgrades, or backend edits.

Increasing the global image cache or clearing it on every scroll was rejected:
the former retains more decoded memory; the latter causes repeated decode work.
Debouncing raw scroll offsets was also rejected because the two controls need
immediate threshold transitions, not delayed whole-feed rebuilds. A finite
layout width is required before converting logical pixels to decode pixels;
blindly multiplying `double.infinity` would fail on full-width cards.

**Verification and limits.** The same four-jump widget test now records zero
builds of the still-visible card, while elevation and jump-to-top visibility
still change at the original thresholds. A second widget test verifies a
200-logical-pixel image at DPR 2 requests a 400-pixel decode. Existing pagination,
flash-sale and impression tests still pass. Native captures loaded the original
122-deal catalog on the same iPhone simulator, using `tool/profile_app.dart`
and `tool/capture_home_profile.py` to collect the service data used by DevTools.
Top-of-feed decoded cache storage changed from **46,080,000 bytes / 6 entries**
to **15,063,552 bytes / 7 entries**; resized rail/feed copies use distinct keys.
The post-scroll snapshots were **99,840,000 bytes / 13 entries** before and
**77,862,912 bytes / 24 entries** after. These are observed cache snapshots, not
an overall-memory reduction claim: the isolate heap did not decrease.

[Evidence, raw captures, and reproduction steps](docs/evidence/README.md) include
a connected DevTools screenshot. Its debug-mode frame times are not valid
release-performance measurements. The timeline ring buffer retained unequal
tails, so absolute native build totals are not compared. Physical-device
profile-mode frame/memory comparisons, repeated cold/warm-cache trials, large
screens, and unusual image aspect ratios remain to be evaluated. The old image
cache was already bounded; this does not prove an unbounded leak was fixed.

## RES-106 — Incorrect pickup labels and the today filter

**Root cause.** ISO strings ending in `Z` parse as UTC instants. Formatting
those values directly showed UTC clock hours (23:00–02:30) instead of the
Bangkok device's local hours (06:00–09:30). `isToday` also compared only the
day-of-month of the parsed start with local `DateTime.now()`, mixing timezones
and allowing dates from other months/years with the same day number to match.

**Why this fix.** `PickupWindowModel.fromJson` converts both instants with
`toLocal()`, preserving the point in time while giving labels and date checks
the same device-local representation. `isToday` compares year, month, and day.
Changing the backend timestamps or stripping `Z` is rejected: the API instants
are correct and changing their interpretation corrupts ordering/durations.
A fixed Bangkok-date implementation appears in history but was reverted; the
current code follows the device timezone. This is a product boundary, not a
claim that all travelers will see store-local time.

**Edges and limits.** UTC/local midnight crossings and equal day numbers in
different months/years matter. `test/model_test.dart` checks local representation
and preservation of the UTC instant; it does not yet prove Bangkok labels or
the today filter against a controlled clock. “Today” currently means the start
date, so an overnight window that began yesterday is excluded even if open
now. Store-timezone display for users outside Thailand and overnight overlap
semantics are deferred. Q3 below describes the missing regression coverage.

## RES-107 — Deep link crashes without a navigation argument

**Root cause.** `DealDetailsController.onInit` cast `Get.arguments` directly
to `DealModel`. Internal card navigation supplied that object, but a deep link
contains an ID in the URL and no in-memory model, so casting null crashed
before the controller could load the deal.

**Why this fix.** Capture and validate the route ID, accept a model argument
only if its ID matches, and otherwise fetch through `DealRepo.fetchById`.
The screen observes loading, loaded, and error state; a valid link proceeds to
the normal interactive details view with stock, analytics, and add-to-bag.
Showing only a null-argument error/fallback is rejected because deal 42 exists
and the requirement is a working page. Always fetching is also unnecessary
when a matching model was already supplied by an internal card.

**Edges and limits.** Missing/non-numeric IDs, missing deals, transient fetch
errors, mismatched arguments, retry, and leaving before completion are handled
by validation, error state, and `isClosed` guards. Route parameters are captured
before the await so later navigation cannot change the in-flight request's
context. A follow-up simulator smoke check opened
`rescu://open/deal?id=42&source=push` without a model argument: logs show
`GET /deals/42` and a details-view event with source `push`, and
[the screenshot](docs/evidence/deep-link-42.png) shows the loaded deal and active
Add to bag button. This was a warm-app iOS simulator check; dedicated automated
route/controller tests and physical-device cold-start coverage remain missing.

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
order. F-3 supersedes the in-flight cleanup policy: submitted lines stay locked until
the server responds, so the client never releases holds used by that request.

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
- F-1 itself adds no per-second parent rebuild. The later RES-105 follow-up
  addresses scroll-wide rebuilds and decode size separately; real-device frame
  timing remains unmeasured.

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

The missing behavior was visibility-qualified impression recording and batched
delivery: having a card built does not establish that a user saw it. The
implementation separates visibility/dwell ownership from session deduplication
and network delivery.

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
test is not an FPS claim. The later RES-105 section records the separate
scroll/image changes and their diagnostic evidence.

## F-3 — Stock reservations with optimistic UI

### Implementation and decisions

The original bag only mutated local quantities; adding a line never invoked
the available reservation API. A visible bag entry therefore did not mean stock
was held, and checkout could submit a null reservation ID.

`CartService` now owns the complete hold lifecycle through the existing
`OrderRepo.reserve` and `releaseReservation` methods. Adding or changing a
quantity updates the bag, badge, and total immediately. A pending line reads
**Holding your items…**; checkout stays disabled until every current quantity
has a confirmed hold. On success, each line shows the time remaining using the
server's absolute `expiresAt` timestamp and the existing shared clock/countdown.
There is no extra timer per line or whole-list rebuild on each second.

A reservation failure removes the affected line and recalculates the total,
with **Could not hold this item** and a plain-language explanation naming it.
This includes a failed quantity replacement: the old hold is no longer valid,
so retaining the previous quantity would misrepresent held stock.

The API has no adjustment endpoint. Quantity changes therefore release the
previous hold **before** reserving the desired total quantity. This avoids
requesting a second full hold against our own already-held stock, but there is
a gap in which another buyer may take it. A successful replacement gets a fresh
five-minute deadline. Each line serializes its requests and reconciles rapid
edits to the latest desired quantity. A superseded successful response is
released before replacement; a response for a removed line is released and
cannot resurrect that line or overwrite a later re-add. Decrementing to zero,
removing, clearing, and flash-sale expiry all release their holds. A failed
release is handled visibly; replacement stops, and the server's five-minute
expiry remains the fallback. No backend changes were made.

Rejected alternatives:

- Waiting for the reservation response before updating the bag: loses the
  required instant feedback; pending state plus rollback makes the uncertainty
  visible while keeping the interaction responsive.
- Reserving the new full quantity before releasing the old hold: can compete
  against our own held stock. The API offers no atomic adjustment, so the
  documented release/re-reserve gap is preferable to overlapping full holds.
- Renewing expired holds or retrying checkout automatically: can monopolize
  stock or place an order without a fresh review. Expiry requires user action.

### Expiry policy and checkout

At the reservation deadline, remove the expired line, update the total/badge,
and tell the user to add it again to check availability. Do this throughout
the app, including immediately after returning from the background. Do not
automatically renew: that would let an idle bag monopolize scarce stock and
silently extend a promise made for only five minutes. Users explicitly add
items again if they still want them.

Checkout checks wall time synchronously, so a tap between clock ticks cannot
submit an expired hold. If this check changes the bag, checkout stops to let
the user review the new total. It snapshots confirmed quantities and
reservation IDs and locks all bag mutation paths for the submitted request;
the lock belongs to the session service and survives leaving the bag screen.

While checkout is in flight, countdowns continue, but pruning and release wait
for the response. An already-submitted request cannot be cancelled through this
API. A success is authoritative even if the local clock has crossed expiry.
A `410` means the order was not placed: clear/release the submitted holds and
ask the user to add items again. Since the API does not identify the rejected
line (and also uses `410` for unknown IDs), invalidate the whole submitted set,
including holds that appear unexpired locally. This sacrifices some convenience
but prevents repeatedly submitting an invalid hold. There is no automatic
checkout retry or automatic purchase of only the remaining lines.

Other checkout errors retain still-valid holds, unlock controls in `finally`,
and prune anything that expired while waiting. Unexpected transport errors
ask users to check their orders before trying again because the response may
have been lost after acceptance. The API provides no checkout idempotency key.

### Verification and limits

`test/reservation_test.dart` exercises immediate feedback, pending checkout
gating, countdown updates, contention/network rollback, rapid quantity edits,
release-before-replace ordering, decrement-to-zero, failed replacement,
remove/re-add with out-of-order replies, clearing pending holds, exact and
background expiry, between-tick checkout validation, submitted reservation IDs,
locked controls, duplicate-submit prevention, mid-checkout expiry, server-only
`410`, success after local expiry, other checkout errors, and release failure.
The controllable API test double supplies delayed responses and fixed deadlines;
the existing flash-sale tests also use it to preserve deterministic F-1 coverage.

Validation on 2026-09-29: `flutter test --reporter expanded` passed all
**51 tests**, including **18 new F-3 tests**. Targeted `dart analyze` passed
for every changed/new Dart file, and `git diff --check` passed.

Reservations remain in memory for this app session; server expiry handles an
abrupt process exit. The device clock is trusted for display and proactive
cleanup, while checkout rejection remains server-authoritative. The supplied
fake backend does not deduct active holds from its availability calculation;
client tests prove correct reservation API usage and reconciliation, not real
multi-client backend stock isolation. Physical-device validation is not claimed.

## AI usage log

Codex was used to inspect the repository, implement F-1/F-2/F-3, generate and
revise regression tests, interpret failures, and draft the write-up. Part A
was developed interactively earlier; this review reconstructs its technical
status from code/history rather than inventing a full record of those sessions.
No other AI assistant is claimed without a record of its use.

| Tool | Use and evidence |
| --- | --- |
| Codex with terminal commands | Read API contracts and lifecycle ownership; implement features and tests; review the final changes |
| `rg`, file reads, `git log/show/diff` | Locate callers, compare starter/current code, recover RES-104 diagnosis, and identify incomplete tickets |
| Python file-edit scripts and `dart format` | Apply source/document edits and format changed Dart files |
| `flutter test` | Controlled async, fake-time, widget, and controller checks; latest implementation run passed 60 tests |
| `dart analyze`, `git diff --check` | Targeted static analysis and whitespace checks; targeted success is not full-project lint success |
| iOS simulator, Browser skill, DevTools, Python VM-service capture | Earlier F-1/F-2 checks plus RES-105 native cache/timeline snapshots and a DevTools Performance screenshot; no real-device profiling claim |

Concrete incorrect AI suggestions and how they were corrected:

1. **F-1 timer setup.** AI-generated tests started the periodic clock in ordinary
   `setUp`, outside the widget test's fake-time zone. Advancing test time did
   not advance that timer, so countdown/expiry assertions failed. Service
   startup moved into the mounted widget-test setup inside the fake-time zone.
2. **F-1 lifecycle cleanup.** AI assumed `Get.reset()` would call service
   `onClose`. Pending-timer failures and inspection of the installed GetX
   implementation showed it only cleared registrations. Tests explicitly call
   service lifecycle deletion callbacks after unmounting widgets instead.
3. **F-3 cleanup timing.** AI initially put asynchronous widget-test cleanup in
   `addTearDown`. Flutter checked for pending timers before that cleanup ran,
   producing “A Timer is still pending” and overlay ticker failures. Cleanup
   moved into a `try/finally` around each test body, inside the widget test.
4. **F-3 waiting for idle.** AI used `pumpAndSettle` during cleanup of the actual
   bag screen. The network-image shimmer kept scheduling frames, so it timed
   out; queued snackbars also complicated early dismissal. Tests now advance
   bounded fake time to let notices finish, unmount the tree, and explicitly
   close the services. Waiting for the whole app to become idle was the wrong
   cleanup condition for an intentionally animated placeholder.
5. **RES-105 build-counter test.** The first draft counted only callbacks with
   `builtOnce == true`, so the test incorrectly passed on the old code. Reading
   Flutter 3.27's `Element.rebuild` showed that flag is updated only when
   `debugPrintRebuildDirtyWidgets` is enabled. The corrected test counts all
   callbacks for the target card and resets after initial mounting. It then
   failed on the old code with four builds and passed after the fix with zero.

## Design questions

**Q1.** A `GetxController` is initialized and closed according to GetX dependency
and route ownership (`onInit`/`onClose`); a widget `State` is initialized when
mounted and disposed when removed from the tree (`initState`/`dispose`). Their
lifetimes need not coincide: a controller can outlive a widget, and covering a
route need not dispose either. In RES-102 the pickup timer was created by the
widget State but survived that State, then called `setState` after disposal.
Its owner must cancel it in `dispose`; controller cleanup is not a substitute.
Conversely, RES-103's subscription belongs to the details controller and must
be disposed in `onClose`, while bag holds belong to a session service.

**Q2.** A large `Obx` is costly when a frequently changing observable read by
its builder invalidates a subtree whose other content did not change. Before
RES-105, `HomeScreen` did this: every `scrollOffset` update rebuilt the
Scaffold/feed although only elevation and the jump-to-top button depended on
scroll thresholds.
Scope each subscription to the smallest useful UI unit with a shared update
reason: timer text per second, availability controls at expiry, and the list
when its data changes. Keep static children outside that builder and prefer a
threshold boolean when the UI does not need the raw offset; verify build counts
and profile frames rather than assuming more `Obx` widgets always help.

**Q3.** Run a deterministic test under `TZ=Asia/Bangkok` with API start
`2026-09-28T23:00:00Z`, end `2026-09-29T02:30:00Z`, and reference now
`2026-09-29T01:00:00Z`: assert label `06:00 – 09:30`, unchanged UTC instants,
and inclusion in the actual “Pickup today” filter. Add previous/next-day cases,
exact local midnight, and dates with the same day number in other months/years
to expose the original day-only comparison. Introduce an `isTodayAt(now)`
method with a production getter delegating to it, and inject the home filter's
clock so both model and controller tests use the same fixed instant. Run the
process with an explicit timezone, or inject a timezone conversion policy if
store-local time becomes the requirement. These are proposed additions; the
current model test verifies instant preservation but not this full scenario.

Latest follow-up verification on 2026-09-29: all **60 tests** passed (seven
new RES-101 tests and two RES-105 tests in addition to the earlier 51).
Targeted `dart analyze` passed for all changed/new Dart files, including the
profiling entry point. `git diff --check` passed.

## Time spent and next steps

| Work | Rough time and source |
| --- | --- |
| RES-104 diagnosis, implementation, and verification | About 15 minutes, recovered from the historical write-up in commit `3823b87`; excludes later revisions |
| F-1 implementation and verification | About 15 minutes on 2026-09-28, recorded in the existing write-up |
| F-2 implementation and verification | About 10 minutes on 2026-09-28, recorded in the existing write-up, including simulator/debug-screen inspection |
| RES-101/RES-105 follow-up | Roughly 20–25 minutes on 2026-09-29, including simulator startup, diagnostic captures, tests, and documentation |
| Other Part A work, F-3, and earlier documentation review | Not reliably timed; no duration inferred from gaps between commits |

The recorded subtotal is approximately **60–65 minutes**, not a total for the
assessment or all human review time. Unrecorded work is additional; exact
per-ticket times should not be inferred from commit timestamps.

With one more day, add lifecycle, deep-link, and deterministic pickup-date
regressions for the earlier tickets. Extend the RES-105 diagnostic captures to
a physical device in profile mode for scrolling frames and image memory; repeat
F-1/F-2 profiling to check the features under load. Use remaining time for physical Android/iOS background/resume, cold-start links,
and reservation expiry near checkout, and resolve the documented annotation
diagnostics before claiming a clean full-project analysis.
