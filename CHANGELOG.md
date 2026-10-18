# Changelog

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
