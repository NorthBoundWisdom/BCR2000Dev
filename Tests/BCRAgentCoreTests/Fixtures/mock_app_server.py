"""Offline JSONL fixture for the stable Codex App Server request/response shapes.

No network, credentials, shell execution or repository writes. Fails on unsafe wire policies.
"""

import json
import sys

threads = {}
turns = {}
approvals = {}
next_thread = 1
next_turn = 1
next_approval = 100


def emit(value):
    print(json.dumps(value), flush=True)


def finish(thread, turn, status):
    emit({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": turn, "status": status}}})


for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    args = request.get("params") or {}
    identifier = request.get("id")
    if method is None:
        thread, turn = approvals.pop(identifier)
        assert request["result"]["decision"] in ("accept", "decline")
        finish(thread, turn, "completed" if request["result"]["decision"] == "accept" else "interrupted")
        continue
    if identifier is None:
        assert method == "initialized"
        continue
    result = {}
    if method == "initialize":
        assert args["clientInfo"]["name"] == "BCRAgentConsole"
        result = {"userAgent": "offline-fixture"}
    elif method == "account/read":
        result = {"account": {"type": "chatgpt", "email": "offline@example.invalid"}}
    elif method == "model/list":
        result = {
            "data": [
                {
                    "id": "fixture",
                    "displayName": "Offline Fixture",
                    "isDefault": True,
                    "supportedReasoningEfforts": [{"reasoningEffort": "low"}],
                }
            ]
        }
    elif method == "thread/start":
        assert args["sandbox"] in ("read-only", "workspace-write")
        thread = "thread-" + str(next_thread)
        next_thread += 1
        threads[thread] = args
        result = {"thread": {"id": thread}}
    elif method == "turn/start":
        thread = args["threadId"]
        assert thread in threads
        assert args["approvalPolicy"] == "on-request"
        assert args["sandboxPolicy"]["type"] in ("readOnly", "workspaceWrite")
        if args["sandboxPolicy"]["type"] == "workspaceWrite":
            assert args["sandboxPolicy"]["writableRoots"] == [args["cwd"]]
            assert args["sandboxPolicy"]["networkAccess"] is False
        assert args["input"][0]["type"] == "text"
        turn = "turn-" + str(next_turn)
        next_turn += 1
        turns[thread] = turn
        emit({"id": identifier, "result": {"turn": {"id": turn, "status": "inProgress"}}})
        emit({"method": "turn/started", "params": {"threadId": thread, "turn": {"id": turn}}})
        text = args["input"][0]["text"]
        if text == "approval":
            next_approval += 1
            approvals[next_approval] = (thread, turn)
            emit(
                {
                    "id": next_approval,
                    "method": "item/commandExecution/requestApproval",
                    "params": {"threadId": thread, "turnId": turn, "command": "offline fixture validation"},
                }
            )
        elif text == "complete":
            finish(thread, turn, "completed")
        elif text == "fail":
            finish(thread, turn, "failed")
        continue
    elif method == "turn/interrupt":
        finish(args["threadId"], args["turnId"], "interrupted")
    else:
        emit({"id": identifier, "error": {"code": -32601, "message": "Unsupported fixture method"}})
        continue
    emit({"id": identifier, "result": result})
