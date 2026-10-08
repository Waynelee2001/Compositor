#!/usr/bin/env python3
"""Real Codex + loopback-only mock Responses provider; no account, external inference, or real key."""
from __future__ import annotations
import argparse
import gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time

PNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
DUMMY_KEY = "ci-placeholder-not-a-real-api-key"

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    args = parser.parse_args()
    requests: list[dict] = []
    failures: list[str] = []
    class Provider(BaseHTTPRequestHandler):
        def log_message(self, *_: object) -> None:
            pass
        def do_POST(self) -> None:
            try:
                assert self.path == "/responses", "Wrong provider route"
                assert self.headers.get("Authorization") == "Bearer " + DUMMY_KEY, "Wrong credential routing"
                raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                if self.headers.get("Content-Encoding") == "gzip": raw = gzip.decompress(raw)
                body = json.loads(raw)
                assert body["model"] == "deepseek-flash", "Wrong model routing"
                assert body.get("stream") is True, "Expected streaming"
                requests.append(body)
                first = len(requests) == 1
                identifier = "resp_probe" if first else "resp_final"
                if first:
                    names = [tool.get("name") for tool in body.get("tools", [])]
                    assert "compositor_ci_probe" in names, "Dynamic editor tool was not forwarded"
                    assert not any(n in names for n in ["shell", "shell_command", "exec_command", "apply_patch"]), "Unexpected filesystem execution tool"
                    item = {"type": "function_call", "id": "fc_probe", "call_id": "call_probe", "name": "compositor_ci_probe", "arguments": "{}", "status": "completed"}
                else:
                    assert "input_image" in json.dumps(body.get("input")), "Tool image result was not passed back"
                    item = {"type": "message", "id": "msg_final", "role": "assistant", "status": "completed",
                            "content": [{"type": "output_text", "text": "Provider integration OK.", "annotations": []}]}
                result = {"id": identifier, "object": "response", "model": "deepseek-flash", "status": "completed", "output": [item],
                          "usage": {"input_tokens": 20, "output_tokens": 10, "total_tokens": 30,
                                    "input_tokens_details": {"cached_tokens": 0}, "output_tokens_details": {"reasoning_tokens": 0}}}
                events = [{"type": "response.created", "response": {"id": identifier, "object": "response", "status": "in_progress", "output": []}},
                          {"type": "response.output_item.added", "output_index": 0, "item": {**item, "status": "in_progress"}}]
                if not first:
                    events.append({"type": "response.output_text.delta", "item_id": item["id"], "output_index": 0,
                                   "content_index": 0, "delta": "Provider integration OK."})
                events += [{"type": "response.output_item.done", "output_index": 0, "item": item},
                           {"type": "response.completed", "response": result}]
                self.send_response(200); self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close"); self.end_headers()
                for sequence, event in enumerate(events):
                    event["sequence_number"] = sequence
                    self.wfile.write(("event: " + event["type"] + "\ndata: " + json.dumps(event) + "\n\n").encode())
                    self.wfile.flush()
                self.close_connection = True
            except Exception as error:
                failures.append(str(error))
                self.send_error(400, "Mock provider validation failed")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start()
    try:
        with tempfile.TemporaryDirectory(prefix="compositor-provider-smoke-") as temp:
            root = Path(temp); home = root / "home"; work = root / "workspace"
            home.mkdir(mode=0o700); work.mkdir(mode=0o700)
            catalog = home / "models.json"
            endpoint = f"http://127.0.0.1:{server.server_port}"
            fixture = json.loads(subprocess.check_output([str(args.fixture.resolve()), endpoint, str(catalog)], text=True, timeout=15))
            catalog.write_text(json.dumps(fixture["catalog"])); catalog.chmod(0o600)
            environment = {k: v for k, v in os.environ.items() if k in {"PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR"}}
            environment["CODEX_HOME"] = str(home); environment[fixture["envKey"]] = DUMMY_KEY
            command = [str(args.codex.resolve()), "app-server", "--listen", "stdio://"]
            for value in ['approval_policy="never"', 'sandbox_mode="read-only"', 'web_search="disabled"',
                          'features.shell_tool=false', 'features.unified_exec=false', 'features.apply_patch_freeform=false',
                          'features.apps=false', 'features.plugins=false', 'mcp_servers={}', 'cli_auth_credentials_store="file"']:
                command += ["-c", value]
            command += fixture["flags"]
            assert DUMMY_KEY not in " ".join(command) and DUMMY_KEY not in catalog.read_text()
            process = subprocess.Popen(command, cwd=work, env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True, encoding="utf-8")
            messages: queue.Queue[object] = queue.Queue(); errors: list[str] = []
            def read() -> None:
                try:
                    for line in process.stdout:
                        if line.strip(): messages.put(json.loads(line))
                except Exception as error: messages.put(error)
                finally: messages.put(EOFError("Codex closed stdout"))
            def read_errors() -> None:
                for line in process.stderr:
                    errors.append(line.replace(DUMMY_KEY, "[redacted]"))
                    if len(errors) > 40: errors.pop(0)
            threading.Thread(target=read, daemon=True).start(); threading.Thread(target=read_errors, daemon=True).start()
            def send(message: dict) -> None:
                process.stdin.write(json.dumps(message) + "\n"); process.stdin.flush()
            def next_message() -> dict:
                message = messages.get(timeout=30)
                if isinstance(message, Exception): raise message
                if not isinstance(message, dict): raise RuntimeError("Invalid RPC envelope")
                return message
            def request(identifier: int, method: str, params: dict) -> dict:
                send({"id": identifier, "method": method, "params": params})
                for _ in range(200):
                    message = next_message()
                    if message.get("id") == identifier:
                        if "error" in message: raise RuntimeError(str(message["error"]))
                        return message["result"]
                raise RuntimeError("RPC response not received")
            try:
                request(1, "initialize", {"clientInfo": {"name": "compositor_provider_ci", "version": "0.3.0"}, "capabilities": {"experimentalApi": True}})
                send({"method": "initialized"})
                started = request(2, "thread/start", {"model": "deepseek-flash", "cwd": str(work), "approvalPolicy": "never", "sandbox": "read-only", "ephemeral": True,
                    "baseInstructions": "Use compositor_ci_probe once and then say Done.", "dynamicTools": [{"type": "function", "name": "compositor_ci_probe",
                        "description": "Return a small test image.", "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}, "deferLoading": False}]})
                send({"id": 3, "method": "turn/start", "params": {"threadId": started["thread"]["id"], "model": "deepseek-flash",
                      "input": [{"type": "text", "text": "Run the test image tool.", "text_elements": []}]}})
                deadline = time.monotonic() + 90; called = False; complete = False; streamed = False
                while time.monotonic() < deadline:
                    message = next_message(); method = message.get("method"); params = message.get("params", {})
                    if "error" in message: raise RuntimeError(str(message["error"]))
                    if method == "item/tool/call":
                        assert params.get("tool") == "compositor_ci_probe" and not called
                        called = True
                        send({"id": message["id"], "result": {"success": True, "contentItems": [
                            {"type": "inputText", "text": "Generated CI test image, no user data."}, {"type": "inputImage", "imageUrl": PNG}]}})
                    elif method == "item/agentMessage/delta": streamed = True
                    elif method == "turn/completed":
                        assert params["turn"]["status"] == "completed", params["turn"].get("error")
                        complete = True; break
                    elif method and "id" in message:
                        raise RuntimeError("Unexpected non-editor request: " + method)
                assert complete and called and streamed, "Incomplete streamed editor-tool round trip"
                assert len(requests) == 2 and not failures, failures
                print("PASS: real Codex custom Responses provider -> streamed function call -> host image result -> streamed final answer")
                print("PASS: configured model, environment-only API key, disabled execution tools, isolated home (no paid inference)")
            except Exception:
                print("Isolated mock diagnostics:\n" + "".join(errors)[-6000:])
                if failures: print("Mock validation:", failures)
                raise
            finally:
                try: process.stdin.close()
                except BrokenPipeError: pass
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    try: process.wait(timeout=5)
                    except subprocess.TimeoutExpired: process.kill(); process.wait()
    finally:
        server.shutdown(); server.server_close(); worker.join(timeout=2)

if __name__ == "__main__":
    main()
