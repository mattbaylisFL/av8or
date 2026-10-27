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
| Default radar center for a fresh install: SFO → Orlando International (MCO) | `config.h.example` (two lines; the installer copies it to the untracked `config.h`) |
| Updater, factory reset and repair script default to this repo instead of upstream, so `FLIGHTSCNR_GITHUB_REPO` is no longer needed in `/etc/flightscnr.env` and a factory reset re-clones *this* repo | `flightscnr/utilities/updater.py`, `flightscnr/setup/portal-factory-reset.sh`, `scripts/repair-ota.sh` (one line each) |
| Device seed: `/etc/flightscnr/seed.conf` + `/etc/flightscnr/seed/data/` pre-configure keys, location and portal settings and survive updates *and* factory reset | `flightscnr/av8or_seed.py` (new), 3 small hooks in `flightscnr/secrets_store.py`, template `av8or-seed.conf.example` |
| Guard tests for the above | `flightscnr/tests/test_av8or_seed.py` |

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
  what to do, assigned to the repo owner (which is what makes GitHub send the
  email). The issue closes itself once a later run succeeds.
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

### Releases for our own changes (`release-av8or.yml`)

The Pi only updates when the version string goes *up*, and the sync job only
tags upstream's `VERSION`. So a PR merged here would never reach a device on
its own ("Up to date" even though the commit changed). `release-av8or.yml`
closes that gap: every push to the default branch made by a person (a merged
PR, a direct push) gets a release of its own.

- Version = today's date with **iteration 10 or higher**: `2026.10.27.10`,
  `.11`, ... Upstream uses `.1`, `.2`, `.3` on its own same-day releases, so
  the two never collide and an upstream release on any later day still sorts
  higher.
- The workflow commits the new `VERSION`, tags it and publishes a GitHub
  release titled `av8or <version>`. Pushes by the sync bot and commits that are
  already tagged are skipped, so it never loops.
- When upstream and this repo both bumped `VERSION`, the sync merge resolves
  it by itself: upstream's value if it is newer, otherwise the next av8or
  iteration for today, so the merge still ships. `VERSION` is never a reported
  conflict.
- Same-day caveat: an upstream release later the same day (say `2026.10.27.2`
  after our `.10`) is merged and shipped as `2026.10.27.11`, not under
  upstream's number. Release notes still say which upstream version it carries.

To ship something without a code change, run **Release av8or** from the
Actions tab (workflow_dispatch).

### Rules that keep merges painless

1. **Never edit `VERSION` by hand.** The sync job and `release-av8or.yml` own it.
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

The updater, factory reset and repair script already default to this repo, so
no `/etc/flightscnr.env` edit is needed. Per-device settings (location, watch
list, API keys) are entered on the device through the portal and never go into
this repo.

## Pre-configuring a device

Everything the portal stores lives in `/var/lib/flightscnr` and is wiped by the
portal's **Factory reset**. To make a device come back pre-configured, put the
baseline under `/etc/flightscnr/`, which nothing in the app removes:

```sh
sudo install -d -m 755 /etc/flightscnr /etc/flightscnr/seed/data
sudo install -m 600 ~/FlightScnr_Pi/av8or-seed.conf.example /etc/flightscnr/seed.conf
sudo nano /etc/flightscnr/seed.conf          # API keys, HOME_LAT/HOME_LON
```

`seed.conf` is the lowest-priority key source (portal and config.h override it).
Once the device is set up the way you want through the portal, snapshot the
portal-managed files too; they are copied back in only when missing, i.e. on
first boot or after a reset:

```sh
sudo cp /var/lib/flightscnr/round_touch_settings.json /etc/flightscnr/seed/data/
sudo cp /var/lib/flightscnr/alert_prefs.json          /etc/flightscnr/seed/data/   # if present
```

A seeded `secrets.json` in `seed/data/` also works and is chmod 600 on copy.

## Other ideas (not done), by merge safety

- **Swap a binary file, no conflict risk:** hourly chime (`assets/ding.wav`),
  alert sounds (`traffic.mp3`, `airbus_autopilot.mp3`), aircraft icons
  (`assets/aircraft/icons/*.png`), portal favicon (`web/static/`).
- **Quiet-file edit:** accent colours in `display/round_touch/color_presets.py`.
- **Avoid:** `app.py`, `settings.py`, `index.html`, the boot disclaimer,
  `scripts/release.sh`, `VERSION`, license files/headers. The setup hotspot name
  (`AP_SSID_PREFIX` in `utilities/wifi_setup.py`) is functional, not cosmetic.
