"""A bounded background dictionary queue, with independent visibility epochs per consumer."""
from collections import OrderedDict
from threading import Condition, Thread

from .word_definition_provider import WordDefinitionProvider

# Cache a few candidate pages without retaining an unbounded history of typed words.
MAXIMUM_CACHED_WORDS = 128


class WordDefinitionWorker:
    def __init__(self, *, provider=None, dispatch):
        self.provider = provider or WordDefinitionProvider()
        self.dispatch = dispatch
        self.condition = Condition()
        self.cache = OrderedDict()
        self.pending = None
        self.thread = None
        self.closed = False

    def request(self, target, completed):
        key = (target.word, target.reading)
        with self.condition:
            if self.closed:
                self.dispatch(lambda: completed({"status": "stale", "word": key[0], "reading": key[1]}))
                return
            if self.pending is not None:
                retired_key, retired_completed = self.pending
                self.pending = None
                self.dispatch(lambda: retired_completed({"status": "stale", "word": retired_key[0], "reading": retired_key[1]}))
            if key in self.cache:
                response = self.cache[key]
                self.cache.move_to_end(key)
                self.dispatch(lambda: completed(response))
                return
            # At most the newest request waits behind the currently running query.
            self.pending = (key, completed)
            if self.thread is None:
                self.thread = Thread(target=self.run, name="azookey-word-definitions", daemon=True)
                self.thread.start()
            self.condition.notify()

    def run(self):
        while True:
            with self.condition:
                self.condition.wait_for(lambda: self.closed or self.pending is not None)
                if self.closed:
                    return
                key, completed = self.pending
                self.pending = None
            try:
                response = self.provider.lookup(*key)
            except Exception:
                # Dictionary failure must never stop the input engine's main loop.
                response = {"status": "error", "word": key[0], "reading": key[1], "senses": []}
            with self.condition:
                if self.closed:
                    self.dispatch(lambda completed=completed, key=key: completed({"status": "stale", "word": key[0], "reading": key[1]}))
                    return
                if response["status"] in ("found", "notFound"):
                    self.cache[key] = response
                    self.cache.move_to_end(key)
                    while len(self.cache) > MAXIMUM_CACHED_WORDS:
                        self.cache.popitem(last=False)
            self.dispatch(lambda response=response, completed=completed: completed(response))

    def close(self):
        with self.condition:
            self.closed = True
            if self.pending is not None:
                key, completed = self.pending
                self.dispatch(lambda: completed({"status": "stale", "word": key[0], "reading": key[1]}))
            self.pending = None
            self.condition.notify()


class WordDefinitionLookup:
    def __init__(self, worker, changed):
        self.worker = worker
        self.changed = changed
        self.target = None
        self.result = None
        self.epoch = object()

    def update(self, target):
        if target == self.target:
            return
        self.invalidate()
        self.target = target
        if target is None:
            self.changed(None)
            return
        epoch = self.epoch
        self.result = {"status": "loading", "word": target.word, "reading": target.reading, "senses": []}
        self.changed(self.result)
        self.worker.request(target, lambda response: self.finish(epoch, response))

    def finish(self, epoch, response):
        if epoch is self.epoch and self.target is not None and response.get("status") != "stale":
            self.result = response
            self.changed(response)

    def invalidate(self):
        self.epoch = object()
        self.target = None
        self.result = None


_shared_worker = None


def word_definition_worker():
    global _shared_worker
    if _shared_worker is None:
        from gi.repository import GLib

        def dispatch(callback):
            def deliver():
                callback()
                return GLib.SOURCE_REMOVE
            GLib.idle_add(deliver)

        _shared_worker = WordDefinitionWorker(dispatch=dispatch)
    return _shared_worker
