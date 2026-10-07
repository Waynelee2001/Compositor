#!/usr/bin/env python3
"""Exercise the real app-server handshake without signing in or requesting inference."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex", type=Path, required=True)
    args = parser.parse_args()
    binary = args.codex.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="compositor-codex-smoke-") as temporary:
        home = Path(temporary) / "home"
        work = Path(temporary) / "workspace"
        home.mkdir(mode=0o700); work.mkdir(mode=0o700)
        environment = {key: value for key, value in os.environ.items() if key in {
            "PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR", "HTTP_PROXY", "HTTPS_PROXY",
            "ALL_PROXY", "NO_PROXY", "SSL_CERT_FILE", "SSL_CERT_DIR"}}
        environment["CODEX_HOME"] = str(home)
        version = subprocess.run([str(binary), "--version"], cwd=work, env=environment,
                                 capture_output=True, text=True, timeout=15)
        print("Codex binary:", version.stdout.strip(), "exit:", version.returncode, flush=True)
        if version.returncode != 0:
            raise RuntimeError("Codex binary cannot start: " + version.stderr[-4000:])
        command = [str(binary), "app-server", "--listen", "stdio://"]
        for override in ['approval_policy="never"', 'sandbox_mode="read-only"', 'web_search="disabled"',
                         'features.shell_tool=false', 'features.unified_exec=false', 'features.apply_patch_freeform=false',
                         'features.apps=false', 'features.plugins=false', 'mcp_servers={}', 'cli_auth_credentials_store="file"']:
            command += ["-c", override]
        process = subprocess.Popen(command, cwd=work, env=environment, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8")
        messages: queue.Queue[object] = queue.Queue()
        diagnostics: list[str] = []
        diagnostics_lock = threading.Lock()
        def read_errors() -> None:
            assert process.stderr is not None
            for line in process.stderr:
                with diagnostics_lock:
                    diagnostics.append(line)
                    while sum(map(len, diagnostics)) > 8000 and len(diagnostics) > 1:
                        diagnostics.pop(0)
        def read() -> None:
            assert process.stdout is not None
            try:
                for line in process.stdout:
                    if line.strip(): messages.put(json.loads(line))
            except Exception as error: messages.put(error)
            finally: messages.put(EOFError("Codex closed stdout"))
        thread = threading.Thread(target=read, daemon=True); thread.start()
        error_thread = threading.Thread(target=read_errors, daemon=True); error_thread.start()
        def send(message: dict[str, object]) -> None:
            assert process.stdin is not None
            process.stdin.write(json.dumps(message) + "\n"); process.stdin.flush()
        def request(identifier: int, method: str, params: dict[str, object]) -> dict[str, object]:
            send({"id": identifier, "method": method, "params": params})
            for _ in range(100):
                message = messages.get(timeout=30)
                if isinstance(message, Exception): raise message
                if not isinstance(message, dict): raise RuntimeError("Non-object RPC envelope")
                if "method" in message and "id" in message:
                    send({"id": message["id"], "error": {"code": -32601, "message": "No tools in smoke test"}})
                elif message.get("id") == identifier:
                    if "error" in message:
                        raise RuntimeError(f"{method} failed in isolated signed-out test: {message['error']}")
                    return message.get("result", {})
            raise RuntimeError("Too many notifications without a response")
        try:
            initialized = request(1, "initialize", {"clientInfo": {"name": "compositor_ci", "version": "0.2.0"},
                                                    "capabilities": {"experimentalApi": True}})
            if not isinstance(initialized, dict): raise RuntimeError("Invalid initialize result")
            send({"method": "initialized"})
            account = request(2, "account/read", {"refreshToken": False})
            if account.get("account") is not None: raise RuntimeError("Smoke test must use an isolated signed-out home")
            # No turn/start: validate experimental tool registration without using a model or account.
            started = request(3, "thread/start", {"cwd": str(work), "approvalPolicy": "never", "sandbox": "read-only",
                "ephemeral": True, "dynamicTools": [{"type": "function", "name": "compositor_ci_probe",
                "description": "A host tool used only to validate registration; never executed in this smoke test.",
                "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}, "deferLoading": False}]})
            if not started.get("thread", {}).get("id"): raise RuntimeError("Missing thread ID after tool registration")
            print("PASS: real Codex initialize -> initialized -> account/read -> thread/start with dynamic tool (signed out; no inference)")
        except Exception:
            # This process has an empty private home, no API-key environment, and no login/model call.
            # Never enable this diagnostic stream in the application's authenticated connection.
            error_thread.join(timeout=1)
            with diagnostics_lock:
                print("Signed-out Codex startup diagnostics:\n" + "".join(diagnostics)[-8000:], flush=True)
            raise
        finally:
            if process.stdin is not None:
                try: process.stdin.close()
                except BrokenPipeError: pass
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
            thread.join(timeout=1); error_thread.join(timeout=1)

if __name__ == "__main__":
    main()
