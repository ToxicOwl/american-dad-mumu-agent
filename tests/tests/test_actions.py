from ad_agent.actions import SAFE_ACTIONS


def test_safe_actions_are_single_non_negative_taps() -> None:
    assert set(SAFE_ACTIONS) == {
        "daily-chest-open",
        "gifts-claim-all",
        "gifts-claim-all-despite-no-space",
        "gifts-confirm-no-space",
        "friends-claim-gifts",
    }
    for action in SAFE_ACTIONS.values():
        assert action.tap_x >= 0
        assert action.tap_y >= 0
        assert 0.9 <= action.min_score <= 1.0


def test_no_space_followup_is_only_defined_for_the_explicit_action() -> None:
    action = SAFE_ACTIONS["gifts-claim-all-despite-no-space"]
    assert action.followup_template_name == "no_space_modal.png"
    assert action.followup_tap_x == 748
    assert action.followup_tap_y == 478
    assert action.followup_min_score == 0.96
