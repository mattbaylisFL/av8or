# av8or backlog

Findings noticed but deferred. Keep entries short; link the measurement that found them.

## Radar sweep performance (measured 2026-11-01 on av8or.local, Pi 4B, X11)

Fixed in the sweep-perf patch (icon sprite caches, altitude colour snap, secrets.json cache, ATC orphan scan cache):
the 300 to 580 ms sweep freezes. Remaining, in order of measured cost:

- Grab pipeline shares the GIL with the render thread: pipe_dedupe is about 90 ms of pure Python every 2 s and
  shows up as the once-a-second 55 to 65 ms hitch (hitch log proc=1 share about 45%). Structural fix is moving the
  overhead grab into a separate process, or at least chunking dedupe with explicit yields.
- Live icon frame (smooth motion) spikes to 30 to 80 ms when a position batch changes many headings at once:
  every affected sprite is re-rendered and its sub-pixel variants regenerated (radar._icon_vis, _subpixel_variant).
  Consider rendering new variants on the prewarm worker, or capping variants per frame lower than 10.
- Flip board runs on the render thread: observe() about 11 ms per data tick and save() (json.dump to the SD card)
  about 11 ms every 10 to 15 s (app._update_flip_board). Move both to the grab thread or a worker.
- Pacing floor: the 4 ms yield sleep overruns by about 14 ms on average (loop_sleep_overrun), so the 33 ms timer
  lands at 36 to 38 ms (27 to 28 fps) with a few ms of jitter per frame. No vsync is available on the X11 path.
- The render thread reads update-status.json about 7 times a second (updater.update_running via several callers)
  and the HUD overlay is re-rasterized and rotated (1080 px SRCALPHA) on the render thread when its signature
  changes (4p_overlays up to 70 ms).
- _radar_flights() applies the position smoother about once per frame from several call sites; memoizing per
  loop iteration would save a few ms per frame.
- 2r_status (radar._draw_status) recomputes _visible_flights on every layer rebuild, about 12 ms each.
- py-spy with --native stalls this process for seconds per sample on the Pi; use the FLIGHTSCNR_FRAME_DEBUG
  stages instead. faulthandler.dump_traceback_later never fired inside the app for stalls that were plain CPU
  time in C (PNG decode); unexplained.
