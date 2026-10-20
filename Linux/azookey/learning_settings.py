"""Labels follow the converter's update/use policies, not input/output text."""
from .i18n import text as message


def learning_choices():
    return [(mode, message(f"learning.mode.{mode}"))
            for mode in ("inputAndOutput", "onlyOutput", "nothing")]
