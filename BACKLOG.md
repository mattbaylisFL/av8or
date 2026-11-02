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

Still open, in priority order:

- loop_sleep overrun of 13 to 14 ms even on near-zero sleeps is the main thread waiting to reacquire the GIL from
  the worker threads (prewarm rotate, flip-board observer, grab), not the kernel. It is now the floor under the
  remaining 48 to 60 ms hitches: 33 ms frame plus about 14 ms GIL wait plus loop_misc. Candidates:
  0_prewarm_rotate 6 ms, flip_observe 13 to 23 ms avg on its worker (still shares the GIL), 4a_rotate spikes to
  125 ms. sys.setswitchinterval(0.001) made no difference earlier; the real fix is less Python on the workers
  (or C-level pygame calls that release the GIL) or a separate process for the grab.
- 2r_bezel still averages 4.9 ms per rebuild: apply_round_bezel band blits plus the HUD overlay text and icon
  rerender once a minute (pills are cached now). Cache the HUD text clusters per minute string.
- 2r_flights 8 to 9 ms per rebuild (max 19) with about 11 targets: trail drawing and tag placement.
- The render thread reads update-status.json about 7 times a second (updater.update_running via several callers)
  and the HUD overlay is rotated (1080 px SRCALPHA) on the render thread when its signature changes
  (4p_overlays max 25 to 33 ms).
- py-spy with --native stalls this process for seconds per sample on the Pi; use the FLIGHTSCNR_FRAME_DEBUG
  stages instead. faulthandler.dump_traceback_later never fired inside the app for stalls that were plain CPU
  time in C (PNG decode); unexplained.
