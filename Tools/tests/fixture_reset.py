"""Record a fixture's public input-method reset without claiming IBus delivery."""


def observe_reset(event_log, *, api, field_index, reset):
    event_log.append("reset-requested", api=api, fieldIndex=field_index)
    reset()
    event_log.append("reset-returned", api=api, fieldIndex=field_index)
