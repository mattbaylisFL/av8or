# av8or: a customized FlightScnr Pi

A public, lightly customized copy of [FlightScnr Pi](https://github.com/yashmulgaonkar/FlightScnr_Pi)
by Yash Mulgaonkar, built as a gift for **Av8oR**. It is **not a GitHub fork**, but
keeps upstream's full git history, which is what makes automatic merging possible.

> **License:** upstream is CC BY-NC-SA 4.0. Keep `LICENSE`, `NOTICE`, the README
> license section and every file header intact, credit the original project, say
> that changes were made, and keep it non-commercial. Don't imply Yash endorses
> this edition.
>
> **This repo is public. Never commit secrets, API keys, home locations or
> settings exports.** Per-device settings live on the device, not here.

## What is customized

Deliberately tiny, so upstream merges stay automatic:

| Change | Where |
|---|---|
| Clock wordmark `FLIGHTSCNRPI` → `AV8OR` | `flightscnr/display/round_touch/screens/flieger_clock.py`, `analog_clock.py` (one line each) |
| Boot / About image: Yash's contact-email line → "Custom edition · Av8oR" (his credit line is kept) | `flightscnr/assets/boot/brand_plate.png`, `about.png`, `splash.png` |
| Guard test: fails if an upstream refactor drops the wordmark | `flightscnr/tests/test_av8or_brand.py` |

The guard test matters: without it a merge that silently lost the wordmark would
still count as a success. With it, the sync holds the merge and opens an issue.

## How upstream stays merged

`.github/workflows/sync-upstream.yml` runs every 6 hours (and on demand from the
Actions tab):

```
upstream/main ──merge──▶ sync/upstream ──tests vs. baseline──▶ default branch + tag + release
                              │                    │
                         conflict?             new failures?
                              └──────▶ GitHub issue labelled `upstream-sync`
```

- **Clean merge, no new test failures:** the default branch is fast-forwarded,
  the upstream `VERSION` is tagged and a release is published. Nothing to do.
- **Conflict or new test failures:** nothing is published; an issue explains
  what to do. The issue closes itself once a later run succeeds.
- **Tests:** upstream's suite has ~30 known failures at any given time, so the
  gate compares against the pre-merge baseline *and* against pure upstream, and
  only blocks failures unique to the merge. A test that fails on upstream itself
  (common for new display-dependent tests) is upstream's problem, not ours.
- **Upstream workflow changes are never merged.** Our workflows always win.
  Held-back changes are listed in the release notes.
- GitHub pauses scheduled workflows on a public repo after 60 days without
  activity. Upstream ships almost daily, so this shouldn't happen; if it does,
  re-enable the workflow in the Actions tab.

Why tags matter: the Pi decides whether an update exists by comparing `VERSION`
with the newest **release tag** (`flightscnr/utilities/updater.py`), so the sync
job must publish tags or devices will never see updates.

### Rules that keep merges painless

1. **Never edit `VERSION`.** The sync job tags whatever upstream's value is.
2. **Prefer new files and swapped binary assets** over edits to upstream files.
3. **Avoid the hot files** (upstream commits touching them since July):
   `display/round_touch/app.py` (147), `web/templates/index.html` (122),
   `display/round_touch/settings.py` (89). Edits there will conflict.
4. Don't touch `scripts/release.sh` (frozen upstream, breaks their OTA) or the
   boot safety disclaimer (`screens/disclaimer.py`, `disclaimer_acceptance.py`);
   it's upstream policy and a safety notice, shown on every boot by design.

If a sync conflicts on the wordmark lines, re-apply the one-word change by hand
(see the table above) and push.

## One-time setup

1. **Settings → Actions → General:** allow actions for the repository.
2. **Make the default branch `main`** (*Settings → General → Default branch*).
   The Pi's installer hard-codes `origin/main`.
3. Run **Actions → Sync upstream → Run workflow** once and confirm it passes.

## Putting it on a Pi

The repo is public, so no credentials are needed anywhere (updates, the
portal's *Clean install*, and fresh installs all clone anonymously):

```sh
git clone https://github.com/mattbaylisFL/av8or.git ~/FlightScnr_Pi
cd ~/FlightScnr_Pi && sudo ./install-pi.sh
```

Then point the updater at this repo by adding to `/etc/flightscnr.env`:

```
FLIGHTSCNR_GITHUB_REPO=mattbaylisFL/av8or
```

*(Written from reading the updater/installer code; not yet exercised on
hardware, so test an update on a Pi before gifting.)* Per-device settings
(location, watch list, API keys) are entered on the device itself through the
portal and never go into this repo.

## Other ideas (not done), by merge safety

- **Swap a binary file, no conflict risk:** hourly chime (`assets/ding.wav`),
  alert sounds (`traffic.mp3`, `airbus_autopilot.mp3`), aircraft icons
  (`assets/aircraft/icons/*.png`), portal favicon (`web/static/`).
- **Quiet-file edit:** accent colours in `display/round_touch/color_presets.py`.
- **Avoid:** `app.py`, `settings.py`, `index.html`, the boot disclaimer,
  `scripts/release.sh`, `VERSION`, license files/headers. The setup hotspot name
  (`AP_SSID_PREFIX` in `utilities/wifi_setup.py`) is functional, not cosmetic.
