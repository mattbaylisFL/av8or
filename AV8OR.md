# av8or: a customized FlightScnr Pi

A private, customized copy of [FlightScnr Pi](https://github.com/yashmulgaonkar/FlightScnr_Pi)
by Yash Mulgaonkar, built as a gift. It is **not a GitHub fork** (so it can be
private) but keeps upstream's full git history, which is what makes automatic
merging possible.

> **License:** upstream is CC BY-NC-SA 4.0. Keep `LICENSE`, `NOTICE`, the README
> license section and every file header intact, credit the original project, say
> that changes were made, and keep it non-commercial (a gift is fine). Don't
> imply Yash endorses this edition.

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
  gate compares against the pre-merge baseline and only blocks *new* failures.
- **Upstream workflow changes are never merged.** Our workflows always win.
  Held-back changes are listed in the release notes.

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

## One-time setup

1. **Make the default branch `main`.** The Pi's installer hard-codes
   `origin/main`. If the default branch has another name, rename it in
   *Settings → General → Default branch* (GitHub updates workflows/branches).
2. *Settings → Actions → General → Workflow permissions:* leave the default;
   the workflow requests the permissions it needs per job.
3. Run **Actions → Sync upstream → Run workflow** once and confirm it passes.

## Putting it on the friend's Pi (private repo!)

The Pi must be able to read this repo without a login prompt. **Use an HTTPS
token, not an SSH deploy key**: the portal's *Clean install* button runs
`git clone https://github.com/<repo>.git` and an SSH key won't be used.

> ⚠️ *Clean install* **wipes settings and the checkout first, then clones.** With
> no stored credential it would leave the device empty. Verify the credential
> (below) before ever pressing it.

1. Create a **fine-grained personal access token** limited to this repository,
   permission **Contents: Read-only**. It expires (max 1 year): put a reminder
   in your calendar, because an expired token makes updates fail quietly.
2. On the Pi, as the user that owns the checkout:
   ```sh
   git config --global credential.helper store
   printf 'https://x-access-token:%s@github.com\n' "$TOKEN" > ~/.git-credentials
   chmod 600 ~/.git-credentials
   git clone https://github.com/mattbaylisFL/av8or.git ~/FlightScnr_Pi
   cd ~/FlightScnr_Pi && sudo ./install-pi.sh
   ```
3. Point the updater at this repo: add to `/etc/flightscnr.env`
   ```
   FLIGHTSCNR_GITHUB_REPO=mattbaylisFL/av8or
   GITHUB_TOKEN=<same token>
   ```
4. Verify: `git ls-remote https://github.com/mattbaylisFL/av8or.git` works with
   no prompt, then use the portal's **Updates** section to check for updates.

*(Written from reading the updater/installer code; not yet exercised on
hardware, so test an update on your own Pi before gifting.)*

## Customization map

Ordered by merge safety. Churn = upstream commits touching the file since 2026-07-01.

### 1. Swap a binary file (zero conflict risk)

| What | Files | Churn |
|---|---|---|
| **Boot splash / About screen** | `flightscnr/assets/boot/splash.png`, `brand_plate.png`, `about.png`, `monogram.png` (720×720). The version number is drawn live over `brand_plate.png` at the position in `brand_layout.json` | 1 |
| **Hourly chime** | `assets/ding.wav` / `ding.mp3` / `audio/hourly_chime.wav` (first one found wins, see `hourly_chime.py`) | 1 |
| **Alert sounds** | `assets/traffic.mp3` (tracked/alert), `airbus_autopilot.mp3` (military), `earthquake_voice.mp3` | 1 |
| **Split-flap board sounds** | `assets/flap_click.wav`, `flap_transition.mp3` | low |
| **Aircraft icons** | `assets/aircraft/icons/*.png` (21 icons). Leave `aircraft-icons.json` alone (5 churn) | 1 |
| **Portal favicon / icon** | `web/static/favicon.ico`, `radar_icon.png` | 0 |

Splash note: keep the "FlightScnr Pi by Yash Mulgaonkar" credit. The contact
email on the stock plate is his; replace *that line* with something like
"Custom edition for <name>" so people don't email him about a modified build.

### 2. Add a new file (can't conflict)

- **Gift preset**: set up the Pi how you want it (home location, favourite
  locations, **watch list** of tail numbers/callsigns he cares about, colours,
  clock style, chime on), then export from the portal (*Settings backup*,
  `utilities/settings_backup.py`). Commit it as `av8or/preset.config` and he
  restores it in one tap. **Delete the `secrets` section first**; it holds API keys.
- **Own lofi playlist**: set `LOFI_PACK_URL` (see `.env.example`) or drop MP3s
  into `/var/lib/flightscnr/lofi/` on the device; they join the playlist.
- **Reworded UI text via a language pack** (`flightscnr/i18n/locales/<tag>/`):
  a pack can override only a few strings and falls back to English for the
  rest. Packs targeting a *newer* catalog revision than the runtime are skipped,
  so pin `source_catalog_revision` at the current value. Not yet tried here.

### 3. Small edits in quiet files (rare, easy conflicts)

- **Accent colours:** `display/round_touch/color_presets.py` (`THEMES`,
  `DEFAULT_CUSTOM_RGB`, default tag colours), e.g. his team's colours (churn 6).
- **Clock wordmark:** the literal `"FLIGHTSCNRPI"` is drawn in
  `screens/flieger_clock.py:309` and `screens/analog_clock.py:304`; make it his
  name or callsign (churn 5 and low).

### 4. Avoid

- `app.py`, `settings.py`, `web/templates/index.html`: constant churn.
- Changing default values inside `settings.py`: use the preset instead.
- The boot disclaimer, `scripts/release.sh`, `VERSION`, license files/headers.
