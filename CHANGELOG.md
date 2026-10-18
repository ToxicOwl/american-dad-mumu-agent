# Changelog

## 1.6.0 — 18 October 2026

- Redesigned the Windows HUD with a modern command-center layout, clearer action sections and improved button states.
- Added the Roger header visual plus extracted transparent gold, silver and bronze trophy assets for the podium counters.

## 1.5.0 — 18 October 2026

- Added the guarded Invasion route: Map event icon → SHOW → OCR-located random `Invasion!` UFO → one selected `BATTLE XN` or `ATTACK` action.
- Added visual fallback validation for the `BATTLE XN` / `ATTACK` layout when Windows OCR misses small labels; it explicitly rejects the optional-power popup.
- The optional `EQUIP POWERS FOR BATTLE` popup uses only its green `ATTACK` button. The `ADD` button remains blocked.
- Intermediate battle and `VICTORY` screens are observed only. At the complete end, the agent verifies and presses centered `HOME`, waits for `INVASION REPELLED`, then verifies and presses centered `OK` once.
- Added Invasion calibration capture controls and both **Invasion safe test** and **Run Invasion once** controls in the Windows application.
- Added `-FinalizeCurrent` for a guarded one-time HOME/OK completion from an already open verified final screen.

## 1.4.0 — 18 October 2026

- Added a public GitHub Releases distribution channel and a confirmed in-app updater.
- The Arena application checks stable release metadata on startup and offers a manual **Check updates** button.
- Updates preserve `config.json`, the local Python environment, captures and logs; a local backup is created before program files are replaced.
- Added automatic ADB reconnect support before Food and Arena capture flows.
- Added Food-menu fallback recognition for notifications that temporarily cover OCR text.
- Added the persistent Food/Arena HUD with resettable position counters.

## 0.2.2 — 17 October 2026

- Added `gifts-confirm-no-space`, which confirms the already visible `No space` dialog only after strict visual recognition.

## 0.2.1 — 17 October 2026

- Added `gifts-claim-all-despite-no-space`: a two-tap sequence that taps `CLAIM` only after recognizing the exact `No space` dialog at a strict score threshold.
- Added evidence capture before the first tap, after the first tap, and after the conditional second tap.

## 0.2.0 — 17 October 2026

- Added packaged recognition templates calibrated from the current MuMu screenshots.
- Added guarded one-tap actions: Daily Chest Open, received Gifts Claim All, and Friends Claim Gifts.
- Added explicit `--dry-run` and `--confirm` gates.
- Added mandatory 1280×720, screen-template, and diamond-spend safety guards.
- Saved before/after evidence screenshots and JSONL log events for every authorized tap.

## 0.1.1 — 17 October 2026

- Replaced YAML with standard-library JSON to support Python 3.15 without Microsoft C++ Build Tools.
- Made the installer stop if a package installation fails.

## 0.1.0 — 17 October 2026

- Initial monitor-and-calibration release.
