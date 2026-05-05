#!/usr/bin/env python3
"""
Codex Azure Proxy - Comprehensive Test Suite
Tests all real Codex input patterns discovered from proxy logs.
Run: python3 tests/test_proxy.py [model]
"""
import http.client
import json
import sys

MODEL = sys.argv[1] if len(sys.argv) > 1 else "gpt-5.5"
PROXY_HOST = "127.0.0.1"
PROXY_PORT = 8765


def req(body):
    """Send a request to the proxy and return parsed response."""
    payload = json.dumps(body).encode()
    conn = http.client.HTTPConnection(PROXY_HOST, PROXY_PORT, timeout=30)
    conn.request("POST", "/v1/responses", payload, {
        "Content-Type": "application/json",
        "Content-Length": str(len(payload)),
        "Authorization": "Bearer test",
    })
    resp = conn.getresponse()
    raw = resp.read().decode()
    conn.close()

    events = []
    for line in raw.split("\n"):
        line = line.strip()
        if line.startswith("data: "):
            try:
                events.append(json.loads(line[6:]))
            except Exception:
                pass
    return events


def get_text(events):
    """Extract final response text from events."""
    for e in reversed(events):
        if e.get("type") == "response.output_text.done":
            return e.get("text", "")
    return ""


def get_tool_calls(events):
    """Extract tool call items from completed response."""
    for e in events:
        if e.get("type") == "response.completed":
            output = e.get("response", {}).get("output", [])
            return [o for o in output if o.get("type") == "function_call"]
    return []


def has_completed(events):
    return any(e.get("type") == "response.completed" for e in events)


def has_error(events):
    for e in events:
        if e.get("type") == "response.completed":
            err = e.get("response", {}).get("error")
            if err:
                return str(err)
    return None


PASS = 0
FAIL = 0


def check(name, events, expect_text=False, expect_tools=0):
    global PASS, FAIL
    err = has_error(events)
    if err:
        print(f"  ✗ FAIL {name}")
        print(f"       Error: {err[:200]}")
        FAIL += 1
        return False
    if not has_completed(events):
        print(f"  ✗ FAIL {name} (no completed event)")
        FAIL += 1
        return False
    text = get_text(events)
    tools = get_tool_calls(events)
    if expect_text and not text:
        print(f"  ✗ FAIL {name} (expected text, got none)")
        FAIL += 1
        return False
    if expect_tools > 0 and len(tools) != expect_tools:
        print(f"  ✗ FAIL {name} (expected {expect_tools} tools, got {len(tools)})")
        FAIL += 1
        return False
    print(f"  ✓ PASS {name}")
    PASS += 1
    return True


TOOLS = [{
    "type": "function",
    "name": "shell",
    "description": "Run a shell command",
    "parameters": {
        "type": "object",
        "properties": {"cmd": {"type": "string"}},
        "required": ["cmd"],
    },
}]

print(f"\n=== Codex Azure Proxy Test Suite (model={MODEL}) ===\n")

# Test 1: Basic single-turn text
events = req({"model": MODEL, "input": "Say 'hello' and nothing else."})
check("Test 1: Basic single-turn text", events, expect_text=True)

# Test 2: Single tool call [user, fc, fco]
events = req({
    "model": MODEL,
    "tools": TOOLS,
    "input": [
        {"role": "user", "content": "Run pwd"},
        {"type": "function_call", "call_id": "call_001", "name": "shell", "arguments": '{"cmd":"pwd"}'},
        {"type": "function_call_output", "call_id": "call_001", "output": "/Users/balloon"},
    ],
})
check("Test 2: Single tool [user, fc, fco]", events)

# Test 3: Parallel tools [fc1,fc2,fc3,fco1,fco2,fco3]
events = req({
    "model": MODEL,
    "tools": TOOLS,
    "input": [
        {"role": "user", "content": "Run three commands in parallel"},
        {"type": "function_call", "call_id": "call_p1", "name": "shell", "arguments": '{"cmd":"pwd"}'},
        {"type": "function_call", "call_id": "call_p2", "name": "shell", "arguments": '{"cmd":"whoami"}'},
        {"type": "function_call", "call_id": "call_p3", "name": "shell", "arguments": '{"cmd":"date"}'},
        {"type": "function_call_output", "call_id": "call_p1", "output": "/Users/balloon"},
        {"type": "function_call_output", "call_id": "call_p2", "output": "balloon"},
        {"type": "function_call_output", "call_id": "call_p3", "output": "Mon Jan 1"},
    ],
})
check("Test 3: Parallel 3 tools [fc1,fc2,fc3,fco1,fco2,fco3]", events)

# Test 4: Text + tool in same output turn [text, fc, fco]
events = req({
    "model": MODEL,
    "tools": TOOLS,
    "input": [
        {"role": "user", "content": "Check disk space"},
        {"role": "assistant", "content": "I'll check that for you."},
        {"type": "function_call", "call_id": "call_t1", "name": "shell", "arguments": '{"cmd":"df -h"}'},
        {"type": "function_call_output", "call_id": "call_t1", "output": "disk: 80% full"},
    ],
})
check("Test 4: Text+tool [text, fc, fco]", events)

# Test 5: Tool sandwiched by text [fc, text_msg, fco]
# Real Codex pattern: model emits fc, then a text message, then user sends fco
events = req({
    "model": MODEL,
    "tools": TOOLS,
    "input": [
        {"role": "user", "content": "Run git status"},
        {"type": "function_call", "call_id": "call_s1", "name": "shell", "arguments": '{"cmd":"git status"}'},
        {"role": "assistant", "content": [{"type": "output_text", "text": "Running git status..."}]},
        {"type": "function_call_output", "call_id": "call_s1", "output": "On branch main, nothing to commit"},
    ],
})
check("Test 5: Tool sandwiched text [fc, text_msg, fco]", events)

# Test 6: Sequential tools [fc1, fco1, text, fc2, fco2]
events = req({
    "model": MODEL,
    "tools": TOOLS,
    "input": [
        {"role": "user", "content": "Step by step: list files then count them"},
        {"type": "function_call", "call_id": "call_seq1", "name": "shell", "arguments": '{"cmd":"ls"}'},
        {"type": "function_call_output", "call_id": "call_seq1", "output": "a.txt b.txt c.txt"},
        {"role": "assistant", "content": "Found 3 files. Counting..."},
        {"type": "function_call", "call_id": "call_seq2", "name": "shell", "arguments": '{"cmd":"ls | wc -l"}'},
        {"type": "function_call_output", "call_id": "call_seq2", "output": "3"},
    ],
})
check("Test 6: Sequential tools [fc1,fco1,text,fc2,fco2]", events)

# Test 7: Mixed parallel + sequential [fc1,fc2,fco1,fco2,text,fc3,fco3]
events = req({
    "model": MODEL,
    "tools": TOOLS,
    "input": [
        {"role": "user", "content": "Complex multi-step task"},
        {"type": "function_call", "call_id": "call_m1", "name": "shell", "arguments": '{"cmd":"pwd"}'},
        {"type": "function_call", "call_id": "call_m2", "name": "shell", "arguments": '{"cmd":"whoami"}'},
        {"type": "function_call_output", "call_id": "call_m1", "output": "/Users/balloon"},
        {"type": "function_call_output", "call_id": "call_m2", "output": "balloon"},
        {"role": "assistant", "content": "Got location and user. Now checking git..."},
        {"type": "function_call", "call_id": "call_m3", "name": "shell", "arguments": '{"cmd":"git status"}'},
        {"type": "function_call_output", "call_id": "call_m3", "output": "clean"},
    ],
})
check("Test 7: Mixed 3-round [fc1,fc2,fco1,fco2,text,fc3,fco3]", events)

# Test 8: Null/empty content assistant message (Bug 4 regression test)
# Azure rejects {role:"assistant", content:null} without tool_calls.
# Codex can emit assistant messages with empty content arrays.
events = req({
    "model": MODEL,
    "tools": TOOLS,
    "input": [
        {"role": "user", "content": "Continue from previous context"},
        # Simulate assistant message with empty content array (real pattern from logs)
        {"type": "message", "role": "assistant", "content": []},
        {"type": "function_call", "call_id": "call_null1", "name": "shell", "arguments": '{"cmd":"echo ok"}'},
        {"type": "function_call_output", "call_id": "call_null1", "output": "ok"},
    ],
})
check("Test 8: Null/empty content assistant message (Bug 4 regression)", events)

# Test 9: Context compression — send 200 input items, verify proxy compresses and still responds
# Proxy compresses items >80 (COMPRESS_THRESHOLD) into a summary + recent tail.
# We can't easily test the internal compression, but we can verify the proxy
# still returns a valid response without hanging or erroring.
big_input = [{"role": "user", "content": "Large session test"}]
for i in range(100):
    cid = f"call_big{i:03d}"
    big_input.append({"type": "function_call", "call_id": cid, "name": "shell",
                       "arguments": f'{{"cmd":"echo step{i}"}}'})
    big_input.append({"type": "function_call_output", "call_id": cid, "output": f"step{i} output"})
events = req({"model": MODEL, "tools": TOOLS, "input": big_input})
check("Test 9: Large context (200 items) triggers compression and returns", events)

# Test 10: Timeout behavior — proxy should return an error event, not hang.
# We test this by hitting a known-bad endpoint that forces a quick Azure 404,
# which exercises the error path (can't easily force a real timeout in unit test).
events = req({
    "model": "nonexistent-model-xyz-404",
    "input": "Simple test that will hit Azure 404",
})
# Should return completed event (possibly with error), not hang
completed = any(e.get("type") == "response.completed" for e in events)
if not completed:
    print("  ✗ FAIL Test 10: Timeout/error path — no completed event returned")
    FAIL += 1
else:
    print("  ✓ PASS Test 10: Error path returns completed event (not silent hang)")
    PASS += 1

# Test 11: previous_response_id forwarding
# Send a first request, extract the response ID, then send a follow-up using previous_response_id.
# Verifies that the proxy forwards previous_response_id to Azure and gets a valid stateful response.
events1 = req({"model": MODEL, "input": "My name is Balloon. Say 'got it' and nothing else."})
check("Test 11a: First turn (establish state)", events1, expect_text=True)

resp_id = None
for e in events1:
    if e.get("type") == "response.completed":
        resp_id = e.get("response", {}).get("id")
        break

if resp_id:
    events2 = req({"model": MODEL, "previous_response_id": resp_id, "input": "What is my name?"})
    ok = check("Test 11b: Follow-up with previous_response_id", events2, expect_text=True)
    if ok:
        text2 = get_text(events2)
        if "Balloon" in text2 or "balloon" in text2:
            print("  ✓ INFO  previous_response_id state confirmed (name recalled)")
        else:
            print("  ✗ WARN  previous_response_id response did not recall name: " + text2[:100])
else:
    print("  ✗ FAIL Test 11b: Could not extract response ID from Test 11a")
    FAIL += 1

print(f"\n{'=' * 50}")
print(f"Total: {PASS}/{PASS+FAIL} passed")
if FAIL > 0:
    sys.exit(1)
