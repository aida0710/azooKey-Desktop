"""Readable side-by-side column widths and the pointer route into a definition."""
from dataclasses import dataclass


# Keep sentences and dictionary prose readable without shrinking 18/24px text.
CANDIDATE_MINIMUM_WIDTH = 360
CANDIDATE_MAXIMUM_WIDTH = 480
DEFINITION_MINIMUM_WIDTH = 280
DEFINITION_PREFERRED_WIDTH = 320
DEFINITION_MAXIMUM_WIDTH = 360
COLUMN_GAP = 10
STANDARD_FONT_SIZE = 18


@dataclass(frozen=True)
class WordDefinitionColumns:
    candidate_width: int
    definition_width: int
    gap: int = COLUMN_GAP

    @property
    def width(self):
        return self.candidate_width + self.gap + self.definition_width


def word_definition_columns(*, candidate_width, font_size, available_width):
    candidate = min(CANDIDATE_MAXIMUM_WIDTH, max(CANDIDATE_MINIMUM_WIDTH, int(candidate_width)))
    definition = min(DEFINITION_MAXIMUM_WIDTH, max(
        DEFINITION_MINIMUM_WIDTH, round(DEFINITION_PREFERRED_WIDTH * font_size / STANDARD_FONT_SIZE)))
    candidate = min(candidate, max(CANDIDATE_MINIMUM_WIDTH,
                                   available_width - COLUMN_GAP - DEFINITION_MINIMUM_WIDTH))
    definition = min(definition, max(DEFINITION_MINIMUM_WIDTH, available_width - COLUMN_GAP - candidate))
    return WordDefinitionColumns(candidate, definition)


def pointer_in_rectangle(pointer, rectangle):
    x, y = pointer
    left, top, width, height = rectangle
    return left <= x < left + width and top <= y < top + height


def pointer_in_definition_corridor(*, pointer, row, definition):
    if pointer_in_rectangle(pointer, definition):
        return True
    x, y = pointer
    left, top, width, height = definition
    row_x, row_y, row_width, row_height = row
    row_right = row_x + row_width
    if not row_right <= x < left or left <= row_right:
        return False
    # A diagonal trip to the entry heading must not briefly restore selection.
    progress = (x - row_right) / (left - row_right)
    corridor_top = row_y + (top - row_y) * progress
    corridor_bottom = row_y + row_height + (top + height - row_y - row_height) * progress
    return corridor_top <= y < corridor_bottom
