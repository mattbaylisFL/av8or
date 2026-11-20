# av8or backlog

Findings noticed but deferred. Keep entries short; link the measurement that found them.

## Radar sweep performance (measured 2026-11-01 on av8or.local, Pi 4B, X11)

Fixed in the sweep-perf patch (icon sprite caches, altitude colour snap, secrets.json cache, ATC orphan scan cache):
the 300 to 580 ms sweep freezes. Fixed by the dedupe key memoisation (pipe_dedupe 55 ms to 4 ms per cycle) and by
upstream f6011bd, merged 2026-11-02: the O(n^2) dedupe fallback, the live icon frame (now cached per target and
refreshed within a 6 ms budget), the flip board (now on its own worker, one airport scan per track), the per-frame
_radar_flights() copy on cached-layer frames, trail point decimation, and oldest-entry eviction for the rotated,
rotor and glow caches.

Measured again on 2026.11.2.11 (2026-11-01 20:18 to 20:21 ET, about 15 targets): 27.3 fps, 62 hitches over 48 ms
per minute, p50 59 ms, 1.7 per minute over 99 ms, worst 218 ms. 4_present fell from 12.4 to 8.4 ms with upstream's
live frame cache; the hitch rate did not move. 73% of hitches happen with no grab in flight (hitch log proc=0).

Fixed 2026-11-01 (sweep_poll_sleep_s in app.py): the loop now sleeps only until the next sweep frame is due
instead of a fixed 4 ms. Same device, 3 minute windows: 27.3 to 29.6 fps, interval avg 37.0 to 34.1 ms, jank over
66 ms 14.2 to 6.7 per minute, over 99 ms 1.7 to 0, worst gap 218 to 92 ms. Hitches over 48 ms only 62 to 57 per
minute, p50 59 to 56 ms (about 9 targets in the after window).

Fixed 2026-11-02 (pill cache in radar_hud._draw_curved_white_pill, cached attribution text): the layer rebuild
re-rasterized the zoom pill (146 anti-aliased discs at 2x plus a smoothscale) every 3 s and the HUD overlay did
the same for its pills once a minute. Same device, 3 minute windows, about 11 targets: 2r_status 9.8 to 3.2 ms,
2r_bezel 7.9 to 4.9 ms (max 37.6 to 19.5), layer cost max 53 to 26 ms, draw avg 17.2 to 13.4 ms, jank over
66 ms 16.9 to 8.7 per minute, over 99 ms 2.4 to 0, worst gap 183 to 96 ms. Hitches over 48 ms 53.4 to 52.7 per
minute, p50 59 to 56 ms: the GIL floor below is untouched. Note: _draw_status itself was never the cost (it
returns in 0.03 ms when traffic is visible); the earlier "_visible_flights 12 ms" guess was the zoom pill.

Fixed 2026-11-02 (HUD overlay pre-rotated on the rebuild thread, HUD text through the text cache, update status
read once per check with a 2 s bubble cache): the render thread no longer rotates the 1080 px SRCALPHA HUD overlay
when the clock minute changes. Same device, 4 minute windows, 12 to 14 targets: 4p_overlays max 27.4 to 3.3 ms
(avg 2.5 to 1.4), layer cost max 47 to 31 ms, jank over 66 ms 17.0 to 13.9 per minute, over 99 ms 2.0 to 1.0.
Hitches over 48 ms 57.0 to 56.9 per minute: the GIL floor, unchanged.

Still open, in priority order:

- ROOT CAUSE FOUND 2026-11-02, step 1 shipped 2026-11-02 (utilities/run_as_user.py): the "GIL floor" is fork(). bluetooth_audio._run_as_audio_user passes
  user= to subprocess.run, and CPython then cannot use vfork, so every pactl / wpctl probe forks the 380 MB display
  process (page table copy, 15.6 ms avg, 20 ms max per strace, GIL held throughout, then copy-on-write faults on
  the next draw). audio_output's speaker watch (3 s, force=True), its 2 s cache and the 8 s Bluetooth reconnect
  watch add up to about 27 such forks a minute, one hitch each. Evidence: the sleep overrun fires on only 0.4% of
  loop iterations (about one per 2 s), is uncorrelated with the prewarm, flip-board and grab stages, and
  sys._current_frames() at overrun time shows subprocess._execute_child under bluetooth_audio in 48% of samples
  and 0% of baseline samples. A standalone benchmark on the Pi put the OS sleep floor at 0.1 ms and a pure Python
  worker at the 2 ms switch interval; full-size blits, fills and copies on a worker hold the GIL 4 to 10 ms, while
  transform.rotate, smoothscale and image.load release it.
  Trial (setpriv --reuid/--regid/--init-groups in front of the command instead of user=, so vfork is used), same
  device, 4 minute radar windows: hitches over 48 ms 48.5 to 8.6 per minute, jank over 66 ms 8.5 to 0.8, over
  99 ms 0.8 to 0.2, draw avg 14.0 to 11.7 ms, interval p95 57 to 41 ms, sleep overruns 112 to 2 per window.
  Step 1 DONE (setpriv wrapper with a user= fallback in bluetooth_audio and atc_audio's unmute, tests in
  tests/test_run_as_user.py). Clean-patch A/B on the Pi, 4 minute radar windows: hitches over 48 ms 64.5 to
  18.0 per minute, jank over 66 ms 16.8 to 7.8, draw avg 16.7 to 14.5 ms, interval p95 42 to 39 ms, sleep
  overruns over 5 ms seen in 69 of 120 windows to none, fps 29.4 to 29.8. Remaining hitches: p50 65 ms, 38%
  with a grab in flight, one 231 ms outlier per run.
  Steps 2 and 3 DONE 2026-11-02 (sysfs gates in bluetooth_audio, sysfs-keyed nmcli cache in wifi_setup,
  tests/test_probe_gates.py). A/B with the paired speaker switched off: child processes 135 to 34 per minute
  (bluetoothctl 90 to 24, nmcli 44 to 6), PIDs allocated 406 to 150 per minute, display CPU 90.2 to 89.1% of
  a core, frame timing within noise. Remaining bluetoothctl calls are the reconnect attempts (backed off to
  32 s). Not done: the 380 MB RSS item below, and a pactl subscribe event stream was judged not worth it.
  Original step 2 notes (probe cadence, measured on this Pi with audio_route=usb, no speaker): audio_output's speaker watch
  (3 s) ends in pactl list short sinks via is_output_ready() with no preferred MAC; the bluetooth_audio watch
  (8 s, usb branch) runs ensure_usb_pulse_sink -> find_usb_sink -> pactl, twice when no USB card exists. The
  flap clatter and chime hit the 2 s cache between polls. Proposed: gate is_output_ready/is_connected on
  /sys/class/bluetooth/hci*/hci*:* (an ACL link entry exists only while a device is connected; verify with a
  paired speaker), skip ensure_usb_pulse_sink when /proc/asound has no USB card, raise the watch to 5 to 10 s.
  Step 3 (nmcli): with auto_wifi_setup_hotspot on, _tick_wifi_link calls link_up() every 2 s and the 2 s
  cache TTL makes every call a refresh: probe_client_wifi runs nmcli device status, GENERAL.CONNECTION device
  show and 802-11-wireless.mode connection show, three spawns per 2 s (about 150 ms CPU plus a D-Bus round trip
  each). ap_radio_active and saved_client_wifi_names only run on the setup screen. Proposed: key the nmcli
  classification on the /sys/class/net/wlan0 (operstate, carrier) tuple and re-run nmcli only when that tuple
  changes or every 30 s, invalidating from ensure_setup_ap/stop_setup_ap.
  Step 4 DONE: remeasured (above), released, PR branch perf/probe-sysfs-gates on the fork. The 380 MB RSS itself (surface caches) makes any fork expensive and is a
  separate item.
- DONE 2026-11-03 (reload key groups, scope="audio" reload hint, weather fetch on a worker; six portal connect
  calls: loop_settings 1630 ms worst to 9 ms, stall dumps 1 to 0, jank over 99 ms 8.5 to 1.9 per minute).
  Original note: settings reload stalls the sweep for 1.5 s (seen 2026-11-03, FRAME_DEBUG stall dumps: loop_settings=1560 ms,
  gap 1.6 s, twice in 30 min, each right after a portal action rewrote round_touch_settings.json).
  _apply_reloaded_settings runs on the main thread and rebuilds the radar layer inline (2_inline_rebuild 229 ms,
  2r_f_icons 211 ms) plus whatever else the reload touches. Move the heavy parts to the prewarm worker or
  split the reload across frames; measure which settings keys trigger the full rebuild.
- 2r_bezel still averages 5 ms per rebuild: apply_round_bezel band blits plus the HUD overlay once a minute
  (pills and text are cached now; the clock string is a fresh render each minute by nature).
- 2r_flights 8 to 9 ms per rebuild (max 19) with about 12 targets: trail drawing and tag placement.
- py-spy with --native stalls this process for seconds per sample on the Pi; use the FLIGHTSCNR_FRAME_DEBUG
  stages instead. faulthandler.dump_traceback_later never fired inside the app for stalls that were plain CPU
  time in C (PNG decode); unexplained.

## Display protection (requested 2026-11-02)

Next work item after the GIL / fork stall work above: an auto-dim feature to protect the round panel from burn-in.
Today the app has a manual brightness slider (backlight.apply_percent: sysfs backlight when present, else X11 DPMS
for off) and a scheduled quiet-hours dim (quiet_dim_enabled / quiet_dim_percent). There is no activity-based dim,
no idle screen-off and no static-pixel protection.
DECIDED 2026-11-03, in this order: (a) fix the settings reload stall first (new settings will trigger that reload);
(b) idle auto-dim AND idle screen-off, each independently enabled with its own timeout, both restoring full
brightness on a tap; (c) pixel shift; (d) the 380 MB resident size investigation. Static element fade and ambient
light following are skipped.
(b) DONE 2026-11-03: idle_dim_* and idle_off_* settings, device rows on Settings > Display, portal Display card,
six locales (catalogue revision 27), tests/test_idle_display_protection.py. Idle means no touch; the wake tap on a
blanked panel is swallowed. Verified on the Pi 2026-11-03/04 with 1 min dim 20% and 2 min off: backlight 255 to
51 at 1 min, 0 with bl_power 4 at 2 min, journal "Idle 2 min: display off until the next touch"; the morning tap
restored full brightness (the two timers re-fired exactly 1 and 2 min after it) and acted on nothing. Noticed in
passing: about 30 s after the blank the kernel reports bl_power back at 0 while brightness stays 0 (panel stays
dark; the manual screen-off path behaves the same, so not ours).
(c) DONE 2026-11-04: pixel_shift_enabled / pixel_shift_minutes (1, 2, 5, 10, 15; default off, 5 min). The whole
picture walks the perimeter of a square of half-side theme.s(1) (2 px on the 720 panel) one pixel per step
(rotation.set_pixel_shift, applied in both present paths and undone in to_logical so touches still land); each
step repaints the full frame once. Verified on the Pi with X11 screenshots (sudo scrot with admin's Xauthority,
DISPLAY=:0): symmetric 6 px bezel border before, picture offset by exactly the first path step after one interval.
(d) FIRST PASS DONE 2026-11-04 (release 2026.11.4.17): measured from inside the process with the new SIGUSR1 memory report
(display/round_touch/mem_debug.py, FLIGHTSCNR_MEM_DEBUG=1 adds tracemalloc). Display at 380 MB RSS = 86 MB
file-backed (libLLVM 42 MB via the Mesa GL stack, gallium 12 MB, python, libcrypto, curl_cffi, numpy, SDL) plus
294 MB private anonymous heap: pygame surfaces reachable from module globals and the app total 78 MB (map_bg
_surfaces 28 MB for 8 basemaps, 13 to 14 full-frame 720x720x4 layers 2 MB each, radar _icon_state 9 MB,
rotation _rot_sprite_cache 5 MB, the rest small caches), Python objects 89 MB by tracemalloc of which 75 MB was
json.decoder output in 1.2 million blocks: the four local databases (airports.json 15 MB on disk became 57 MB
of dicts for 95k records, cities 13 MB, runways 9 MB, faa 6 MB). Converting the dicts after json.load does not
return the memory (pymalloc arenas stay fragmented: 89 MB before, 82 MB after malloc_trim on the Pi), so the
loaders now stream the cache text record by record into packed array and byte-blob stores
(utilities/compact_store.py, AirportStore / CityStore / RunwayStore / FaaStore): the four databases cost 21 MB
after trim instead of 85 MB, iter_airports_near drops from 23 to 3 ms, icao_to_iata from 3 ms to microseconds,
answers identical to the dict scan on real data. The airports build takes 3 s on the Pi (was 0.7 s json.load),
so app.run() preloads all four on a daemon thread. Unaccounted after this: about 125 MB of anonymous heap that
is neither reachable surfaces nor tracemalloc-visible Python objects (SDL_ttf glyph caches, mixer sounds,
grpc/curl C buffers, PIL, glibc arena slack); mallinfo2 / malloc_trim numbers would split that and are the next
probe. Also worth a look: map_bg keeps 8 basemap surfaces (28 MB) for scales not on screen. Side effect of the
report: tracemalloc mode itself adds about 150 MB RSS and the report takes 23 s with it on, leave it off in
normal use.
Live result on the Pi with the packed stores (release .17, same tracemalloc report 3 min after start): Python heap
89 to 32 MB (json.decoder 75 to 8 MB, the rest is settings / airlines / icao_types JSON), parse peak 160 to
68 MB, report 23 to 4 s. Plain process (tracemalloc off) 3 min after start: 352 MB RSS, 266 MB anon, against 380 /
294 MB before at 1 h 48 min uptime; surfaces reachable at report time were 104 MB this run against 78 MB in the
first (more icons cached), so the like-for-like saving is the heap number, not the RSS delta. Remeasure RSS after
a few hours for the BACKLOG record.
OVERNIGHT RUN started 2026-11-06 22:00 ET on 2026.11.7.10: FLIGHTSCNR_MEM_SAMPLE_S=900 in /etc/flightscnr.env
(backup /etc/flightscnr.env.bak-2026-11-06) logs "[mem] sample" lines with RSS, anon and glibc in-use / free every
15 min; the SIGUSR1 report now ends with mallinfo2 and a malloc_trim(0) result. Read the curve first, then send one
SIGUSR1 (it trims, so it resets the comparison). Pi auto-update is off (update-notify.json), so pushes do not restart it.
OVERNIGHT RESULT 2026-11-07 (44 samples, 21:53 to 09:05, one process, 0 tracebacks): NO LEAK. Night (22:08 to
05:53): anon 306 to 365 MB while glibc in-use stayed flat at 138 to 155 MB and py_blocks flat (640k to 720k); the
whole rise was glibc free space inside the arenas ratcheting up, 89 to 158 MB (fragmentation, never handed back).
06:08: anon fell 42 MB on its own (heap top trimmed after ATC resumed at 06:00). Day (07:23 on): in-use rose 140 to
210 MB with traffic, which is live data, not slack: the 09:05 report showed 155 MB of reachable surface pixels,
largest radar._icon_state 31 MB for 316 visible aircraft (about 100 KB per target, pruned to what is on screen by
_prune_live_state, so bounded by traffic), map_bg 28 MB, _live_label_frame_cache 20 MB, _rot_sprite_cache 15 MB,
radar_hud._pill_cache 15 MB. mallinfo2 at 09:05: in use 208.2 MB, free in arenas 158.6 MB, arena 366.8 MB,
mmapped 4.3 MB. malloc_trim(0) took RssAnon 417.5 to 330.6 MB (87 MB back) in 15 ms.
NEXT: a periodic malloc_trim(0) (every 10 to 15 min, glibc only, timed so the 15 ms lands outside a sweep frame or
on a worker thread, then checked with FRAME_DEBUG for a stall) should hold anon near 330 MB instead of letting it
creep to 400+. Alternatives to compare: MALLOC_ARENA_MAX=2 and a lower M_TRIM_THRESHOLD in the systemd unit.
The sampler var was removed from /etc/flightscnr.env after the trim A/B (backup restored).
Seen in the same journal: fr24 logs "no authentication provided, using anonymous access" 3 times every ~90 s,
which suggests a new FR24 client (and maybe a new HTTP session and TLS handshake) per poll; and with the speaker
offline bluetooth_audio still spawns "rfkill unblock bluetooth" every ~38 s (a fork each time, see the fork stall
note); gating that on /sys/class/rfkill/*/soft would drop the spawn.
PERIODIC TRIM DONE 2026-11-07 (release 2026.11.7.13, mem_debug.start_trimmer, FLIGHTSCNR_MALLOC_TRIM_S default
600, 0 = off): a daemon thread calls malloc_trim(0) through ctypes, which drops the GIL. A/B on the Pi, same
morning traffic, each phase read from 3 min after a restart, from the always-on hitch log (/tmp/flightscnr-hitch.log,
gaps over 48 ms). Trim off: 30.5 gaps over 66 ms per minute, 6.1 over 100 ms, RssAnon 403 MB at 23 min. Trim every
30 s (stress setting): 31.3 and 6.0 per minute, RssAnon 351 MB at 32 min, first pass gave back 48 MB in 6 ms,
29 passes in 15 min. Folding the hitches on the trim period: the 0.25 s right after a trim held 20 small hitches
(max 80 ms, one extra frame) against 13 and 7 in the same windows 10 s and 20 s later; nothing over 100 ms lined up
with a trim. So roughly one in three trims costs one frame; at 600 s that is about one extra frame every 30 min, for
~50 MB less anon. MALLOC_ARENA_MAX / M_TRIM_THRESHOLD not tried; only worth it if the trim cost grows.
The baseline itself is noisy (30 gaps over 66 ms a minute in daytime traffic): a separate item for the sweep work.
UPSTREAM 2026-11-07: the trim is staged as fork branch perf/periodic-malloc-trim (standalone heap_trim.py, started
from App.run, so it does not depend on the open packed-DB PR that adds mem_debug.py); av8or now uses the same module
(release 2026.11.7.15, Pi: 60.3 MB back in 11 ms on the first pass). Log latches staged as fix/log-once-per-episode.
The sampler and C heap report lines can follow upstream once the packed-DB PR (which carries mem_debug.py) merges.
ALIGNED 2026-11-12 (issue #10): mem_debug.py, test_mem_debug.py, app.py and radar.py reset to upstream 2026.11.11.1.
Dropped from av8or as not upstream: FLIGHTSCNR_MEM_SAMPLE_S sampler, C heap (mallinfo2/malloc_trim) report lines,
"surfaces by total bytes", loop_misc lm_* sub-stages, inval_<module>_<line> counters, 2r_cpu, 2r_f_trails_cpu,
live_processed/live_targets/4L_update. Offer them upstream as a new PR if still wanted.
REPORT 2026-11-09 (2026.11.9.12 at 1 h 22 min, 2026.11.9.15 at 20 min, ~80 targets; the report now also lists
surface sizes by total bytes): RSS 476 / 463 MB, anon 390 / 377 MB, C heap in use 209 / 214 MB, free in arenas
136 / 118 MB, malloc_trim gave back 54 / 56 MB. Surfaces 157 / 162 MB: 8 basemaps 964x964 28.4 MB (one on screen);
13 full-frame 720x720 layers 25.7 MB (in use); 687 100x100 icon sprites and sub-pixel phases 26 MB; 40 icon
sub-pixel sources 403x403 24.8 MB plus ~20 tag sources (435 to 459 x 283) ~10 MB, kept in vis["up"] so new phases
are cheap; rotation._rot_sprite_cache 19 to 22 MB (rotated copies of those phases). The Pi has ~1 GB available, so
none of this is pressure on a 2 GB board; it matters for 1 GB boards. Candidates: (1) map_bg keeps only the active
scale and its neighbours (~20 MB); (2) an LRU cap on vis["up"] (rebuilding one costs 4.2 ms on the Pi and a phase
1.5 ms, so dropping them outright would push the live icon pass over budget; cap them instead, ~25 MB).
MERGED 2026-11-09: upstream PR 278 (packed local databases, merge 834691b at 07:30 UTC) together with 280 (weather
test timezone), 281 (log latches) and 282 (periodic trim). The sampler/C heap report follow-up is now unblocked.
REVIEW 2026-11-08 (upstream PR 278, yashmulgaonkar): four fixes pushed to perf/packed-local-databases-rebased and
cherry-picked to av8or (release 2026.11.8.10): near() latitude band /110.0 (old band dropped 29 airports over 1220
real-cache queries on the Pi, new 0); runways and FAA loaders locked (FAA still sets _loaded before the NASR fetch so
lookups never wait on the network); preload skips modules with no cache file (no boot downloads); gc_report freeze
side effect commented. Reply text drafted for Matt to post.
RETEST 2026-11-06 on upstream 2026.11.6.1 as the base, same Pi, both builds restarted and read at 3 min uptime
from /proc/<pid>/smaps_rollup: plain upstream RSS 520 MB / 434 MB anonymous, with the packed stores 437 MB / 352 MB,
so 83 MB less on an identical base and uptime (the early figure is larger than the long-run saving because the
json.load parse peak of about 160 MB has not been trimmed back yet at 3 min). Real-cache equivalence on the device:
94976 airport records, 11335 runway idents and 22046 FAA idents all identical to the json.load dicts, nearby-airport
lists identical for five regions at three size tiers (dict scan 140 ms, packed 17 ms), icao_to_iata identical for
ten codes, nearest city identical for five points (190 ms to 90 ms). Fork branch perf/packed-local-databases-rebased.
BOOT TIMING 2026-11-06, same Pi, upstream 3b3a001 against the PR branch 618b7d6, three alternating restarts each,
timed from systemd start: radar visible at 13.9 to 15.6 s in both builds (the disclaimer holds the screen about
10.8 s after the display starts); radar airports drawn at 15.4 to 18.3 s upstream against 14.7 to 16.4 s with the PR;
the preload finishes 6.4 to 7.0 s after the display starts (airports 4.3 to 4.7 s, cities 1.0, runways 0.6 to 0.7,
FAA 0.5), so about 6.5 s of one core at boot against about 1.1 s on demand upstream, which never loaded cities or
FAA in the first minute; worst frame gap in the first 30 s of radar 2.2 to 3.4 s upstream against 1.4 to 1.6 s with
the PR (consistent with json.load on the overlay worker holding the GIL, not attributed directly). Not measured: a
first-boot user tapping the disclaimer at once, where the airport overlay would wait for the build, up to about 4 s.
Original candidate list:

- Idle auto-dim: dim to a configurable level after N minutes without touch or a tracked event, restore on touch.
  The Pi panel exposes a sysfs backlight (/sys/class/backlight/10-0045, 0 to 255), so dimming is a hardware
  write; keep a software dim fallback (dark overlay on the frame) for panels without one.
- Idle screen-off / DPMS: blank after a longer idle period; wake on touch or on new traffic inside the inner ring.
- Pixel shift: move the whole rendered frame by 1 to 2 px on a slow cycle (every few minutes) so static HUD pills,
  range rings and the attribution line do not sit on the same pixels for hours. Cheap with the existing rotation
  and present path.
- Static element fade: lower the alpha of the HUD arc, range labels and zoom pill when nothing has changed for a
  while, bring them back on touch or traffic.
- Ambient light following: if a light sensor or camera is available, track room brightness; otherwise follow a
  sunrise/sunset curve from the home location (already known) as a proxy.
- Portal and on-screen settings for all of the above, kept in sync (settings.py option lists plus web/app.py and
  index.html), with the catalogue strings in all six locales.

## Daytime radar stutter (measured 2026-11-08, Pi 4B, about 85 targets drawn, ~65 live icons)

Baseline (2026.11.8.14, 09:15 to 09:23 ET, hitch log): 76.5 gaps over 48 ms per minute, 28.0 over 66 ms, 5.4 over
100 ms. FRAME_DEBUG: main thread about 9 ms live icon frame (4L_live_frame) plus about 25 ms present (4p_erase 4,
4p_live 8, 4p_sweep 3, 4s_update 4), so steady frames already sit at the 33 ms budget (28 fps). The layer rebuild
(every ~4 s on the prewarm worker) spends ~635 ms wall in 2r_flights, ~557 ms of it in trails (92 trails, 58 for
aircraft already off the display, ~5000 fixes projected, 1366 lines, 107 deliberate 2 ms yields); frames during a
rebuild swell to 70 to 107 ms, which is the visible stutter.
DONE 156b4cb (release 2026.11.8.16): per-trail projection cache keyed on zoom/pan/facing (fixes projected per
rebuild ~5000 to 188), thread-local projection batch, batch around the live icon pass. 2r_f_trails 557 to 456 ms
wall, jank over 99 ms 6.8 to 4.2 per minute, hitch log over 66 ms 28.0 to 23.0 per minute; per-frame cost unchanged.
TRIED AND REVERTED (930df5c, a3b45e7): redraw only live items whose sprite or rect changed, spreading damage through
overlaps. Pixel-identical (tests were good) but only 2% of item draws were skipped in this sky: the round-robin icon
pass refreshes about a third of targets each frame and overlapping tags pull in the rest. 4_present 25.4 to 25.2 ms.
Do not retry without first making unprocessed targets keep identical sprites and cutting tag overlap.
Counters added (78b053a, release 2026.11.8.18), 7 min capture at 10:58 ET, about 78 targets: a rebuild is
~187 ms of worker CPU in ~585 ms wall (trails 114 ms CPU in 501 ms wall; ~118 yields x 2 ms = ~236 ms of sleep, the
rest GIL waits). 55 of 95 trails drawn are for aircraft already off the display. The live icon pass refreshes ~10 of
~41 targets per frame and always hits its 6 ms budget (4L_update 6.9 ms), i.e. ~0.6 ms per target refresh.
DONE da358bb (release 2026.11.8.20): live icon budget 6 to 4 ms. 7 min FRAME_DEBUG at ~83 targets against the
2026.11.8.18 capture: 4L_live_frame 9.3 to 6.8 ms, 4_present 26.8 to 23.8, draw avg 32.3 to 28.0 ms, jank over
99 ms 6.9 to 4.5 per minute. Hitch log, 8 min from 3 min uptime: gaps over 48 ms 64.9 per minute (earlier runs
today 75 to 80), over 66 ms 21.4 (23 to 31), over 100 ms 5.2 (5.4 to 5.8). Remaining stutter is the layer rebuild
(~160 to 190 ms worker CPU every ~4 s); classic mode below attacks that, and smooth mode could still gain from
cheaper gone-aircraft trails.
UPSTREAM 2026-11-09: 5cc0de1, 156b4cb and da358bb staged as fork branch perf/dense-traffic-frames, opened as upstream
PR 284 on 2026-11-09. Upstream merged the periodic trim (#282) and log latches (#281) on 2026-11-09.
DONE 850601f (release 2026.11.9.17), found by a fresh capture on 2026-11-09 (~80 targets): two once-a-minute
freezes on the display thread, 1.5 to 1.9 per minute over 250 ms. (1) radar_hud.needs_minute_invalidate() called
invalidate_frame_layer(), so the next frame rebuilt the layer inline (300 to 440 ms); it now calls
expire_frame_layer() and the worker rebuilds. (2) lofi_audio.app_tick asked atc_audio.is_playing() twice a second
with lofi off; with no ATC stream that walks every /proc/<pid>/cmdline, and with a busy worker each GIL release cost
up to a switch interval (250 to 580 ms once a minute, 23 ms average; the same walk takes 9 ms in a quiet process).
Lofi now returns early when off and the display runs the orphan walk on a worker. 10 min FRAME_DEBUG and hitch log
after 3 min uptime: gaps over 250 ms 1.6 to 0.1 per minute, inline rebuilds 10 to 1 per 10 min, max gap 731 to
553 ms; the 66/100 ms rates are unchanged (25 and 4 per minute; the 4 s layer rebuild). New probes, FRAME_DEBUG
only (401a272): lm_* sub-stages of loop_misc and inval_<module>_<line> counts.
Still open from the same captures, in rough value order:
- DONE f179abb (release 2026.11.9.19): app._tick_data called invalidate_frame_layer() after check_new_aircraft(), an
  inline rebuild at every new alert. Now expire_frame_layer(); the worker bakes the rim flash ~0.5 s into the 12 s
  flash. Worst gap at each alert tick: 410 to 637 ms (median 525, 8 alerts, 11:24 to 16:00) to 120 and 176 ms (2
  alerts by 20:30). UPSTREAM PR 287 (open; parent PR 286, minute freezes, merged 2026-11-10).
- REVERTED 1f0f2fb (Matt: not enough perf gain to change how trails look). Was: DONE b1d73de (release 2026.11.9.18), Matt chose the faster fade: gone-aircraft trails fade out over 20 s
  (FLIGHTSCNR_GONE_TRAIL_FADE_S, 0 = old behaviour) and then stop being drawn; fixes stay stored. Interleaved A/B on
  the Pi (old, new, old, new, 6 min each, 80 to 86 targets): gone trails drawn per rebuild 51.5 to 3.5, trail lines
  1350 to 885 per 10 s, 2r_f_trails 469 to 325 ms wall and 110 to 75 ms CPU, layer rebuild 563 to 416 ms. Frames
  over 66 ms 26.3 to 25.3 per minute, over 100 ms 4.0 to 3.3: the cheaper layer barely moves frame stutter, so the
  layer worker's GIL time is not what sets the 66 ms rate. A first sequential A/B was void (present 23 to 31 ms on
  every frame between windows, traffic +28%, no throttling): interleave A/Bs. Upstream branch dropped.
- DONE 5457478 (release 2026.11.10.11): the :01/:31 scheduled weather refresh set _weather_redraw_pending and the
  radar then called invalidate_frame_layer(). Now expire_frame_layer(). Worst gap at each tick: 15 of 17 ticks
  froze, 213 to 528 ms (median 354, lower in the evening), to 74 and 84 ms (20:01, 20:31). UPSTREAM PR 288 (open, stacked on 287).
  Remaining invalidate callers are user actions
  (menus, settings, location changes): one freeze per tap.
- loop_prewarm_spawn 11.4 ms on the display thread per rebuild (the _radar_flights() snapshot plus Thread start).
- smooth_apply 5 to 10 ms per data tick; flip_observe 56 ms on its worker; AutoFloor probe 4.4 ms once a second (fine).
  ESTIMATE 2026-11-09 from the 24 min A/B logs: spawn and smooth_apply land in the same loop pass (the same 39 slow
  frames), adding 24 ms together. Moving both off the display thread would bring about 1.4 of the ~25 frames over
  66 ms per minute under 66 (about 5%; a lower bound, since slow-frame lines list only the top 10 stages) and frees
  about 5 ms of display-thread time per second. Small: worth doing only alongside other work in that code.
- Slow gen-0 collections (only passes over 5 ms are logged): median 10 ms, about one every 4 s.
- TESTED, NOT WORTH IT (2026-11-10, experiment only, nothing committed): a live icon budget below 4 ms. Interleaved
  on the Pi (4, 2, 0.5 ms, twice, 5 min each after 3 min warm-up, 61 to 76 targets, traffic rising through the run).
  Per frame: 4L_live_frame 6.4/4.6/3.3 ms then 6.8/5.0/3.6; loop_body 34.7/31.9/31.6 then 37.1/36.3/34.3. Hitch log
  gaps over 66 ms per minute: 19.6/21.8/23.4 then 30.4/30.0/26.0; over 100 ms: 2.8/2.2/4.2 then 5.0/6.2/5.8. So even
  the floor (about one target refreshed per frame, 2 ms of fixed pass overhead left) saves 2 to 3 ms a frame and does
  not move the stutter rate; traffic moves it far more. The 66 ms frames are not a steady-frame headroom problem
  that a few ms fixes. Seen in passing: 4p_overlays is a steady 8 ms per frame, the largest single present stage.
Earlier list of next candidates: a 4 ms live icon budget (each target refreshed every ~6 frames instead of ~4; targets move under
1 px/s, so likely invisible, and it brings steady frames back under 33 ms); shorter fade or no full redraw for
gone-aircraft trails (a visible behaviour change, needs Matt's call); cached per-trail sprites; the 3 ms sweep line.

## Feature: Classic radar mode (planned 2026-11-08, next after the smooth-mode perf work)

A "Classic" radar setting beside today's smooth motion (smooth stays the default and keeps working as now).
In classic mode every target only updates when the sweep passes its bearing, like a real radar, and the
painted returns fade between passes ("radar paint" look). Matt wants all radar content on the sweep: icons, tags,
trail growth, halos, and any other per-target redraws.
Why it is also the frame-rate fix: the 6 s sweep moves ~2 degrees per ~33 ms frame, so with ~40 targets the beam
crosses about 0.25 targets per frame. Today the live icon pass refreshes ~10 targets a frame and present erases
and redraws ~150 icons, tags and tips (see the stutter entry above). In classic mode targets are identical
between passes, so they can live on a cached targets surface and each frame only touches the wedge the beam
covers: expected steady frames ~15 ms instead of ~34 ms, leaving headroom for the layer rebuild.
Design notes:
- Per target, latch position, heading, sprite and tag when the beam crosses its bearing (bearing from radar
  centre, compared against the previous and current sweep angle, wrap-safe). New targets appear on their first
  pass; removed targets fade out instead of vanishing.
- Trails: append the new segment at the pass instead of redrawing every trail in the ~4 s layer rebuild (that
  rebuild is ~187 ms of worker CPU, 55 of 95 trails being aircraft already gone).
- Paint fade: each return dims from full brightness at the pass to a floor before the next pass. Per-frame
  per-target alpha would bring the cost back, so fade in coarse steps (for example 4 to 6 levels a rotation,
  pre-rendered alpha variants per sprite) and redraw a target only when its level changes, spread across frames.
- Sweep hidden (show_sweep off): keep an invisible beam driving updates so classic mode still paces itself.
- Tracked and selected targets: DECIDED (Matt, 2026-11-08) they keep moving smoothly every frame, with their tags
  and trail tips; only the rest of the traffic waits for the beam.
- Touch hit-testing must use the latched positions, not the live ones.
- Setting in settings.py plus the portal (web/app.py, templates) with catalogue strings in all six locales.
- Measure with FRAME_DEBUG and the hitch log against the smooth-mode baseline in the stutter entry.
DECIDED (Matt, 2026-11-16): (1) one three-way "Aircraft motion" choice (Standard, Smooth, Classic radar) replaces
the Smooth motion switch; saved devices map off to Standard and on to Smooth. (2) Tags fade with the icons (full
authentic fade, not text held at full brightness). (3) Alert aircraft follow the beam like other traffic; rim flash
and sound unchanged, halo painted bright at each pass.
Five phases, each a release to look at on the Pi:
- Phase 1 DONE 2026-11-16: setting (settings.radar_motion, key radar_motion, smooth_motion kept in step for older
  code; device picker row; portal select; six locales) and the beam latch (display/round_touch/radar_classic.py,
  BeamLatch). live_icon_frame repaints only targets the beam crossed (bearing of the painted position), everything
  on a view change, and the tracked and selected aircraft every frame; tags hold with their icon; taps use painted
  positions (radar._tap_xy). Same present path as smooth, so no speed gain yet. Known gaps left for later phases:
  the baked trail runs up to a rotation ahead of a held icon (phase 4), departed targets vanish at the next layer
  publish (phase 3), heli rotors freeze between passes, rim targets still update on the layer cadence (phase 4),
  and Fly smoothly in/out applies to all traffic at each pass, not only tracked and selected aircraft.
- Phase 2 DONE 2026-11-16 (release 2026.11.16.12): held targets are stamped once onto a copy of the rotated base
  (rotation._held_update, radar.live_held_frame); per frame the display only restores from that copy and draws the
  beam, HUD and the tracked and selected aircraft. Changed rects are restored from the bare base and every
  overlapping held item restamped clipped to the rect, one rect at a time, so it is pixel-identical to per-frame
  drawing (tested, also rotated); over 40 changed rects in a frame falls back to a full restamp. Held trail tips
  wait for the pass. Interleaved A/B on the Pi (smooth, classic, smooth, classic, 5 min each, mode switched through
  the settings file with no restarts, 55 to 58 targets): 4_present 20.8/22.0 to 10.3/9.9 ms, 4L_live_frame 6.7/6.9
  to 1.6/1.3, 4p_erase 3.2/3.5 to 0.7/0.8, 4p_live 5.7/6.3 to 0, 4h_held 0.5/0.3. Hitch log per minute: gaps over
  48 ms 37.8/48.8 to 19.4/21.0, over 66 ms 14.6/18.8 to 3.4/2.2, over 100 ms 1.4/1.2 to 0.2/0.2. What is left per
  frame in classic: sweep 3.1 ms, display update 3.6, overlays 1.5. The layer rebuild is unchanged (~270 ms every
  4 s) until phase 4.
- Phase 3 DONE 2026-11-16 (release 2026.11.16.14): stepped paint fade (radar_classic.fade_level/fade_brightness,
  radar._faded with a weak per-sprite cache of dimmed copies): icon, halo and tag dim in 5 steps to 35 percent before
  the next pass; tracked and selected stay full. Departed targets become ghosts (radar._ghosts, filled by the layer
  worker when it prunes): their paint decays past the floor and goes after ~7 s, or at once on a view change.
  FLIGHTSCNR_CLASSIC_FADE=0 turns it off (no portal control). Pi A/B (fade off, on, off, on; 4 min each after
  2.5 min warm-up; traffic rose 57, 55, 67, 83 targets, so the stutter rates are confounded): 4h_held 0.3/0.5 to
  1.3/1.8 ms, 4L_live_frame 1.4/1.7 to 2.1/2.6, 4_present 10.3/11.2 to 11.4/12.6, held rects changed per 10 s
  41/55 to 178/226. Gaps over 66 ms per minute 3.5/6.2 (off) and 5.8/11.2 (on, the last at 83 targets); over 100 ms
  0.8/0.8 and 0.2/0.5. So the fade costs about 1.5 to 2 ms a frame. Open look question for Matt: tags at the 35
  percent floor are hard to read in a screenshot; a higher floor for tags only is a small change.
- Phase 4 DONE 2026-11-16 (releases 2026.11.16.16 and the next): trails end at the painted position
  (_draw_trails takes the head from _live_frame_cache; unpainted targets get no trail) and a new layer recomputes the
  held tips against its heads, with the present path holding that burst back one frame so it lands with the new
  base. Rim targets are beam-latched sprites (_rim_spec on the worker, _classic_rim_items on the display), fading
  like the rest; a target entering range keeps its rim paint until its icon is painted. After a view change the
  layer is expired again 0.6 s later so trails return. TRIED AND DROPPED: one layer rebuild per rotation (6 s
  instead of 4). Pi A/B in classic (4, 6, 4, 6 s; 4 min each; 64 to 74 targets): rebuilds 14 to 10 per minute but
  gaps over 66 ms 11.0/12.8 (4 s) against 12.0/11.8 (6 s), over 100 ms 1.2/1.5 against 1.0/1.5. No gain, and new
  traffic appeared up to 2 s later, so classic keeps the 4 s cadence. Per frame now: 4_present ~13.2 ms,
  4h_held ~2.1, 4L_live_frame ~3.0, ~110 held items, ~33 changed rects a second. The 66 ms rate here (11 to 13 per
  minute at ~70 targets) is above the phase 2 figure (2 to 3 at ~57 targets, before fade and rim sprites); traffic
  differs, so phase 5 needs a same-hour smooth against classic comparison.
- FIXED 2026-11-16 (release 2026.11.16.18), reported by Matt: targets brightened out of step with the beam. The
  fast present path draws the beam at sweep minus the panel rotation, while a logical point lands at its bearing
  plus the rotation (rotation._map_display_point), so on the Pi's 90 degree panel the latch fired half a turn from
  the visible beam. radar._beam_bearing() now gives the beam as drawn (sweep minus twice the rotation); a test
  derives that from the real mapping for 0, 90, 180 and 270. Screenshots on the Pi confirm bright paint directly
  behind the beam. Lesson: check beam-relative behaviour on the rotated panel, not from logic in logical space; the
  earlier screenshot checks only showed that fading varied by bearing, not that it was aligned.
- Slow-frame work after phase 4 (2026-11-16). The phase 4 captures showed the full restamp of every held target at
  each layer swap in 106 of 149 slow frames (15 to 30 ms). DONE release 2026.11.16.20: staged swap
  (rotation._held_stage_step, 3 ms a frame onto the next base while the old picture stays up; fallback to a full
  restamp now by changed area, not rect count). DONE release 2026.11.16.21: the stage stamps the held frame as it
  will be on the new layer (radar.live_held_frame_for, tips against _heads_by_gen), and the swap frame skips the
  incremental update, so the tips are not all redrawn after the swap.
- Phase 5 numbers, same-hour interleaved A/B on the Pi (smooth, classic, smooth, classic; 5 min each; mode switched
  through the settings file; release 2026.11.16.21; 63 to 64 targets): gaps over 66 ms per minute 19.8/19.2 smooth
  against 11.6/11.4 classic; over 100 ms 1.2/1.6 against 0.4/1.2; over 48 ms 47.0/54.6 against 42.4/43.8.
  4_present 21.3/22.5 against 12.5/12.8 ms, 4L_live_frame 6.4/6.7 against 2.8/2.7, 4h_held 1.7, 4h_stage 3.0 on
  stage frames. The run before it (2026.11.16.20, 59 to 79 targets): 21.6/19.8 against 13.4/9.6, over 100 ms
  4.4/2.4 against 0.8/1.0. So classic with fade, rim sprites and trails cuts frames over 66 ms by about 40 percent;
  the phase 2 figure (2 to 3 a minute) did not survive those additions.
  STILL OPEN: of ~48 slow classic frames per 5 min, 30 to 34 coincide with a layer rebuild on the worker (GIL), and
  29 still show 8 to 22 ms in 4h_held. Not yet pinned down; suspects are tag changes at each publish (the worker's
  label layout adds and drops tags, each a large rect with many overlapping items to restamp) and fade steps of
  overlapping tags. Next probe: count and area of held rects per frame by key kind, and restamps per rect.
- Phase 5 DONE 2026-11-16: .env.example documents the motion override and FLIGHTSCNR_CLASSIC_FADE; README has no
  motion section to update. ACCEPTED by Matt 2026-11-16 at the measured level (about 40 percent fewer frames over
  66 ms than smooth). The STILL OPEN item above (8 to 22 ms held updates in slow frames) stays as CPU-side follow-up.

UPSTREAM 2026-11-16: classic radar staged as fork branch feat/classic-radar (one commit, 557cc01, on upstream main
3544836; 16 files; upstream suite 2559 passing). Matt opens the PR.

## Next: GPU-driven radar renderer behind a portal setting (requested by Matt 2026-11-16)

After classic radar ships, look into a parallel GPU-driven version of the radar display, selectable in the portal
beside the current CPU path (which stays the default until the GPU path is proven), so classic radar and other
features can be enhanced.
Why: the CPU path is at its budget on the Pi 4. Every change to the picture costs CPU blits plus an X11 upload of
the changed rects, which is why the paint fade is 5 steps and not continuous, and why a per-frame fade or more
steps were ruled out. With textures, brightness is a per-draw alpha value and a continuous fade is nearly free.
Confirmed on the Pi 2026-11-16: Pi 4 Model B Rev 1.5, dtoverlay=vc4-kms-v3d, v3d and vc4 modules loaded,
/dev/dri/renderD128 present, so the VideoCore VI GPU (OpenGL ES 3.1 class) is available. pygame 2.6.1 on SDL
2.32.4, which ships pygame._sdl2 (Renderer and Texture). The service runs SDL_VIDEODRIVER=x11 under lightdm.
Not confirmed: that an accelerated SDL renderer actually comes up under this X11 kiosk (glxinfo is not installed),
how texture uploads of the 720x720 base perform, and behaviour on other fleet hardware (Pi 3, Pi 5, Zero 2).
First steps: (1) a standalone probe on the Pi: create an SDL2 Renderer, report its driver name and flags, time a
full-screen textured frame with ~150 alpha-modulated sprites and a base texture upload. (2) If accelerated, a
renderer interface behind the fast present path (rotation.present_radar_sweep) with the CPU path as one backend:
base as a texture, targets as textures with per-draw alpha, beam as geometry. (3) Portal setting, default CPU,
automatic fallback when no accelerated renderer is found. (4) Same interleaved A/B method as the classic work.
Things a GPU path would unlock: continuous paint fade and beam afterglow, per-frame motion for all targets without
the live icon budget, smoother map pan and zoom.
SHIPPED 2026-11-16 (releases 2026.11.16.28 and .29, tests/test_gpu_renderer.py): GPU renderer, opt-in, CPU default.
How it works: gpu.py opens the window with pygame.SCALED (which gives it an SDL renderer) and shares that renderer
with pygame._sdl2, so every screen still draws to the display surface (flip uploads it as one texture, about 5 ms)
and only the radar fast path changed: gpu_present.py draws base layer (GPU-rotated), sprites with per-draw alpha,
trail tips, rim, sweep wedge, HUD texture and one overlay texture for bubbles, tiles and menus, from scratch every
frame. Chosen in the portal (Radar, Renderer) or FLIGHTSCNR_RENDERER; needs an app relaunch. Runtime flag for
features: gpu.active(). Classic radar uses it for a continuous paint fade (radar_classic.glow_brightness).
Fallback to CPU: no renderer, start-up fill check over 2.5 ms per layer (see below), last GPU start did not finish
(gpu_state.json "starting" found at boot), or a radar frame raising mid-run. A failed state is sticky until the
setting is saved again (CPU, save, GPU, save) or the env var forces it.
Probe on the Pi 4 (X11 kiosk, v3d): render drivers opengl, opengles2, software; 150 alpha sprites plus base plus
rotated beam in about 6 ms accelerated against 33 ms software; vsync locks 60 fps.
A/B on the Pi, same hour, classic motion, 29 to 39 targets, 180 s per arm after 150 s warm-up, interleaved:
frames over 66 ms per minute 1.7 and 0.3 on GPU against 8.0 and 2.7 on CPU; over 99 ms 0.3 and 0.0 against 1.0
and 0.3; present stage 3.8 ms against 10.8 to 11.6 ms; whole draw 5.4 ms against 12.2 to 13.3 ms. Light evening
traffic, so the busy-hour comparison (60 plus targets) is still to do.
Not done or not verified: (1) only the Pi 4 was tested, no Pi 3, Pi 5 or Zero 2; (2) the start-up check ran at
9.7 and 14.1 ms with vsync on, against a 22 ms limit, so a slow boot could trip the fallback by mistake; (3) the
overlay tiles, radial menu, lofi pill and update bubble were not exercised on the panel in GPU mode, only in
tests with stand-ins; (4) the layer rebuild still runs on the CPU and still causes most remaining slow frames;
(5) frames composed on the CPU (pan, menus) use the nearest stepped fade, so brightness can step when a pan starts.
DONE 2026-11-16 (release after 2026.11.17.11): the radar runs at 60 fps on the GPU renderer (FLIGHTSCNR_GPU_FPS,
30 to 60, default 60; the CPU renderer stays at 30). A/B on the Pi 4, GPU mode, classic, 29 to 36 targets,
interleaved 60/30/60/30: 59.3 and 59.4 fps against 29.6; interval p95 18.3 ms against 40.4 to 40.7 ms (30 fps
under vsync alternates 33 and 50 ms frames, so 60 is also the more even of the two); frames over 66 ms per minute
0.3 and 1.0 against 0.3 and 0.6; process CPU 45 to 50 percent of a core against 39; SoC 50 C against 48 C.
About one 2 s window in five at 60 fps had a skipped refresh. Not measured at busy-hour traffic.
Smooth motion at 60 fps on the GPU renderer, measured 2026-11-16 on the Pi 4 (release 2026.11.17.12, 28 to 32
targets, interleaved smooth/classic/smooth/classic, 185 s per arm, mode switched through the settings file with
no restart): smooth held 59.2 and 58.9 fps (classic 59.3 and 59.4); interval p95 18.2 and 18.6 ms (classic 18.3);
frames over 66 ms per minute 1.6 and 5.2 (classic 1.0 and 0.0); over 99 ms 0.0 and 0.3 (classic 0.3 and 0.0);
process CPU 62 to 72 percent of a core (classic 46 to 48); SoC 50 to 51 C (classic 49 to 51 C). The extra cost in
smooth is the per-frame live icon work on the CPU (4L_live_frame 4.3 to 5.3 ms a frame against 1.4 ms), now paid
60 times a second; the GPU draw itself is 1.3 to 1.9 ms. So smooth reaches 60 fps in light traffic but with about
20 points more CPU than classic and more slow frames; at busy-hour traffic it may not hold 60. Not measured there.
Pi left in smooth motion on the GPU renderer for Matt to look at.
Upstream: branch feat/gpu-renderer on the fork, rebuilt 2026-11-16 as GPU only (757e539 plus the start-up check fix, two commits on upstream
main 3544836, 16 files, no classic code, no BACKLOG.md; upstream suite 2466 passing). Matt's decision: the GPU PR
adds the mode alone, independent of the classic radar PR (upstream #295). FOLLOW-UP PR, only if #295 is accepted
and after both merge: classic on the GPU, which is the held-target drawing in gpu_present (held, held_alpha
parameters), radar._fade / live_held_alpha / the dimmed copy in draw_live_icons, radar_classic.glow_brightness,
rotation.shown_layer_gen on the GPU path, and the TestHeldAlpha, TestGlowCurve and TestFadeFollowsTheRenderer
tests. All of that is in av8or main already. Whichever of the two PRs merges second needs a small rebase in
rotation.present_radar_sweep.
Panel check in GPU mode 2026-11-16 by injected taps: airport METAR tile opens and clears, flight detail opens and
the return to the radar redraws, no GPU fallback logged. Radial menu, lofi pill and update bubble still untested
on the panel. Start-up check now takes the best of 12 frames (release 2026.11.17.14).
DEVICE TEST of the exact fork branch, 2026-11-16 (cloned to its own folder on the Pi, run as a transient systemd
unit mirroring flightscnr.service, av8or service stopped meanwhile, settings and env restored after):
GPU start, radar at 59.2 fps (interval p95 18.1 ms, 1.0 frames over 66 ms a minute) with upstream smooth motion;
58.9 fps with smooth motion off; CPU chosen 29.5 fps on the untouched path with no GPU log lines; airport tile,
radial menu and zoom control drawn correctly in GPU mode; portal /radar/json reports renderer and state; portal
POST cpu then gpu clears a failed state; kill -9 seven seconds into a start gives "the last GPU start did not
finish" and CPU on the next start; a clean stop at the same point does not count as a failure;
FLIGHTSCNR_RENDERER=gpu retries past a failed state and =cpu wins over the setting.
FOUND AND FIXED by that test: with LIBGL_ALWAYS_SOFTWARE=1 (Mesa llvmpipe) the old frame-time start-up check
passed (27.5 ms against a 40 ms limit, and the earlier 22 ms limit had only 4 ms of margin over a real GPU at
17.9 ms because vsync quantises the number), and the radar then ran at 32 fps with a 26 ms present, worse than
CPU. SDL_RENDER_DRIVER=software does not force this case: pygame.SCALED picks the driver itself. The check now
times one more full-window blended layer with no present (one-pixel readback to finish the frame): 0.58 ms on
v3d in six starts, 5.1 ms on llvmpipe, limit 2.5 ms; under four busy loops the GPU figure stayed under 1 ms.
Still not tested on a device: a radar frame failing mid-run (unit test only), other Pi models.
Ideas the flag now allows: longer beam afterglow, a paint flash as
the beam crosses a target, per-frame motion for every target, base upload split into bands.
Unrelated, seen 2026-11-16 in a fresh venv: tests/test_iss.py::TestDraw::test_flown_track_has_a_soft_glow_inside_the_chart
fails on its own on main (a pixel outside the chart differs); not from this work.
Upstream branch updated 2026-11-17 (fork feat/gpu-renderer at bde88d5, normal push): upstream merged Classic radar
(#295) and the basemap re-download (#296), so the branch conflicted and, worse, would have drawn no Classic targets
in GPU mode (the GPU path ignored the held list). Merged upstream main ef51428 in and added one commit: gpu_present
draws the held targets exactly as radar.py prepares them (CPU stepped fade), rotation.shown_layer_gen answers on the
GPU path. Matt's decision stands: no continuous fade in this PR. The follow-up PR is now only radar._fade,
live_held_alpha, held_alpha plumbing, radar_classic.glow_brightness, the hint text and three test classes. Device
run of bde88d5 on the Pi 4: smooth 60 fps (interval p95 17.3 ms), Classic 59 to 60 fps (p95 17.6 to 18.0 ms, no
frames over 66 ms in four windows), held targets on screen with the stepped fade. Upstream suite on the branch:
2620 passing plus tests/test_iss.py::TestDraw::test_flown_track_has_a_soft_glow_inside_the_chart, which is flaky
on plain upstream main as well (failed 9 of 12 runs there; not from this work, worth a look or an upstream issue).
DONE 2026-11-17: all-day profile of Classic radar on the GPU renderer against traffic density (Pi 4B, av8or build
with the continuous fade, FLIGHTSCNR_FRAME_DEBUG=1 from a temporary drop-in, 2 s windows binned by targets drawn).
Clean span 13:30 to 20:17 ET, 404 minutes, 28 to 138 targets, 59.1 fps overall, 95 percent of windows at 57 fps or
more, interval p95 17.7 ms, GPU draw 0.8 to 1.8 ms. Per band (minutes, fps, frames over 66 ms a minute): 20-29: 3,
59.3, 0.32. 30-39: 118, 59.3, 0.35. 40-49: 70, 59.2, 0.26. 50-59: 138, 59.0, 0.62. 60-79: 74, 58.9, 1.07. 80+: 2,
58.8, 1.43. Display CPU 52 percent of a core on average (max 73), 49 C average (max 52.6).
Overlay-up span 07:33 to 13:19 (update bubble on screen, 326 minutes, 33 to 132 targets): 57.3 fps overall, 58.0 at
30-39 targets down to 55.8 at 60-79, 2.05 frames over 66 ms a minute, display CPU 97.5 percent, 52.7 C.
Pure feat/gpu-renderer branch (stepped fade), one spot check 11:07 to 11:15: 5.1 minutes at 41 to 49 targets, 58.9
fps, interval p95 17.9 ms, 1.17 frames over 66 ms a minute. The 15:07 and 18:07 spot checks were cancelled, so the
pure branch has no reading above 49 targets. Pi restored 20:19 (Smooth, GPU, drop-in removed, env file matches the
backup) and /home/admin/gpu-day, gpu-branch-test and prof deleted.
DONE 2026-11-18: upstream 2026.11.16.2 merged by hand (sync issue 11: 14 files conflicted because upstream took the
Classic radar #295 while av8or carries it with the GPU fade on top). Every Classic hunk kept this side; #296 and the
PICO icon mapping came in unchanged. The same conflict will recur when upstream merges the GPU renderer PR and the
fade follow-up: resolve the same way (keep this side, check the diff against HEAD is only upstream's other changes).
Follow-up PR READY 2026-11-20: upstream squash-merged the GPU renderer as #297 (dab2257) and added a renderer switch
confirmation (#298), released as 2026.11.20.1. av8or merged it (dae17ec, release 2026.11.20.10; the duplicated
settings, portal and locale blocks took upstream's copy), fork main was fast-forwarded to upstream, and the Pi runs
2026.11.20.10 (Smooth, GPU active). Fork branch feat/classic-gpu-fade is at 2ab1de5: upstream main merged in with a
normal push (no rebase, no force push), 13 files and 208 insertions against upstream main, merges cleanly, suite
2650 passing bar the flaky ISS test. Its fade files are identical to av8or's, which is what the Pi runs. Matt opens
the PR himself. Not re-run on the Pi as the bare branch since c525204 (59 to 60 fps then).

Profile note 2026-11-17 13:30 ET: from 07:33 to 13:19 the "update available" bubble was on screen (the Pi was three
releases behind), and it alone cost 8.1 ms a frame (see the next section). Numbers from that span (57.5 fps, 97
percent of a core, flat across 33 to 108 targets) are "Classic on the GPU with an overlay up", not the clean case.
The Pi was updated and restarted at 13:19 and is bubble-free since; use `analyze.py flightscnr '2026-11-17 13:35:00'`
for the clean figures (Smooth was profiled 13:25 to 13:29, then back to Classic). Every push to origin main brings
the bubble back until the Pi pulls: after pushing, `git pull --ff-only` in the Pi checkout and restart flightscnr.
The 11:07 spot check of the pure branch ran 11:07:22 to 11:15:03 (spots.log); the later check-ins were cancelled.

## Next GPU candidates: CPU drawing worth moving (profiled 2026-11-17, Pi 4B, GPU renderer, 39 to 47 targets)

Queued behind the Classic fade PR. Method: [frame] stage timings for the day, py-spy 0.4.3 at 250 Hz on the live
process (90 to 120 s each: Classic with the update bubble, Classic without, Smooth), `top -H` for the main thread.
The py-spy venv and raw stacks on the Pi were deleted at wrap-up (pip install py-spy in a throwaway venv to redo).

Baseline with nothing extra on screen: Classic 59.3 fps at 41 percent of one core, Smooth 58.7 fps at 68 percent.
`4g_present` is mostly the vsync wait, so "draw avg 14 ms" is not 14 ms of work. Ranked by measured effect:

1. Trails in the 4 s layer rebuild. The rebuild takes 300 to 360 ms on a worker thread and trails are 260 to 300 ms
   of it (about 735 lines and 190 dots through pygame.draw, plus 60 deliberate 2 ms sleeps to release the GIL). It
   is the main pacing fault left. Smooth: 2 s windows with a rebuild run 57.7 fps, median worst frame 60.6 ms, 9.3
   frames over 66 ms a minute; windows without run 59.6 fps, 23.4 ms, none. Classic: 59.1 against 59.5 fps, worst
   frame 35.4 against 21.1 ms. GPU version: draw the trail segments into a render-target texture on the main
   thread, a budgeted slice per frame, and composite it over the base. pygame 2.6.1's Renderer has no geometry call
   and draw_line is 1 px, so segments are a stretched 1x1 texture as `gpu_present._draw_line` does today. Not
   measured: per-segment draw cost at this volume (held sprites cost about 20 us each, so a full redraw is perhaps
   15 to 20 ms, hence the slicing). Spike that first.
2. Overlays (update bubble, airport callout, location toast, lo-fi controls and tile, airport tile, favourite tile,
   radial menu; rotation.py `_blit_*`). Each one, every frame it is visible: allocates a 1080x1080 alpha surface,
   redraws itself, rotates the whole surface, then the GPU path re-uploads the rect. Measured with the update
   bubble: `4g_overlay` 0.2 ms to 8.1 ms a frame, main thread 41 to 97 percent, 59.3 to 57.5 fps (55.2 in rebuild
   windows), 42 percent of main-thread samples under `_draw_overlays` (21 percent in the full-surface rotate alone).
   The bubble also reads its notify JSON every frame. Only the bubble was measured; the other seven share the code
   shape. GPU version: one retained texture per overlay keyed on its content, drawn with the GPU's angle. The same
   key lets the CPU path cache the rotated copy, so this one speeds up both.
3. Smooth targets. `4L_live_frame` is 5.5 ms a frame in Smooth against 1.5 in Classic. About 16 percent of samples
   are the quarter-pixel sprite variants (`_subpixel_variant`, 16 per sprite) and uploading each as its own texture
   (`gpu_present._texture`); about 4.5 percent is `_clip_to_display` cutting sprites at the round edge with a mask.
   The GPU places a texture at a fractional position itself, so on that path: one texture per sprite, float
   destination, and one bezel mask texture drawn last in place of per-sprite clipping. Check on the device that
   linear filtering looks as good as the current variants before removing them from the GPU path.
4. Full-frame screens (everything that is not the radar fast path). Still CPU rotate then flip: `4a_rotate` 5.6 ms
   and `4b_flip` 7.3 ms, but from 11 windows of the disclaimer screen only. Measure the clock, detail and info
   screens before queuing it. GPU version: upload the logical frame and let the GPU rotate it.

Not worth moving yet: tags 16 to 43 ms, rim 7 to 14 ms and bezel 4 to 9 ms per rebuild, all off the main thread.
CPU fix found on the way, not a GPU item: `_tick_wifi_link` calls `wifi_setup.auto_hotspot_enabled()` every frame,
which opens and parses round_touch_settings.json each time (3.4 to 4 percent of samples). Cache it on the mtime.

Decision 2026-11-20 (Matt): no shared render-job or draw-list layer. A render-job refactor was built and run on the
Pi (av8or 2026.11.20.12), then reverted: it was not worth the indirection. Each feature carries its own branch on
the renderer (`gpu.active()`), as the Classic fade does (upstream PR 299). Do not re-propose the abstraction; add
the GPU path next to the CPU path inside the feature, CPU stays the default and the fallback.

Decision 2026-11-20 (Matt): GPU trails (item 1) were built, shipped in av8or 2026.11.20.14 and reverted the same
day. Do not retry them, and do not move anything else that changes the order things are painted in. Trails sit in
the middle of the baked layer (after rim blips, before baked icons, tags, status, attribution, zoom buttons and the
round bezel mask), so a separate trail texture drawn over the layer: escaped the bezel mask (stubs through the rim
ring, trail ends in the corners of a square output), crossed parked vessel dots, baked tags, the zoom pill, the
attribution and the ISS blip at up to 49 percent alpha, stayed in the old projection for 6 to 8 frames after a
zoom, pan commit or rotation (and for a whole burst of zoom taps), and could be doubled or missing for one layer
when the worker and an inline rebuild swapped their bake-or-list decision through a module global. The gain was
modest anyway (trail stage 330 to 95 ms off the main thread, frames over 66 ms 11 to 6 per 2 minutes, fps equal).
Rule for a GPU candidate from now on: it is already drawn per frame at present time, as its own item, and the GPU
version draws the same pixels at the same place in the same sequence. The Classic fade met that; trails did not.

Shortlist under that rule (2026-11-20), replacing the ranking above:
A. Overlays (item 2 above). Already last in the frame, in a fixed sequence, on both renderers, and the sequence
   stays as it is. Keep the CPU-drawn pixels: cache each overlay's rendered (and rotated) surface on a content
   key, upload only when the key changes. No GPU rotation needed, so no filtering difference. 8 ms a frame while
   one is visible, and no more 4.7 MB surface allocated (plus its rotated copy) per overlay per frame. Risk is a
   stale overlay from a key that misses an input (marquee, radial animation, notify JSON): key on the drawn
   state, test each overlay's key, and leave any animating overlay uncached.
B. Full-frame screens (item 4 above), measure first. One texture is the whole frame, so there is no order to get
   wrong; the GPU does the 90 degree rotate, which is exact (no filtering). Possible 5 to 6 ms a frame and no
   rotated full-frame copy. Evidence is 11 windows of one screen: profile the clocks, detail and info first.
C. Smooth sprites (item 3 above), reduced and spike first. Only "one texture per sprite at a float position":
   same items, same sequence. NOT the "bezel mask texture drawn last" part, which is an order change. Open
   question that decides it: whether pygame 2.6.1 passes float destinations through and whether filtered
   placement looks like the 16 quarter-pixel variants on the panel. If it does not match, drop it.
Not GPU work, still worth doing: cache `auto_hotspot_enabled()` on the settings mtime (3.4 to 4 percent of samples).

## Log noise (noticed 2026-11-04)

DONE 2026-11-06 (release 2026.11.7.10, tests/test_log_latches.py): "ATC resuming", "ATC deferred" and the
Bluetooth "offline, reconnecting" now log at info once per episode and at debug after that; the retries are
unchanged, and "Bluetooth speaker <mac> connected" marks the end of an outage. On the Pi each logged once after the
restart and then nothing for 8 minutes (before: all three every 30 to 40 s). Still noisy: "[ais] snapshot: N
vessels" every 10 s at info; a latch on the counts (log on change, or once a minute) would quiet it.
DONE 2026-11-09 (8fe5488, release 2026.11.9.12, tests/test_log_spawn_cleanup.py): rfkill unblock gated on
/sys/class/rfkill soft state, systemctl is-active skipped while bluetoothd is in /proc, fr24 login note passed
once per process, "[ais] snapshot" at info only on first pass, connect/drop and every 10 min. Pi, 10 min after the
deploy with the speaker offline: fr24 auth lines 23 to 1 per 10 min, AIS snapshot info lines 59 to 2, PIDs
allocated 138 to 128 per minute, no tracebacks. UPSTREAM 2026-11-09: fork branch fix/quiet-logs-skip-spawns,
PR submitted by Matt.
Original note:
With the speaker off and ATC enabled, the journal repeats every 30 s "ATC resuming - quiet hours ended" followed by
"ATC deferred - no USB/Bluetooth speaker": the resume path re-announces on every tick instead of once per
transition. The speaker reconnect loop also logs "offline, reconnecting" from both processes (display and portal)
on every attempt at the 32 s backoff ceiling. Both are cosmetic; the fix is a state latch so each message logs once
per transition.

## Time-dependent test failures (noticed 2026-11-04)

tests/test_open_meteo_weather.py: 9 tests pass in the evening (21:00 ET on 2026-11-03) and fail in the morning
(07:15 ET on 2026-11-04) on the same commit, with the forecast fixture yielding 2 days instead of 3. Looks like a
local-date versus UTC-date boundary in the forecast day pruning or the fixture's dates; needs a frozen clock in the
test. Not related to any display work.
DONE: efb0589 pins the weather tests to the fixture's timezone (upstream PR 280, merged 2026-11-09).

## Update notes on the device (fixed 2026-11-16)

The device and portal show only the "## What's Changed" section of a release body
(utilities/updater.extract_whats_changed), else the first paragraph. Our release bodies opened with a credit line,
so a synced upstream release showed only "Synced from ..." and our own releases only "av8or edition release ...".
DONE: .github/scripts/release-notes.py writes both bodies (changes under What's Changed, credit under About, PR
numbers and at-mentions stripped); release-av8or.yml and sync-upstream.yml call it; tests/test_release_notes.py
checks the output through the device parser. Releases published before this keep their old bodies unless edited.

## Portal HTTPS on the .local name (investigated 2026-11-16, nothing shipped, waiting on Matt's choice)

Ask: the portal at `http://<hostname>.local` should load without the user editing `https` back to `http`, ideally
with free auto-renewed certificates, and it must work for a recipient with no accounts or domain.

How it is served today (read from the code and the Pi, read-only):
- `flightscnr.py` spawns `web/app.py` with `subprocess.Popen`; it ends in `app.run(host="0.0.0.0", port=WEB_PORT)`,
  the Werkzeug dev server, plain HTTP, port 80 by default, as root (systemd unit `User=root`). No TLS code, no
  reverse proxy, no login on the portal, no HSTS header anywhere.
- On the Pi: listeners are 80 (python), 22 and 111 only. Nothing on 443 and no firewall rules, so 443 answers with
  an immediate TCP reset (connection refused), not a silent drop. avahi-daemon is active with no extra service
  files (name only). `openssl` is installed; nginx, caddy, certbot, tailscale, cloudflared are not.
- avahi also answers AAAA for the name, but the portal binds IPv4 only, so IPv6 attempts on port 80 are refused
  and the browser falls back to IPv4. Harmless today, one more failed attempt per load.
- The URL is advertised as text only: `config.web_portal_url()` (always `http://`) on the Info and Tracked screens
  and in the installer output. The only QR code is the Wi-Fi join QR on the setup screen; the hotspot portal is
  `http://10.42.0.1/wifi` with a catch-all captive DNS. There is no QR for the portal URL.
- The portal uses no browser API that needs a secure context (no geolocation, clipboard, service worker).
- The failure today: an explicit `https://<hostname>.local` (typed, a bookmark, or address-bar autocomplete that
  remembered https) gets "connection refused" (Chrome ERR_CONNECTION_REFUSED, Safari "can't connect to the
  server"). Chromium's own guide says an explicitly https navigation that fails gets a normal error page and no
  fallback to HTTP. Automatic upgrades of `http://` or scheme-less entries are different: Chrome, Firefox 136+
  and Safari 18.2+ try HTTPS and fall back to HTTP when it fails, and a fast refusal makes that fallback instant.
  NOT verified: which browser and entry method Matt actually hits; Safari's exact rules for typed addresses
  (sources disagree).

The hard constraint (checked against current documents, not memory):
- CA/Browser Forum Baseline Requirements v2.3.1 (2026-10-04), section 4.2.2: "CAs SHALL NOT issue Certificates
  containing Internal Names or Reserved IP Addresses". An Internal Name is one that does not end in a TLD in the
  IANA root zone; `.local` is not in it (RFC 6762 reserves it for mDNS). Reserved IP Addresses are the IANA
  special-purpose registries, which include every RFC 1918 LAN range.
- Let's Encrypt: HTTP-01 and TLS-ALPN-01 need Let's Encrypt to reach the host from the internet; DNS-01 needs a
  real public DNS name. Its IP certificates (general availability 2026-01-15, 6-day lifetime) are for public IPs
  only. dns-persist-01 (announced 2026-02) is not on the challenge-types page yet and would not change this.
- So no public CA can ever issue for `<hostname>.local` or the LAN IP. A padlock on the `.local` name is only
  possible with a CA the user installs on each phone or computer. A public-CA certificate is only possible for a
  different, public DNS name that happens to resolve to the LAN IP.

Options compared:
1. Public DNS name per device plus DNS-01 (the Plex `plex.direct` pattern). Device gets a name such as
   `<random-id>.<our-domain>` with an A record for its LAN IP and a Let's Encrypt cert; the portal URL becomes
   that name, the `.local` URL redirects to it. Unattended and auto-renewing, real padlock, nothing for the
   recipient to install. Cost and catches: someone must own a domain, run the DNS zone and a small broker service
   that holds the DNS API token and answers ACME challenges for devices (the token must never ship on devices or
   in this public repo). That someone is Matt, forever, for every recipient and every fork: about 10 to 15 USD a
   year for the domain, hosting can be free tier. Let's Encrypt allows 50 new certs per registered domain per
   week (renewals exempt), fine for a small fleet. Privacy: every device name lands in public Certificate
   Transparency logs and LAN IPs sit in public DNS (use random ids, never hostnames). Breaks when the internet
   is down, in the setup hotspot, and behind routers with DNS rebinding protection (they drop public names that
   resolve to private IPs). A typed `https://<hostname>.local` still fails, because the cert is for the other
   name. A single shared wildcard cert with its key in the repo (the local-ip.sh style) is ruled out: a
   published private key must be revoked under the CA rules and lets anyone on the LAN impersonate any device.
   The do-it-yourself variant (recipient brings a domain and a DNS API token) works but fails the "no accounts"
   requirement.
2. Local CA. The device creates its own CA on first boot, issues itself a leaf cert for `<hostname>.local`
   (renewed automatically, under 398 days for Apple), serves 443, and offers the CA for download. Free, offline,
   no third party, covers the real `.local` name. The cost is the one-time trust step on every client device:
   iOS (download profile, Settings, install, then General, About, Certificate Trust Settings, enable full
   trust: about 8 taps and two warnings), Android (Settings, Security, install CA certificate, plus a permanent
   "network may be monitored" notice), macOS (Keychain, set Always Trust, admin password), Windows (import to
   Trusted Root, confirm), Firefox (own store on some platforms). That is far more work than typing `http://`
   once, the CA arrives over plain HTTP, and installing a root CA is a bad habit to teach recipients (mitigate
   with name constraints and a key that never leaves the device). Until trusted, 443 shows a full-page
   certificate warning. Plain self-signed without the CA step is the same warning with no way out.
3. No TLS, fix the symptom. Keep 443 closed and fast-refusing (already true: this is what lets automatic
   upgrades fall back instantly), never send HSTS, and hand people a link with the scheme in it: a QR code on
   the Info screen for `http://<hostname>.local` (the `qrcode` dependency is already installed), plus an
   IP-based QR as a fallback for phones where mDNS fails. Free, no accounts, works offline. It does not rescue
   someone who types or autocompletes `https://`; that case needs either option 2 or a helper listener on 443
   with a throwaway self-signed cert that redirects to `http://`. The helper turns "refused, edit the URL" into
   "certificate warning, tap through, redirected", but it may also change what the automatic upgrade does
   (cert error instead of refusal; whether each browser still falls back silently is NOT verified, sources
   conflict), so it must be tested before it is ever on by default.
4. Tunnels and relays. `tailscale cert` gives a Let's Encrypt cert for `<machine>.<tailnet>.ts.net`, but needs a
   Tailscale account, HTTPS enabled on the tailnet, the client devices on the same tailnet, and publishes machine
   names in CT logs. Cloudflare Tunnel needs an account and a domain, and puts a portal with no login (it holds
   API keys and Wi-Fi setup) on the public internet. Both are fine as a documented opt-in for an owner who
   already uses them; neither fits a device handed to someone else.
5. Nothing else credible turned up. There is still no standard for browser-trusted HTTPS on local devices, and
   Chrome's 2026 "Always Use Secure Connections" default explicitly exempts local names, private IPs and
   single-label hosts from its HTTP warning because they cannot get certificates.

Recommendation: option 3 now, option 2 as an opt-in later, option 1 only if Matt wants to run a service.
Free auto-renewed public certificates for the `.local` name do not exist, and the only public-cert route (1)
makes every recipient depend on a domain and broker Matt operates, with internet and router caveats.
Plan for option 3 (no new packages, all changes ride the normal `git pull --ff-only` OTA, unit file and
`scripts/release.sh` untouched, boot disclaimer untouched):
- `config.py`: keep `web_portal_url()` as is; add an IP-based variant for the QR fallback.
- `display/round_touch/screens/info.py` (and the Tracked hint): draw a portal QR with the explicit `http://` URL,
  reusing the QR helper from `screens/wifi_setup.py`.
- `web/app.py`: bind dual-stack so the AAAA answer works; add a test that no response carries
  `Strict-Transport-Security`; a test for the QR payload scheme.
- Docs: one line in README/AV8OR.md on why the address is `http://`.
- Only after an on-device test Matt approves: optional 443 helper behind a new `WEB_HTTPS_REDIRECT=0|1` (default 0,
  documented in `.env.example`), disabled in the setup hotspot so captive-portal probes keep seeing a refusal.
Option 2 later would add `WEB_HTTPS=off|local-ca` and `WEB_HTTPS_PORT=443` in `.env.example`, key material under
`FLIGHTSCNR_DATA_DIR` (mode 600, never in the repo or diagnostics bundle), a "Trust this device" portal page, and
leaf reissue on hostname change. Existing fleet devices would get it by OTA with the default off.

Needed from Matt before building: which browser and device show the failure and how the address is entered
(typed bare, typed with a scheme, bookmark, autocomplete), and permission to open a temporary 443 listener on
the Pi to test the helper across Safari (iOS and macOS), Chrome and Firefox. Nothing was changed on the Pi.
Not verified: Safari typed-address upgrade rules, per-browser fallback on a certificate error, whether Chrome
154's default shipped exactly as announced, router rebinding behaviour for option 1.

Sources: cabforum/servercert `docs/BR.md` v2.3.1 (sections 1.6.1, 4.2.2, 7.1.2.7.12);
letsencrypt.org/docs/challenge-types (updated 2026-02-12), /docs/certificates-for-localhost, /docs/rate-limits
(updated 2026-08-05), /2026/01/15/6day-and-ip-general-availability; Chromium
`docs/security/ask-before-http/ask-before-http-adoption-guide.md`; attackanddefense.dev HTTPS-First in Firefox 136;
Safari 18.2 release notes via engineered.at; words.filippo.io on Plex; tailscale.com/docs/how-to/set-up-https-certificates.

Follow-up 2026-11-16: desktop Chrome on Windows (Matt's report)
Report: latest Chrome on Windows changes the `.local` address to https and fails with no fallback; editing it to
`http://` loads the portal on the same machine; Chrome on iOS falls back correctly.

What Chromium's current source says (main branch read 2026-11-16; the exact stable build and its field trials
were NOT checked, and nothing was tested on a Windows machine):
- `components/omnibox/browser/autocomplete_input.cc`, `ShouldUpgradeToHttps`: "Never upgrade IP addresses or
  non-unique hostnames on non-iOS builds". `net::IsHostnameNonUnique` is true for any name without a known public
  TLD, which includes `.local`, and for private IPs. So desktop Chrome does not add https to a typed bare
  `<hostname>.local`. iOS is carved out of that rule, which matches iOS upgrading and then falling back.
- `chrome/browser/ssl/https_upgrades_interceptor.cc`: `http://` navigations to non-unique hostnames are not
  upgraded at all unless the strict setting is on ("Always use secure connections" set to warn for public and
  private sites). The Chrome 154 default is the public-sites mode, which exempts them.
- Where an upgrade is attempted, both code paths fall back on any network error (refused included), on a
  certificate error, and on a 3 second timer. Refused versus timed out makes no difference to whether Chrome
  falls back, only to how long it takes.
- An explicit https URL never falls back (Chromium ask-before-http guide), and HSTS overrides everything.
Conclusion: stock desktop Chrome should load `<hostname>.local` over HTTP untouched. Something on that machine is
handing Chrome an explicit https URL or a strict policy. "Keep 443 closed" is still right for automatic upgrades
but does nothing for these cases, so the recommendation changes (below).

Causes, most to least likely, what the user sees, and what the device can do:
1. A remembered https URL: the address bar autocompletes `https://<hostname>.local` from history, a bookmark, a
   shortcut or synced history, and that is an explicit https navigation. User sees ERR_CONNECTION_REFUSED.
   Device side: only an answer on 443 helps (helper with a self-signed cert that redirects to `http://`: the
   user sees a certificate warning, clicks Advanced then Proceed once, lands on the portal, and Chrome keeps
   the exception for a while) or a trusted cert (local CA, option 2). User side: highlight the suggestion and
   press Shift+Delete, fix the bookmark, or use the IP address.
2. Strict mode or a policy: "Always use secure connections" on the public-and-private choice, or the
   HttpsOnlyMode policy on a managed machine. Chrome tries HTTPS, gets refused, and shows a full-page "site
   doesn't support a secure connection" warning with a Continue button (remembered about 15 days) rather than a
   silent fallback. Device side: only a trusted cert removes it; a self-signed helper would swap that warning
   for a certificate warning, no better. User side: Continue, switch to the public-sites choice, or allowlist
   the host.
3. An HSTS entry for the hostname in that profile (something once served HTTPS with that header under the same
   name). Chrome redirects internally to https and never falls back; user sees ERR_CONNECTION_REFUSED. A
   self-signed helper makes this worse (certificate errors cannot be bypassed under HSTS). Fix is on the
   client: delete the domain under chrome://net-internals/#hsts. The portal itself never sends HSTS.
4. An extension or security suite forcing HTTPS. Shows as fine in a Guest window, broken in the normal profile.
5. A stable-channel experiment that differs from the source read above. Would show as failing in a clean Guest
   window with default settings. NOT verified either way.
Ruled out by the report itself: mDNS or LLMNR resolution, IPv6 versus the IPv4-only bind, and firewalls. The
hand-edited `http://` URL loads, so the name resolves and port 80 is reachable from that machine; and since 443
on the Pi refuses instantly, Chrome is not waiting on a dropped packet. The IPv4-only bind can still add a
failed attempt per load, so the dual-stack bind stays in the plan as a tidy-up, not as the fix.

Checks for Matt on the Windows machine, in this order:
- The exact code on the failure page (ERR_CONNECTION_REFUSED, ERR_CONNECTION_TIMED_OUT, ERR_SSL_PROTOCOL_ERROR,
  or a warning page with a Continue button), and whether the address shows https before or only after Enter.
- A Guest window (profile menu, Guest; not Incognito, which still autocompletes from history): type the bare
  name. Loads there means cause 1, 3 or 4. Fails there means cause 2 by policy, or cause 5.
- chrome://settings/security: state of "Always use secure connections" and which of the two choices is selected.
- chrome://policy: any HttpsOnlyMode, HttpsUpgradesEnabled or HttpAllowlist entries.
- chrome://net-internals/#hsts, "Query HSTS/PKP domain" with the hostname: "Not found" rules out cause 3.
- Type `http://` plus the device IP from the Info screen: should load in every case except strict mode.
- chrome://version (version and channel), in case it is cause 5.

Recommendation, revised:
- Still first: the explicit `http://` QR, an IP-based URL shown next to the name, the dual-stack bind and the
  no-HSTS test. These cover phones and anyone starting clean.
- The 443 helper (self-signed cert plus redirect to `http://`) moves from "maybe" to "wanted if the checks
  point to cause 1", because per the source above desktop Chrome in its default mode never probes 443 on a
  `.local` name, so the helper cannot break a fallback there; it only catches explicit https. The open risk
  moves to the browsers that do probe 443 (Chrome on iOS, Safari, Firefox): they must still fall back when 443
  answers with an untrusted certificate. Chromium's desktop code falls back on certificate errors; iOS Chrome,
  Safari and Firefox are NOT verified. That is the on-device test still waiting on Matt's permission for a
  temporary 443 listener. Keep it behind `WEB_HTTPS_REDIRECT` (default 0) until that test passes.
- If the checks point to strict mode, no redirect trick helps and the choices are the local CA (option 2) or
  living with one Continue click every 15 days.
Sources: Chromium main `components/omnibox/browser/autocomplete_input.cc`, `net/base/url_util.cc`,
`chrome/browser/ssl/https_upgrades_interceptor.cc`, `https_upgrades_util.cc`,
`typed_navigation_upgrade_throttle.cc`, `docs/security/ask-before-http/ask-before-http-adoption-guide.md`.

PARKED 2026-11-16 by Matt: no further work for now. Suspected cause of the missing fallback is a VPN on the
Windows machine (unverified); the checks above were not run.
