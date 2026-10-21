"""Supported viewport sizes for the compact conversion candidate list."""

# Seven rows add choices without making the ordinary list taller than before.
DEFAULT_VISIBLE_CANDIDATE_ROWS = 7
VISIBLE_CANDIDATE_ROWS = (5, 7, 9)


def visible_candidate_rows(value):
    """Use the default for missing or malformed renderer snapshots."""
    return value if type(value) is int and value in VISIBLE_CANDIDATE_ROWS else DEFAULT_VISIBLE_CANDIDATE_ROWS
