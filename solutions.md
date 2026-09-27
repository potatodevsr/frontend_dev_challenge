# RES-104 — Duplicate deals in the home feed

## Diagnosis

`loadMore()` advanced `_page` before its request completed. A concurrent refresh
reset `_page` to 1 without invalidating that request. If refresh completed first,
the old page appended to the fresh feed while `_page` remained 1. The next load
requested page 2 again. With the bundled catalog, controlled completion order
reproduced 142 cards for 122 unique deals; IDs 21–40 appeared twice. Completing
the old load before refresh instead produced 122 cards.

## Fix

Each refresh increments an epoch. Refresh and pagination requests capture that
epoch and check it before accepting results, handling errors, or clearing loading
flags. Pagination is blocked during refresh. The page counter changes only when
a current request succeeds, so failures preserve the displayed feed and the page
needed for a retry. Refresh also resets the pagination footer. Closing the
controller invalidates pending feed requests.

Deduplicating IDs alone was rejected because it would hide the duplicate cards
while leaving the page counter and request ownership incorrect. Requests already
sent still finish; the client ignores obsolete outcomes. The backend and seed
data are unchanged.

## Verification

The regression test failed before the controller change when refresh completed
first. Tests cover both completion orders through the end of the catalog,
overlapping refreshes, blocked/repeated pagination, stale success and failure
while a newer page is loading, refresh and pagination retries, and refreshing an
exhausted feed. Tests use controlled futures rather than timing-dependent sleeps.
This is controller-level verification; the physical-device gesture was not
automated.

Commands: `flutter test --no-pub --reporter expanded` and
`dart analyze lib/feature/home/home_controller.dart test/home_controller_test.dart`.
All 10 tests passed (nine new controller tests and the existing model test);
analysis reported no issues.

## Process

Approximately 15 minutes for diagnosis, implementation, and verification. Codex
traced the request race, implemented the controller change using the existing
in-progress `_epoch` field, and added tests. One test-harness assumption was
incorrect: pumping without scheduling a frame did not execute the refresh
library's post-frame footer callbacks. Explicitly scheduling a frame corrected
the footer assertions. Remaining assessment tickets and deliverables are outside
this change.
