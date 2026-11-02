# av8or backlog

Findings noticed but deferred. Keep entries short; link the measurement that found them.

## Radar sweep performance (measured 2026-11-01 on av8or.local, Pi 4B, X11)

Fixed in the sweep-perf patch (icon sprite caches, altitude colour snap, secrets.json cache, ATC orphan scan cache):
the 300 to 580 ms sweep freezes. Fixed by the dedupe key memoisation (pipe_dedupe 55 ms to 4 ms per cycle) and by
upstream f6011bd, merged 2026-11-02: the O(n^2) dedupe fallback, the live icon frame (now cached per target and
refreshed within a 6 ms budget), the flip board (now on its own worker, one airport scan per track), the per-frame
_radar_flights() copy on cached-layer frames, trail point decimation, and oldest-entry eviction for the rotated,
rotor and glow caches.

Still open:

- The once-a-second 55 to 65 ms hitch (about 60/min, p50 55 to 58 ms) survived both the dedupe fix and the icon
  caches; dedupe was not its cause. loop_sleep_overrun around 13 ms points at the pacing loop and the rest of
  pipe_grab_total (route enrichment, logo resolution, json writes). Next step: add wall and thread-CPU stages to
  the remaining grab steps, then move the overhead grab into a separate process if any one of them holds the GIL
  for more than a frame. Re-measure first on 2026.11.2.x with upstream's changes in.
- Pacing floor: the 4 ms yield sleep overruns by about 14 ms on average (loop_sleep_overrun), so the 33 ms timer
  lands at 36 to 38 ms (27 to 28 fps) with a few ms of jitter per frame. No vsync is available on the X11 path.
- The render thread reads update-status.json about 7 times a second (updater.update_running via several callers)
  and the HUD overlay is re-rasterized and rotated (1080 px SRCALPHA) on the render thread when its signature
  changes (4p_overlays up to 70 ms).
- 2r_status (radar._draw_status) recomputes _visible_flights on every layer rebuild, about 12 ms each.
- py-spy with --native stalls this process for seconds per sample on the Pi; use the FLIGHTSCNR_FRAME_DEBUG
  stages instead. faulthandler.dump_traceback_later never fired inside the app for stalls that were plain CPU
  time in C (PNG decode); unexplained.
