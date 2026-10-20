#!/usr/bin/env python3
"""Synthetic converter for real IBus delay/failure tests; never uses a model."""
import json
import os
import sys
import time


def main():
    sessions = {}
    delay = float(os.environ.get("AZOOKEY_TEST_DELAY", "0.25"))
    for line in sys.stdin:
        request = json.loads(line)
        operation = request["operation"]
        context = request.get("context", "default")
        session = sessions.setdefault(context, {
            "text": "", "cursor": 0, "generation": 0, "state": "none", "language": "japanese",
        })
        text, cursor, state = session["text"], session["cursor"], session["state"]
        snapshot = {"consumed": True, "commits": [], "candidates": []}
        if operation == "settings":
            snapshot["settings"] = {"tree": False, "aiEnabled": False, "live": False, "halfSpace": True}
        elif operation == "key":
            event = request["event"]
            characters = event.get("characters")
            modifiers = event.get("modifierFlags", 0)
            key = event["keyCode"]
            if characters == "h" and not modifiers:
                # Main-loop progress recovery must not wait for this sleep.
                time.sleep(60)
            time.sleep(delay)
            if characters == "h" and modifiers == 2:
                key, characters = 51, None
            if key in (36, 76):
                snapshot["commits"] = [text] if text else []
                snapshot["consumed"] = bool(text)
                text, cursor, state = "", 0, "none"
            elif key == 53 and not modifiers:
                if state in ("previewing", "selecting", "replaceSuggestion"):
                    state = "composing"
                else:
                    text, cursor, state = "", 0, "none"
            elif key == 53:
                snapshot["consumed"] = not bool(modifiers & 8)
            elif key == 49 and text:
                state = "previewing"
            elif key == 51:
                text = text[:max(0, cursor - 1)] + text[cursor:]
                cursor = max(0, cursor - 1)
            elif key in (123, 124):
                cursor = max(0, cursor - 1) if key == 123 else min(len(text), cursor + 1)
                snapshot["consumed"] = bool(text)
            elif key in (102, 104):
                session["language"] = "english" if key == 102 else "japanese"
            elif key == 98:
                # F7 selects a synthetic AI state only in this fixture.
                text, cursor, state = "にほんご", 4, "replaceSuggestion"
            elif characters and session["language"] == "english" and state == "none":
                snapshot["commits"] = [characters]
            elif characters:
                text = text[:cursor] + characters + text[cursor:]
                cursor += len(characters)
                state = "composing"
            else:
                snapshot["consumed"] = False
            session["generation"] += 1
        elif operation in ("reset", "close"):
            text, cursor, state = "", 0, "none"
            session["generation"] += 1
        session.update(text=text, cursor=cursor, state=state)
        snapshot.update(
            preedit="人工知能の候補" if state == "replaceSuggestion" else text,
            cursor=cursor, reading=text, readingCursor=cursor,
            generation=session["generation"], inputState=state, language=session["language"],
        )
        print(json.dumps(snapshot), flush=True)


if __name__ == "__main__":
    main()
