from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
import time

from .adb import AdbClient
from .config import AppConfig
from .logging_utils import log_event
from .vision import dimensions, match_template


@dataclass(frozen=True)
class SafeAction:
    key: str
    label: str
    template_name: str
    min_score: float
    tap_x: int
    tap_y: int
    description: str
    followup_template_name: str | None = None
    followup_min_score: float | None = None
    followup_tap_x: int | None = None
    followup_tap_y: int | None = None


ASSETS = Path(__file__).with_name("assets")

# Each action is a single claim/open tap. None uses diamonds, watches ads,
# sends chat, navigates, dismisses prompts, repeats, or interacts with combat.
SAFE_ACTIONS: dict[str, SafeAction] = {
    "daily-chest-open": SafeAction(
        key="daily-chest-open",
        label="Open Daily Chest",
        template_name="daily_chest_screen.png",
        min_score=0.94,
        tap_x=428,
        tap_y=572,
        description="Opens only the green OPEN button of the Daily Chest screen.",
    ),
    "gifts-claim-all": SafeAction(
        key="gifts-claim-all",
        label="Claim all received gifts",
        template_name="gifts_screen.png",
        min_score=0.94,
        tap_x=899,
        tap_y=595,
        description="Presses only CLAIM ALL in the received-gifts window.",
    ),
    "gifts-claim-all-despite-no-space": SafeAction(
        key="gifts-claim-all-despite-no-space",
        label="Claim all gifts despite no storage space",
        template_name="gifts_screen.png",
        min_score=0.94,
        tap_x=899,
        tap_y=595,
        description="Presses CLAIM ALL, then presses CLAIM only if the exact No space dialog is recognized.",
        followup_template_name="no_space_modal.png",
        followup_min_score=0.96,
        followup_tap_x=748,
        followup_tap_y=478,
    ),
    "gifts-confirm-no-space": SafeAction(
        key="gifts-confirm-no-space",
        label="Confirm current No space gift dialog",
        template_name="no_space_modal.png",
        min_score=0.96,
        tap_x=748,
        tap_y=478,
        description="Presses only CLAIM in the already visible, exactly recognized No space dialog.",
    ),
    "friends-claim-gifts": SafeAction(
        key="friends-claim-gifts",
        label="Claim friend gifts",
        template_name="friends_screen.png",
        min_score=0.94,
        tap_x=1015,
        tap_y=180,
        description="Presses only CLAIM GIFTS in the Friends tab of Leaderboards.",
    ),
}


class ActionSafetyError(RuntimeError):
    """Raised when a requested action does not pass all safety guards."""


def _timestamp() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")


def list_actions() -> list[SafeAction]:
    return list(SAFE_ACTIONS.values())


def guarded_action(
    config: AppConfig,
    adb: AdbClient,
    action_key: str,
    *,
    dry_run: bool,
    confirm: bool,
) -> int:
    try:
        action = SAFE_ACTIONS[action_key]
    except KeyError as exc:
        available = ", ".join(SAFE_ACTIONS)
        raise ActionSafetyError(f"Unknown action '{action_key}'. Available actions: {available}.") from exc

    if not dry_run:
        if not config.safety.forbid_diamond_spend:
            raise ActionSafetyError("Blocked: safety.forbid_diamond_spend must remain true for guarded actions.")
        if config.safety.mode != "actions":
            raise ActionSafetyError(
                "Blocked: config.json has safety.mode 'monitor'. Set it to 'actions' only after a successful dry run."
            )
        if not confirm:
            raise ActionSafetyError("Blocked: re-run with --confirm to authorize exactly one guarded tap.")

    template = ASSETS / action.template_name
    if not template.is_file():
        raise ActionSafetyError(f"Required built-in screen template is missing: {template.name}")

    before = config.root / "captures" / f"{_timestamp()}-before-{action.key}.png"
    adb.screenshot(before)
    width, height = dimensions(before)
    expected = (config.emulator.expected_width, config.emulator.expected_height)
    if (width, height) != expected:
        raise ActionSafetyError(
            f"Blocked: screenshot is {width}x{height}, expected {expected[0]}x{expected[1]}. No tap was sent."
        )

    result = match_template(before, template)
    if result.score < action.min_score:
        raise ActionSafetyError(
            f"Blocked: required screen was not recognized (score {result.score:.3f}; minimum {action.min_score:.3f}). No tap was sent."
        )

    log_event(
        config.root / "logs" / "agent.jsonl",
        "action_check",
        action=action.key,
        mode=("dry_run" if dry_run else "actions"),
        template_score=result.score,
        screenshot=str(before.relative_to(config.root)),
    )
    if dry_run:
        print(f"DRY RUN PASSED: {action.label}")
        print(f"Screen recognition: {result.score:.3f} (minimum {action.min_score:.3f})")
        print(f"Would tap exactly once at ({action.tap_x}, {action.tap_y}): {action.description}")
        if action.followup_template_name:
            print(
                "A second tap would be permitted only if the exact 'No space' dialog appears "
                f"with a recognition score of at least {action.followup_min_score:.3f}."
            )
        print("No tap was sent.")
        return 0

    adb.tap(action.tap_x, action.tap_y)
    time.sleep(1.0)
    mid = config.root / "captures" / f"{_timestamp()}-after-first-tap-{action.key}.png"
    adb.screenshot(mid)

    if action.followup_template_name:
        followup_template = ASSETS / action.followup_template_name
        if not followup_template.is_file():
            raise ActionSafetyError(f"Required follow-up template is missing: {followup_template.name}")
        if action.followup_tap_x is None or action.followup_tap_y is None or action.followup_min_score is None:
            raise ActionSafetyError("Conditional action definition is incomplete. No second tap was sent.")
        followup = match_template(mid, followup_template)
        if followup.score < float(action.followup_min_score):
            log_event(
                config.root / "logs" / "agent.jsonl",
                "guarded_action_followup_blocked",
                action=action.key,
                template_score=followup.score,
                required_score=action.followup_min_score,
                before=str(before.relative_to(config.root)),
                after_first_tap=str(mid.relative_to(config.root)),
            )
            print("FIRST TAP SENT. The expected No space dialog was not recognized.")
            print("SAFETY STOP: no second tap was sent.")
            print(f"Evidence: {before} and {mid}")
            return 0

        adb.tap(int(action.followup_tap_x), int(action.followup_tap_y))
        time.sleep(1.0)
        after = config.root / "captures" / f"{_timestamp()}-after-second-tap-{action.key}.png"
        adb.screenshot(after)
        log_event(
            config.root / "logs" / "agent.jsonl",
            "guarded_action_followup_tap",
            action=action.key,
            first_tap={"x": action.tap_x, "y": action.tap_y},
            followup_template_score=followup.score,
            second_tap={"x": action.followup_tap_x, "y": action.followup_tap_y},
            before=str(before.relative_to(config.root)),
            after_first_tap=str(mid.relative_to(config.root)),
            after_second_tap=str(after.relative_to(config.root)),
        )
        print(f"TWO GUARDED TAPS SENT: {action.label}")
        print(f"Evidence: {before}, {mid}, and {after}")
        return 0

    log_event(
        config.root / "logs" / "agent.jsonl",
        "guarded_action_tap",
        action=action.key,
        tap={"x": action.tap_x, "y": action.tap_y},
        template_score=result.score,
        before=str(before.relative_to(config.root)),
        after=str(mid.relative_to(config.root)),
    )
    print(f"ONE TAP SENT: {action.label}")
    print(f"Evidence: {before} and {mid}")
    return 0
