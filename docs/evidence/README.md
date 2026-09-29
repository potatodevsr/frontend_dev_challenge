# RES-105 diagnostic evidence — 2026-09-29

Same iPhone 17 Pro / iOS 26.5 simulator, Flutter 3.27.0 / Dart 3.6.0,
**debug mode**, original 122-deal fake backend catalog. The production entry
point does not include the profiling extension.

Run the capture entry point:

```sh
flutter run --debug --no-pub -t tool/profile_app.dart -d DEVICE_ID
python3 tool/capture_home_profile.py VM_SERVICE_URL docs/evidence/home-capture
```

Use the VM service URL printed by Flutter. Open its DevTools link to inspect the
same app. The capture script calls the Dart VM service used by DevTools, enables
widget-build timeline events, records a five-second idle interval, then performs
two four-second down/up scroll cycles. Each cycle uses the current estimated
maximum scroll extent. Both runs started at the top after loading all 122 deals.
Before and after were separated by a hot restart to reset the Dart image cache;
the on-disk image cache was left intact. Image requests were settled (zero
pending) at both snapshots. Network timing, viewport estimates, and emulator
load were not controlled, so this is diagnostic evidence, not a benchmark.

| Observation | Before | After |
| --- | ---: | ---: |
| Loaded deals | 122 | 122 |
| Decoded image cache at top, bytes | 46,080,000 | 15,063,552 |
| Cache entries at top | 6 | 7 |
| Decoded image cache after scripted scrolling, bytes | 99,840,000 | 77,862,912 |
| Cache entries after scripted scrolling | 13 | 24 |
| Live image listeners after returning to top | 6 | 7 |
| Isolate heap usage after scrolling, bytes | 100,776,592 | 105,112,512 |

The resized rail/feed copies can use separate cache keys, hence seven entries
instead of six at the top. This run shows smaller decoded image storage, **not**
a reduction in Dart heap or a demonstrated fix for every possible memory leak.
The original image cache was already bounded near its default 100 MiB limit;
we did not increase that limit or force cache eviction.

`home-before-summary.json` and `home-after-summary.json` contain the raw cache
and isolate-memory snapshots plus timeline event counts. `*-timeline.json.gz`
contain gzip-compressed VM timeline responses. The VM uses a ring buffer: only
2.838300 seconds of the before scroll and 6.382345 seconds of the after scroll
were retained. **Do not compare absolute event totals across these unequal
windows.** Both idle traces contain countdown/text updates and no Scaffold or
DealCard builds. The after scroll tail contains no Scaffold builds; the
controlled widget regression is the quantitative rebuild comparison below.

`test/home_performance_test.dart` separately uses the actual Home screen with
122 deals. Four jumps (10, 20, 30, 40 logical pixels) while the first card stays
visible caused four builds of that card before the fix and zero afterward.
It also checks the elevation/button thresholds and a 200-logical-pixel image
at DPR 2 requesting a 400-pixel decode width. This harness proves update scope
and requested decode size; it does not measure FPS or network throughput.

`devtools-after.png` shows the connected native app's Performance panel and its
explicit debug-mode warning. It is **not** release frame-time evidence. The
before/after Home screenshots are visual smoke checks. Real-device profile-mode
captures with the same scroll path and cache conditions remain outstanding.

`deep-link-42.png` is a separate warm-app smoke check after opening
`rescu://open/deal?id=42&source=push` on the same simulator. The API log recorded
`GET /deals/42`, and the loaded details page includes its Add to bag control.
This is not an automated external cold-start/deep-link test.
