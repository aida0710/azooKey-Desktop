"""Speak Core's selection announcement without moving AT focus from the document."""


class CandidateAnnouncements:
    def __init__(self, announce):
        self.announce = announce
        self.identity = None

    def update(self, snapshot):
        announcement = (snapshot.get("candidateDisplay") or {}).get("announcement")
        if announcement is None:
            self.reset()
            return
        # Redrawing the same reply or changing only scores repeats nothing.
        identity = (snapshot.get("contextId"), announcement)
        if identity == self.identity:
            return
        self.identity = identity
        self.announce(announcement)

    def reset(self):
        self.identity = None
