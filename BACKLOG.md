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

Still open, in priority order:

- Frame pacing quantisation (the 55 to 65 ms hitch). The radar draw decision is made once per loop iteration, and
  an iteration is loop_misc (7 ms avg) plus a 4 ms sleep that overruns by 13 ms, so about 20 to 25 ms. Any
  iteration that ends past the 33 ms deadline costs a whole extra iteration, which is exactly the 55 to 60 ms gap
  mode in the hitch histogram (smooth decay from 48 ms, no separate cluster). Fix: sleep until the next draw
  deadline (min of the input-poll sleep and time remaining) and poll input without sleeping when a draw is due.
  Expect the 48 ms hitch rate to drop sharply and fps to approach 30.
- loop_sleep overrun of 13 ms on a 4 ms sleep is GIL contention from the worker threads (prewarm rotate,
  flip-board observer, grab), not the kernel. Candidates: 0_prewarm_rotate 6 ms, flip_observe 23 ms avg on its
  worker (still shares the GIL), 4a_rotate spikes to 125 ms. sys.setswitchinterval(0.001) made no difference
  earlier; the only real fix is less Python on the workers or a separate process for the grab.
- loop_misc outliers to 160 ms (2r_bezel 132 ms in the same frame): bezel rebuild when the ring or status text
  changes. Cache the bezel surface per signature.
- 2r_status (radar._draw_status) recomputes _visible_flights on every layer rebuild, about 12 ms each.
- Pacing floor: the 4 ms yield sleep overruns by about 14 ms on average (loop_sleep_overrun), so the 33 ms timer
  lands at 36 to 38 ms (27 to 28 fps) with a few ms of jitter per frame. No vsync is available on the X11 path.
- The render thread reads update-status.json about 7 times a second (updater.update_running via several callers)
  and the HUD overlay is re-rasterized and rotated (1080 px SRCALPHA) on the render thread when its signature
  changes (4p_overlays up to 70 ms).
- 2r_status (radar._draw_status) recomputes _visible_flights on every layer rebuild, about 12 ms each.
- py-spy with --native stalls this process for seconds per sample on the Pi; use the FLIGHTSCNR_FRAME_DEBUG
  stages instead. faulthandler.dump_traceback_later never fired inside the app for stalls that were plain CPU
  time in C (PNG decode); unexplained.
