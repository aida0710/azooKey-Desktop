"""Test replacement ownership through a private, real IBus daemon and Core."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import time
import traceback

from ibus_native_field import IBus, wait_for
from reading_native_trace import CoreTrace
from reading_reconversion_native_field import ReadingReconversionField
from reading_reconversion_native_audit import audit_case
from gi.repository import Gio, GLib
from native_ibus_observer import observe_ibus


ORIGINAL = "前ニホンゴ後"
# A short series distinguishes repeated Engine replies from one cached daemon reply.
HEARTBEAT_COUNT = 8
# This checks main-loop responsiveness, not widget latency under a two-second load.
ENGINE_REPLY_SECONDS = 0.1
ENGINE_CALL_TIMEOUT_MILLISECONDS = 3000
CONTROL_SHIFT = int(IBus.ModifierType.CONTROL_MASK | IBus.ModifierType.SHIFT_MASK)


def engine_heartbeat(connection):
    started = time.monotonic()
    connection.call_sync("org.azookey.Tree", "/org/azookey/Tree", "org.azookey.Tree", "RendererStatus",
                         None, GLib.VariantType.new("(b)"), Gio.DBusCallFlags.NONE, ENGINE_CALL_TIMEOUT_MILLISECONDS, None)
    elapsed = time.monotonic() - started
    assert elapsed < ENGINE_REPLY_SECONDS, f"engine main loop waited {elapsed:.6f}s"
    return elapsed


class ReconversionTrial:
    def __init__(self, directory):
        IBus.init()
        self.bus = IBus.Bus()
        assert self.bus.is_connected()
        self.connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.directory = directory
        self.trace = CoreTrace(directory)
        self.fields = []
        self.observations = {}

    def field(self, name, *, warm=True, client_name=None):
        field = ReadingReconversionField(self.bus, client_name or "reading-reconversion-" + name, trace=self.trace)
        self.fields.append(field)
        if warm:
            field.warm()
        else:
            field.focus()
        field.set_document(ORIGINAL, cursor=5, anchor=1)
        return field

    def requests(self, operation, since):
        return self.trace.records(role="reading", operation=operation, phase="request", since=since)

    def responses(self, operation, since):
        return self.trace.records(role="reading", operation=operation, phase="response", since=since)

    def formal_inputs(self, since):
        return [row for row in self.trace.records(role="reading", phase="response", since=since)
                if row["response"].get("kind") == "input"]

    def wait_prepared(self, since):
        wait_for(lambda: any("reconversionReadingRequest" in row["response"]
                             for row in self.responses("reconvert", since)),
                 "the actual reader did not request candidate-owned reading resolution")

    def wait_replies(self, field, tokens):
        wait_for(lambda: all(any(reply["token"] == token for reply in field.replies) for token in tokens),
                 "the original start or buffered key did not finish")
        field.assert_replies(tokens)

    def known(self):
        field = self.field("known")
        field.hold_ack = True
        began = time.monotonic()
        with self.trace.stopped("candidate", field.context_id):
            start = field.send(ord("r"), CONTROL_SHIFT)
            enter = field.send(IBus.KEY_Return)
            self.wait_prepared(began)
            self.observations["engineHeartbeatSeconds"] = [engine_heartbeat(self.connection)
                                                           for _ in range(HEARTBEAT_COUNT)]
            assert not [row for row in field.replies if row["token"] in (start, enter)]
            assert field.document == ORIGINAL and not field.deletions and not self.formal_inputs(began)
        wait_for(lambda: len(field.deletions) == 1 and any(row["token"] == start for row in field.replies),
                 "the real dictionary reading did not prepare one deletion")
        assert field.document == "前後" and field.preedit == "" and not field.commits
        assert not self.requests("confirm-reconversion", began) and not self.formal_inputs(began)
        assert not any(row["token"] == enter for row in field.replies)
        acknowledgement = time.monotonic()
        field.surrounding(acknowledge=True)
        self.wait_replies(field, (start, enter))
        wait_for(lambda: field.commits == ["にほんご"] and field.preedit == "", "restored reading did not commit once")
        assert field.document == "前にほんご後"
        confirms = self.requests("confirm-reconversion", began)
        assert len(confirms) == 1 and confirms[0]["monotonic"] >= acknowledgement
        self.observations.update(inputBeforeDeletionAck=0, confirmAfterAck=1,
                                 deletion=field.deletions, originalTokens=[start, enter])

    def reject_pending(self, reason):
        field = self.field(reason)
        began = time.monotonic()
        other = None
        with self.trace.stopped("candidate", field.context_id):
            start = field.send(ord("r"), CONTROL_SHIFT)
            enter = field.send(IBus.KEY_Return)
            self.wait_prepared(began)
            if reason == "focus":
                field.context.focus_out()
                other = self.field("other", warm=False)
                other.set_document("別欄", cursor=2, anchor=2)
                self.wait_replies(field, (start, enter))
            elif reason == "private":
                field.context.set_content_type(IBus.InputPurpose.FREE_FORM, IBus.InputHints.PRIVATE)
                self.wait_replies(field, (start, enter))
                wait_for(lambda: any(row["request"].get("surroundings", {}).get("privateInput") is True
                                     for row in self.responses("focus-in", began)),
                         "PRIVATE did not reach the actual reader")
            else:
                field.set_document("別ニホンゴ後", cursor=5, anchor=1)
            assert not field.deletions and not field.commits
        self.wait_replies(field, (start, enter))
        # A further ordinary public input is the next actual reader/IBus ACK.
        destination = other or field
        destination.key(ord("a"))
        destination.key(IBus.KEY_Escape)
        assert not field.deletions and not field.commits and not self.requests("confirm-reconversion", began)
        assert field.document == ("別ニホンゴ後" if reason == "changed" else ORIGINAL)
        if other:
            assert other.document == "別欄" and not other.commits and not other.forwarded
        self.observations.update(rejection=reason, deleted=0, originalTokens=[start, enter],
                                 otherField=other.document if other else None)

    def private_start(self):
        field = self.field("private-start")
        began = time.monotonic()
        field.context.set_content_type(IBus.InputPurpose.FREE_FORM, IBus.InputHints.PRIVATE)
        wait_for(lambda: any(row["request"].get("surroundings", {}).get("privateInput") is True
                             for row in self.responses("focus-in", began)), "PRIVATE authority was not acknowledged")
        started = time.monotonic()
        token = field.key(ord("r"), CONTROL_SHIFT)
        field.assert_replies((token,))
        assert not self.requests("reconvert", started)
        assert not field.deletions and field.document == ORIGINAL and not field.commits
        self.observations.update(private=True, readerReconvertRequests=0, deleted=0)

    def undo(self):
        field = self.field("undo")
        field.set_document("前後", cursor=1, anchor=1)
        for character in "nihongo":
            field.key(ord(character))
        field.key(IBus.KEY_Return)
        wait_for(lambda: field.commits == ["にほんご"] and field.preedit == "", "initial real commit was not acknowledged")
        assert field.document == "前にほんご後"
        field.hold_ack = True
        began = time.monotonic()
        with self.trace.stopped("candidate", field.context_id):
            start = field.send(IBus.KEY_BackSpace, CONTROL_SHIFT)
            enter = field.send(IBus.KEY_Return)
            wait_for(lambda: len(field.deletions) == 1, "undo depended on the stopped candidate")
            assert field.document == "前後" and field.preedit == "" and not self.formal_inputs(began)
            field.surrounding(acknowledge=True)
            self.wait_replies(field, (start, enter))
            wait_for(lambda: field.commits == ["にほんご", "にほんご"] and field.preedit == "", "undo restored reading did not commit")
            assert field.document == "前にほんご後"
            assert not self.trace.records(role="candidate", operation="resolve-reconversion-reading", since=began)
        self.observations.update(candidateStoppedDuringUndo=True, inputBeforeDeletionAck=0,
                                 undoDelete=field.deletions, commits=field.commits)

    def unknown(self):
        field = self.field("unknown")
        field.set_document("前🧪後", cursor=2, anchor=1)
        began = time.monotonic()
        start = field.key(ord("r"), CONTROL_SHIFT)
        wait_for(lambda: any(row["response"].get("reconversionReading") == ""
                             for row in self.responses("resolve-reconversion", began)), "unknown reading did not remain local")
        letter = field.key(ord("a"))
        wait_for(lambda: any(row["response"].get("reconversionReading") == "あ"
                             for row in self.responses("reconversion-reading", began)), "local reading did not accept the real key")
        escape = field.key(IBus.KEY_Escape)
        field.assert_replies((start, letter, escape))
        assert field.document == "前🧪後" and not field.deletions and not field.commits and not self.formal_inputs(began)
        self.observations.update(unknownReadingCancelled=True, inputEffects=0, deleted=0)

    @contextmanager
    def pending_confirmation(self, field, began):
        field.hold_ack = True
        start = field.send(ord("r"), CONTROL_SHIFT)
        wait_for(lambda: len(field.deletions) == 1, "selection deletion was not prepared")
        with self.trace.stopped("reading", field.context_id) as worker:
            field.surrounding(acknowledge=True)
            wait_for(lambda: field.preedit == "ニホンゴ" and self.requests("confirm-reconversion", began),
                     "deletion ACK did not establish original-only recovery preedit")
            yield start, worker

    def confirm_focus(self):
        field = self.field("confirm-focus")
        began = time.monotonic()
        with self.pending_confirmation(field, began) as (start, worker):
            enter = field.send(IBus.KEY_Return)
            field.context.focus_out()
            other = self.field("confirm-other", warm=False)
            other.set_document("別欄", cursor=2, anchor=2)
            self.wait_replies(field, (start, enter))
            wait_for(lambda: field.commits == ["ニホンゴ"], "IBus did not keep deleted original in its old field once")
            assert field.document == ORIGINAL and not other.commits
        other.key(ord("a"))
        other.key(IBus.KEY_Return)
        wait_for(lambda: other.commits == ["あ"], "next field did not accept only its own reading")
        assert field.commits == ["ニホンゴ"] and field.document == ORIGINAL
        assert other.document == "別欄あ"
        canceled = self.responses("focus-out", began)
        assert all(row["response"].get("snapshot", {}).get("commits", []) == [] for row in canceled)
        assert canceled or worker["resumeDisposition"] == "process-retired-before-resume"
        self.observations.update(oldFieldOriginalCommits=1, nextFieldCommits=other.commits,
                                 formalCancellationCommits=0, oldWorker=worker["resumeDisposition"],
                                 lateConfirmObserved=bool(self.responses("confirm-reconversion", began)))

    def confirm_reset(self):
        field = self.field("confirm-reset")
        began = time.monotonic()
        with self.pending_confirmation(field, began) as (start, worker):
            enter = field.send(IBus.KEY_Return)
            field.context.reset()
            self.wait_replies(field, (start, enter))
            wait_for(lambda: field.commits == ["ニホンゴ"], "IBus reset did not preserve the original once")
            assert field.document == ORIGINAL
        assert worker["resumeDisposition"] == "resumed-same-process"
        field.key(ord("a"))
        field.key(IBus.KEY_Return)
        wait_for(lambda: field.commits == ["ニホンゴ", "あ"], "input after reset was not committed once")
        assert field.document == "前ニホンゴあ後"
        confirms = self.responses("confirm-reconversion", began)
        resets = self.responses("reset", began)
        assert len(confirms) == 1 and resets
        assert all(row["response"].get("snapshot", {}).get("commits", []) == [] for row in resets)
        self.observations.update(originalCommits=1, newCommits=["あ"], formalCancellationCommits=0,
                                 oldWorker=worker["resumeDisposition"], lateConfirmObserved=True)

    def qt_confirm_reset(self):
        field = self.field("qt-confirm-reset", client_name="QIBusInputContext")
        began = time.monotonic()
        with self.pending_confirmation(field, began) as (start, worker):
            enter = field.send(IBus.KEY_Return)
            # Model only Qt's local preedit submission followed by public Reset.
            # This is an IBus protocol client, not a claim about a real Qt widget.
            recovered = field.preedit
            assert recovered == "ニホンゴ" and not field.commits
            field.record("toolkit-local-commit", text=recovered)
            field.document = field.document[:field.cursor] + recovered + field.document[field.cursor:]
            field.cursor += len(recovered)
            field.anchor = field.cursor
            field.preedit = ""
            field.context.reset()
            self.wait_replies(field, (start, enter))
            field.surrounding()
        assert worker["resumeDisposition"] == "resumed-same-process"
        field.key(ord("a"))
        field.key(IBus.KEY_Return)
        wait_for(lambda: bool(field.commits), "new input after the Qt-style Reset was not committed")
        assert field.commits == ["あ"], field.commits
        assert field.document == "前ニホンゴあ後", field.document
        confirms = self.responses("confirm-reconversion", began)
        resets = self.responses("reset", began)
        assert len(confirms) == 1 and resets
        assert all(row["response"].get("snapshot", {}).get("commits", []) == [] for row in resets)
        self.observations.update(clientName=field.name, toolkitLocalOriginalCommits=1,
                                 additionalIBusOriginalCommits=0, newCommits=field.commits,
                                 formalCancellationCommits=0, lateConfirmObserved=True,
                                 oldWorker=worker["resumeDisposition"])


def main():
    case = os.environ["AZOOKEY_RECONVERSION_CASE"]
    directory = Path(os.environ["AZOOKEY_NATIVE_ARTIFACTS"])
    trial = ReconversionTrial(directory)
    began = time.monotonic()
    result = {"case": case, "status": "FAIL"}
    try:
        with observe_ibus(directory):
            if case in ("focus", "private", "changed"):
                trial.reject_pending(case)
            else:
                getattr(trial, case.replace("-", "_"))()
        result["status"] = "PASS"
    except Exception as error:
        result.update(error=type(error).__name__, message=str(error), traceback=traceback.format_exc())
    finally:
        for index, field in enumerate(trial.fields):
            field.save(directory / f"field-{index}.json")
        if result["status"] == "PASS":
            try:
                audit = audit_case(directory)
                (directory / "bus-audit.json").write_text(json.dumps(audit, indent=2) + "\n")
            except Exception as error:
                result.update(status="FAIL", error=type(error).__name__, message=str(error),
                              traceback=traceback.format_exc())
        result.update(observations=trial.observations, elapsedSeconds=time.monotonic() - began)
        (directory / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps(result, ensure_ascii=False))
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
