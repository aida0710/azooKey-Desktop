"""Complete one original native key call, including cancellation, at most once."""


class NativeKeyReply:
    def __init__(self, complete):
        self.complete = complete
        self.deferred = False
        self.completed = False

    def defer(self):
        self.deferred = True
        return self.finish

    def finish(self, consumed):
        if self.completed:
            return
        self.completed = True
        self.complete(consumed)
