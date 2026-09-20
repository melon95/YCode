#!/usr/bin/env python3
import json
import os
import sys


def read_message():
    length = None
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        key, _, value = line.decode("utf-8").partition(":")
        if key.lower() == "content-length":
            length = int(value.strip())
    if length is None:
        return None
    return json.loads(sys.stdin.buffer.read(length))


def write_message(value):
    body = json.dumps(value, separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii"))
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()


def log(value):
    path = os.environ.get("YCODE_FAKE_LSP_LOG")
    if path:
        with open(path, "a", encoding="utf-8") as stream:
            stream.write(json.dumps(value, ensure_ascii=False) + "\n")


while True:
    message = read_message()
    if message is None:
        break
    log(message)
    method = message.get("method")
    request_id = message.get("id")
    if method == "initialize":
        write_message({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "capabilities": {
                    "definitionProvider": True,
                    "semanticTokensProvider": {
                        "legend": {"tokenTypes": ["function", "variable"], "tokenModifiers": ["declaration"]},
                        "full": True,
                    },
                }
            },
        })
    elif method == "textDocument/didOpen":
        uri = message["params"]["textDocument"]["uri"]
        write_message({
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": {
                "uri": uri,
                "diagnostics": [{
                    "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 2}},
                    "severity": 2,
                    "message": "fake warning",
                }],
            },
        })
    elif method == "textDocument/semanticTokens/full":
        write_message({"jsonrpc": "2.0", "id": request_id, "result": {"data": [0, 3, 4, 0, 1, 1, 2, 5, 1, 0]}})
    elif method == "textDocument/definition":
        uri = message["params"]["textDocument"]["uri"]
        write_message({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": [{
                "uri": uri,
                "range": {"start": {"line": 0, "character": 3}, "end": {"line": 0, "character": 7}},
            }],
        })
    elif method == "shutdown":
        write_message({"jsonrpc": "2.0", "id": request_id, "result": None})
    elif request_id is not None:
        write_message({"jsonrpc": "2.0", "id": request_id, "result": None})
    if method == "exit":
        break
