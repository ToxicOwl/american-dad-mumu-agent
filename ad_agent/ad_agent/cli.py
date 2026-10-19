from __future__ import annotations

import argparse
from datetime import datetime
import json
from pathlib import Path
import sys

from .adb import AdbClient, AdbError
from .actions import ActionSafetyError, guarded_action, list_actions
from .config import AppConfig, ConfigError, load_config
from .monitor import monitor, observe
from .vision import VisionError, crop_template, dimensions


def _default_config_path() -> Path:
    return Path.cwd() / "config.json"


def _load(args: argparse.Namespace) -> AppConfig:
    return load_config(Path(args.config))


def _adb(config: AppConfig) -> AdbClient:
    return AdbClient(config.emulator.adb_path, config.emulator.device)


def command_doctor(args: argparse.Namespace) -> int:
    config = _load(args)
    adb = _adb(config)
    print(f"ADB path: {config.emulator.adb_path}")
    print(f"Target device: {config.emulator.device}")
    print(f"Safety mode: {config.safety.mode} (input disabled)")
    print(f"Connect: {adb.connect()}")
    print(f"Device state: {adb.state()}")
    print(f"Android: {adb.android_version()}")
    print(f"Model: {adb.model()}")

    target = config.root / "captures" / "doctor-latest.png"
    adb.screenshot(target)
    width, height = dimensions(target)
    expected = (config.emulator.expected_width, config.emulator.expected_height)
    status = "OK" if (width, height) == expected else "CHECK"
    print(f"Screenshot: {target}")
    print(f"Screenshot size: {width}x{height}; expected {expected[0]}x{expected[1]} [{status}]")
    return 0 if status == "OK" else 2


def command_capture(args: argparse.Namespace) -> int:
    config = _load(args)
    adb = _adb(config)
    label = args.label.replace(" ", "-")
    now = datetime.now().strftime("%Y%m%d-%H%M%S")
    target = config.root / "captures" / f"{now}-{label}.png"
    adb.screenshot(target)
    width, height = dimensions(target)
    print(f"Saved {target}")
    print(f"Size: {width}x{height}")
    return 0


def command_calibrate(args: argparse.Namespace) -> int:
    config = _load(args)
    adb = _adb(config)
    output = config.root / "calibration" / "templates" / f"{args.name}.png"
    temporary = config.root / "captures" / "calibration-latest.png"
    adb.screenshot(temporary)
    crop_template(temporary, output, args.x, args.y, args.width, args.height)

    config_path = Path(args.config)
    raw = json.loads(config_path.read_text(encoding="utf-8"))
    raw.setdefault("templates", {})[args.name] = {
        "path": str(output.relative_to(config.root)).replace("\\", "/"),
        "min_score": args.min_score,
    }
    config_path.write_text(json.dumps(raw, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Saved template: {output}")
    print(f"Updated profile: {config_path}")
    print("Tip: use a static, distinctive part of the current screen, not an account name, resource counter, timer, or chat message.")
    return 0


def command_once(args: argparse.Namespace) -> int:
    config = _load(args)
    item = observe(config, _adb(config))
    print(f"{item.width}x{item.height} — {item.screen}")
    if item.score is not None:
        print(f"Template score: {item.score:.3f}")
    print(f"Screenshot: {item.screenshot}")
    return 0


def command_monitor(args: argparse.Namespace) -> int:
    config = _load(args)
    return monitor(config, _adb(config), args.count)


def command_actions(args: argparse.Namespace) -> int:
    print("Available guarded actions — each has a fixed, explicitly checked tap sequence and never spends diamonds:")
    for action in list_actions():
        print(f"  {action.key}: {action.description}")
    return 0


def command_action(args: argparse.Namespace) -> int:
    if args.dry_run and args.confirm:
        raise ActionSafetyError("Use either --dry-run or --confirm, not both.")
    if not args.dry_run and not args.confirm:
        raise ActionSafetyError("Choose --dry-run to simulate, or --confirm to authorize one tap.")
    config = _load(args)
    return guarded_action(config, _adb(config), args.action_key, dry_run=args.dry_run, confirm=args.confirm)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="ad-agent",
        description="Local MuMu monitor, calibration, and guarded-action agent.",
    )
    parser.add_argument("--config", default=str(_default_config_path()), help="Path to config.json (default: ./config.json)")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("doctor", help="Verify ADB, MuMu connection, and screenshot dimensions").set_defaults(func=command_doctor)

    capture = subparsers.add_parser("capture", help="Save a timestamped screenshot from MuMu")
    capture.add_argument("label", help="Short name, e.g. base or mail")
    capture.set_defaults(func=command_capture)

    calibrate = subparsers.add_parser("calibrate-template", help="Capture then crop a reusable recognition template")
    calibrate.add_argument("name", help="Template name, e.g. main_base")
    calibrate.add_argument("x", type=int, help="Crop left coordinate")
    calibrate.add_argument("y", type=int, help="Crop top coordinate")
    calibrate.add_argument("width", type=int, help="Crop width")
    calibrate.add_argument("height", type=int, help="Crop height")
    calibrate.add_argument("--min-score", type=float, default=0.88, help="Recognition threshold 0.0–1.0; default 0.88")
    calibrate.set_defaults(func=command_calibrate)

    subparsers.add_parser("once", help="Take one safe observation and report detected screen").set_defaults(func=command_once)

    monitor_parser = subparsers.add_parser("monitor", help="Monitor safely; never taps the emulator")
    monitor_parser.add_argument("--count", type=int, default=None, help="Stop after this many successful observations")
    monitor_parser.set_defaults(func=command_monitor)

    subparsers.add_parser("actions", help="List the available guarded one-tap actions").set_defaults(func=command_actions)
    action_parser = subparsers.add_parser("action", help="Run one guarded action only after screen recognition")
    action_parser.add_argument("action_key", help="Action key shown by the 'actions' command")
    action_parser.add_argument("--dry-run", action="store_true", help="Check the screen and print the planned tap; send no input")
    action_parser.add_argument("--confirm", action="store_true", help="Authorize one tap after all guards pass")
    action_parser.set_defaults(func=command_action)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except (ConfigError, AdbError, VisionError, ActionSafetyError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
