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

## Log noise (noticed 2026-11-04)

DONE 2026-11-06 (release 2026.11.7.10, tests/test_log_latches.py): "ATC resuming", "ATC deferred" and the
Bluetooth "offline, reconnecting" now log at info once per episode and at debug after that; the retries are
unchanged, and "Bluetooth speaker <mac> connected" marks the end of an outage. On the Pi each logged once after the
DONE 2026-11-09 (8fe5488, release 2026.11.9.12, tests/test_log_spawn_cleanup.py): rfkill unblock gated on
/sys/class/rfkill soft state, systemctl is-active skipped while bluetoothd is in /proc, fr24 login note passed
once per process, "[ais] snapshot" at info only on first pass, connect/drop and every 10 min. Pi, 10 min after the
deploy with the speaker offline: fr24 auth lines 23 to 1 per 10 min, AIS snapshot info lines 59 to 2, PIDs
allocated 138 to 128 per minute, no tracebacks.
restart and then nothing for 8 minutes (before: all three every 30 to 40 s). Still noisy: "[ais] snapshot: N
vessels" every 10 s at info; a latch on the counts (log on change, or once a minute) would quiet it.
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
