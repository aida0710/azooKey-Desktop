"""Capture the installed, sandboxed IME through TextEdit and Accessibility."""

import json
import time

from smoke_evidence import require_success

# Wait for actual AX state, including asynchronous Dictionary Services completion.
STATE_TIMEOUT_SECONDS = 30
POLL_INTERVAL_SECONDS = 0.5


def elements(snapshot):
    pending = list(snapshot.get("windows", []))
    while pending:
        element = pending.pop(0)
        yield element
        pending.extend(element.get("children", []))


def identifier(snapshot, name):
    return next((element for element in elements(snapshot) if element.get("AXIdentifier") == name), None)


def snapshot(evidence, name):
    completed = evidence.run(name, [evidence.directory / "helpers/CandidateSnapshot"])
    return json.loads(require_success(completed, "Read candidate window").stdout)


def wait_snapshot(evidence, name, predicate):
    deadline = time.monotonic() + STATE_TIMEOUT_SECONDS
    attempt = 0
    while True:
        observed = snapshot(evidence, f"{name}-{attempt}")
        if predicate(observed):
            if observed.get("frontmost") != "com.apple.TextEdit":
                raise RuntimeError("Candidate UI took focus from TextEdit")
            evidence.write_json(name + ".json", observed)
            return observed
        if time.monotonic() >= deadline:
            evidence.screenshot(name + "-failed")
            raise RuntimeError(f"Candidate UI did not reach {name}; inspect its AX snapshots")
        time.sleep(POLL_INTERVAL_SECONDS)
        attempt += 1


def capture_candidates(evidence, send_keys, *, compact, outcome):
    def keys(name, value):
        require_success(evidence.run(name, [send_keys, value]), "Post " + value)

    def clear(name):
        keys(name + "-confirm", "return")
        require_success(evidence.run(name + "-clear", [evidence.directory / "helpers/TextEditDocument", "clear"]), "Clear TextEdit")

    def has_buttons(observed):
        return any(element.get("AXRole") == "AXButton" for element in elements(observed))

    clear("tree")
    keys("type-long-composition", "kyouhagakkainiikoutoomotteimasu")
    tree = wait_snapshot(evidence, "candidate-tree", has_buttons)
    evidence.screenshot("candidate-tree")
    keys("open-candidate-list", "space")
    listing = wait_snapshot(evidence, "candidate-list", lambda observed:
                            identifier(observed, "candidate-list") if compact else has_buttons(observed))
    evidence.screenshot("candidate-list")

    clear("definition")
    keys("type-dictionary-word", "tesuto")
    keys("convert-dictionary-word", "space")
    # The runner normally has an English dictionary. Find the real converter's
    # English candidate without inserting text or replacing the dictionary result.
    def english_selected(observed):
        for element in elements(observed):
            label = element.get("AXTitle", "") + " " + element.get("AXDescription", "")
            if element.get("AXRole") == "AXButton" and "test" in label.lower() and element.get("AXSelected"):
                return True
        return False

    selected = None
    # A physical page has nine candidates. Search one page of actual converter results.
    for offset in range(9):
        observed = snapshot(evidence, f"dictionary-selection-{offset}")
        if english_selected(observed):
            selected = observed
            break
        keys(f"select-dictionary-{offset}", "down")
    if selected is None:
        raise RuntimeError("The converter's English test candidate was not found on its first page")
    if compact:
        selected = wait_snapshot(evidence, "candidate-definition", lambda observed: identifier(observed, "candidate-definition"))
    else:
        evidence.write_json("candidate-definition.json", selected)
    evidence.screenshot("candidate-definition")

    clear("no-definition")
    keys("type-missing-dictionary-word", "qzxv")
    keys("convert-missing-dictionary-word", "space")
    missing = wait_snapshot(evidence, "candidate-no-definition", lambda observed:
                            has_buttons(observed) and identifier(observed, "candidate-definition") is None)
    evidence.screenshot("candidate-no-definition")
    if compact:
        removed = {"candidate-confirm", "candidate-tree-toggle", "candidate-details-toggle", "candidate-details"}
        for captured in [tree, listing, selected, missing]:
            if any(element.get("AXIdentifier") in removed for element in elements(captured)):
                raise RuntimeError("Removed candidate controls are still visible")
        card = identifier(selected, "candidate-definition")
        menu = identifier(selected, "candidate-list")
        if not card or not menu or card["AXPosition"][0] <= menu["AXPosition"][0]:
            raise RuntimeError("The definition is not to the right of the candidate list")
        outcome["sandboxedDictionaryDefinitionVisible"] = True
        outcome["missingDefinitionCardAbsent"] = True
    outcome["candidateScreensCaptured"] = True
    keys("finish-candidate-capture", "escape")
