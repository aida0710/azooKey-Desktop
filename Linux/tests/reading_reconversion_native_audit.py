"""Check saved real bus replies and deletion/ACK ordering without rerunning."""
import json
import re


def load(path):
    return json.loads(path.read_text())


def header(block, name):
    found = re.search(r"(?:^|[ ;])" + re.escape(name) + r"=([^ ;\n]+)", block.splitlines()[0])
    return found[1] if found else None


def audit_case(directory):
    blocks = [value for value in re.split(r"(?=^(?:signal|method call|method return|error) time=)",
                                         (directory / "ibus-events.log").read_text(), flags=re.M) if value.strip()]
    engine_senders = {}
    for block in blocks:
        if block.startswith("signal ") and header(block, "interface") == "org.freedesktop.IBus.Engine":
            engine_senders[header(block, "path")] = header(block, "sender")
    calls = []
    for index, block in enumerate(blocks):
        if not block.startswith("method call ") or header(block, "member") != "ProcessKeyEvent":
            continue
        interface = header(block, "interface")
        assert interface in ("org.freedesktop.IBus.Engine", "org.freedesktop.IBus.InputContext")
        serial, sender = header(block, "serial"), header(block, "sender")
        expected_sender = engine_senders[header(block, "path")] if interface.endswith(".Engine") else "org.freedesktop.DBus"
        matches = [(position, reply) for position, reply in enumerate(blocks)
                   if position > index and reply.startswith(("method return ", "error "))
                   and header(reply, "reply_serial") == serial
                   and header(reply, "destination") == sender and header(reply, "sender") == expected_sender]
        assert len(matches) == 1, (index, serial, matches)
        returned_index, returned = matches[0]
        assert returned.startswith("method return ") and re.findall(r"boolean (true|false)", returned) in (["true"], ["false"])
        calls.append({"layer": interface.rsplit(".", 1)[-1], "callBlock": index,
                      "replyBlock": returned_index, "serial": serial,
                      "key": [int(value) for value in re.findall(r"uint32 (\d+)", block)],
                      "consumed": "boolean true" in returned})
    assert not any(header(block, "member") == "ForwardKeyEvent" for block in blocks)
    fields = [load(path) for path in sorted(directory.glob("field-*.json"))]
    client_calls = sum(len(field["calls"]) for field in fields)
    assert client_calls == sum(call["layer"] == "InputContext" for call in calls)
    assert client_calls == sum(call["layer"] == "Engine" for call in calls)
    for field in fields:
        assert len(field["calls"]) == len(field["replies"]) and not field["errors"] and not field["forwarded"]
        assert len({reply["token"] for reply in field["replies"]}) == len(field["replies"])

    deletion_order = []
    clock = load(directory / "observation-clock.json")
    trace = [json.loads(line) for path in (directory / "workers").glob("*.jsonl")
             for line in path.read_text().splitlines()]
    for index, block in enumerate(blocks):
        if header(block, "interface") != "org.freedesktop.IBus.Engine" or header(block, "member") != "DeleteSurroundingText":
            continue
        starts = [call for call in calls if call["layer"] == "Engine" and call["callBlock"] < index
                  and call["key"][0] in (114, 65288) and call["key"][2] == 5]
        start = starts[-1]
        acknowledgements = [(position, value) for position, value in enumerate(blocks)
                            if position > index and header(value, "interface") == "org.freedesktop.IBus.Engine"
                            and header(value, "member") == "SetSurroundingText"
                            and header(value, "path") == header(block, "path") and 'string "前後"' in value
                            and re.findall(r"uint32 (\d+)", value)[-2:] == ["1", "1"]]
        assert acknowledgements
        ack_index, acknowledgement = acknowledgements[0]
        assert start["callBlock"] < index < start["replyBlock"] < ack_index
        ack_monotonic = float(header(acknowledgement, "time")) - clock["wallSeconds"] + clock["monotonicSeconds"]
        start_monotonic = float(header(blocks[start["callBlock"]], "time")) - clock["wallSeconds"] + clock["monotonicSeconds"]
        early_inputs = [row for row in trace if row["role"] == "reading" and row["phase"] == "response"
                        and start_monotonic <= row["monotonic"] < ack_monotonic
                        and row["response"].get("kind") == "input"]
        early_confirms = [row for row in trace if row["operation"] == "confirm-reconversion"
                          and row["phase"] == "request" and start_monotonic <= row["monotonic"] < ack_monotonic]
        assert not early_inputs and not early_confirms
        deletion_order.append({"startCallBlock": start["callBlock"], "deleteBlock": index,
                               "startReplyBlock": start["replyBlock"], "ackBlock": ack_index,
                               "formalInputsBeforeAck": 0, "confirmRequestsBeforeAck": 0})
    return {"inputContextCalls": client_calls, "engineCalls": client_calls,
            "singleReplies": len(calls), "forwardedKeys": 0, "deletionOrder": deletion_order,
            "calls": calls}

