from ad_agent.actions import ASSETS
from ad_agent.vision import dimensions, match_template


def test_packaged_screen_templates_are_valid_images() -> None:
    for filename in ("daily_chest_screen.png", "gifts_screen.png", "friends_screen.png", "mail_screen.png", "no_space_modal.png"):
        image = ASSETS / filename
        width, height = dimensions(image)
        assert width > 20
        assert height > 20
        assert match_template(image, image).score > 0.999
