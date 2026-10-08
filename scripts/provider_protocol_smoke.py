#!/usr/bin/env python3
"""Verify production provider options with a real Codex child and a loopback-only mock Responses API.
No vendor account, real API key, photo, or paid inference is used.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PNG = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=='


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--codex', type=Path, required=True)
    parser.add_argument('--fixture-generator', type=Path, required=True)
    args = parser.parse_args()
    requests: list[dict] = []
    failures: list[str] = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            try:
                assert self.path == '/responses', 'wrong Responses URL'
                assert self.headers.get('Authorization') == 'Bearer compositor-loopback-test', 'wrong provider credential'
                size = int(self.headers.get('Content-Length', '0'))
                assert 0 < size <= 2 * 1024 * 1024, 'invalid payload size'
                body = json.loads(self.rfile.read(size))
                assert body.get('model') == 'deepseek-flash', 'wrong model ID'
                assert body.get('stream') is True, 'not streaming'
                requests.append(body)
                index = len(requests)
                if index == 1:
                    tool_names = {tool.get('name') for tool in body.get('tools', [])}
                    assert 'compositor_get_document_info' in tool_names, 'dynamic editor tools missing'
                    item = {'id': 'fc_info', 'type': 'function_call', 'name': 'compositor_get_document_info',
                            'call_id': 'info_1', 'arguments': '{}', 'status': 'completed'}
                elif index == 2:
                    assert 'documentId' in json.dumps(body.get('input', [])), 'missing tool-result round trip'
                    item = {'id': 'fc_preview', 'type': 'function_call', 'name': 'compositor_get_canvas_preview',
                            'call_id': 'preview_1', 'arguments': '{}', 'status': 'completed'}
                else:
                    assert index == 3, 'unexpected retry or extra model request'
                    assert 'data:image/png;base64,' in json.dumps(body.get('input', [])), 'image tool result was lost'
                    item = {'id': 'msg_final', 'type': 'message', 'role': 'assistant', 'status': 'completed',
                            'content': [{'type': 'output_text', 'text': 'provider-mock-ready', 'annotations': []}]}
                response = {'id': f'resp_{index}', 'object': 'response', 'model': 'deepseek-flash',
                            'status': 'in_progress', 'output': []}
                events = [('response.created', {'response': response.copy()}),
                          ('response.output_item.added', {'output_index': 0, 'item': dict(item, status='in_progress')})]
                if item['type'] == 'message':
                    events += [('response.content_part.added', {'item_id': item['id'], 'output_index': 0, 'content_index': 0,
                                                               'part': {'type': 'output_text', 'text': '', 'annotations': []}}),
                               ('response.output_text.delta', {'item_id': item['id'], 'output_index': 0, 'content_index': 0,
                                                               'delta': 'provider-mock-ready'})]
                events.append(('response.output_item.done', {'output_index': 0, 'item': item}))
                response.update(status='completed', output=[item], usage={'input_tokens': 5, 'output_tokens': 5, 'total_tokens': 10})
                events.append(('response.completed', {'response': response}))
                payload = ''.join(f'event: {kind}\ndata: {json.dumps(dict(data, type=kind, sequence_number=i))}\n\n'
                                  for i, (kind, data) in enumerate(events)).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers(); self.wfile.write(payload)
            except Exception as error:
                failures.append(str(error))
                self.send_error(400, 'mock protocol assertion failed')

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    serving = threading.Thread(target=server.serve_forever, daemon=True); serving.start()
    try:
        with tempfile.TemporaryDirectory(prefix='compositor-provider-test-') as temporary:
            folder = Path(temporary)
            home, workspace = folder / 'home', folder / 'workspace'
            home.mkdir(mode=0o700); workspace.mkdir(mode=0o700)
            subprocess.run([str(args.fixture_generator.resolve()), str(home), f'http://127.0.0.1:{server.server_port}'], check=True)
            extra = json.loads((home / 'arguments.json').read_text())
            environment = {key: value for key, value in os.environ.items() if key in {'PATH', 'HOME', 'USER', 'LANG', 'TMPDIR'}}
            environment.update(CODEX_HOME=str(home), COMPOSITOR_PROVIDER_API_KEY='compositor-loopback-test', NO_PROXY='127.0.0.1,localhost')
            command = [str(args.codex.resolve()), 'app-server', '--listen', 'stdio://']
            for setting in ['approval_policy="never"', 'sandbox_mode="read-only"', 'web_search="disabled"',
                            'features.shell_tool=false', 'features.unified_exec=false', 'features.apply_patch_freeform=false',
                            'features.apps=false', 'features.plugins=false', 'mcp_servers={}', 'cli_auth_credentials_store="file"']:
                command += ['-c', setting]
            process = subprocess.Popen(command + extra, cwd=workspace, env=environment,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            incoming: queue.Queue[object] = queue.Queue()
            diagnostics: list[str] = []
            notifications: list[dict] = []
            called: list[str] = []
            def read():
                try:
                    for line in process.stdout:
                        if line.strip(): incoming.put(json.loads(line))
                except Exception as error: incoming.put(error)
                finally: incoming.put(EOFError('Codex closed stdout'))
            def errors():
                for line in process.stderr:
                    diagnostics.append(line)
                    if len(diagnostics) > 60: diagnostics.pop(0)
            threading.Thread(target=read, daemon=True).start()
            threading.Thread(target=errors, daemon=True).start()
            def send(value):
                process.stdin.write(json.dumps(value) + '\n'); process.stdin.flush()
            def receive():
                value = incoming.get(timeout=60)
                if isinstance(value, Exception): raise value
                if value.get('method') == 'item/tool/call' and 'id' in value:
                    tool = value['params']['tool']; called.append(tool)
                    if tool == 'compositor_get_document_info':
                        content = [{'type': 'inputText', 'text': json.dumps({'documentId': 'mock-document', 'activeLayerId': 'mock-layer'})}]
                    elif tool == 'compositor_get_canvas_preview':
                        content = [{'type': 'inputImage', 'imageUrl': PNG}]
                    else: raise AssertionError('unexpected tool')
                    send({'id': value['id'], 'result': {'contentItems': content, 'success': True}})
                elif 'method' in value and 'id' in value:
                    send({'id': value['id'], 'error': {'code': -32601, 'message': 'unsupported in loopback test'}})
                elif 'method' in value: notifications.append(value)
                return value
            def request(identifier, method, params):
                send({'id': identifier, 'method': method, 'params': params})
                deadline = time.monotonic() + 65
                while time.monotonic() < deadline:
                    value = receive()
                    if value.get('id') == identifier and 'method' not in value:
                        if 'error' in value: raise RuntimeError(f'{method}: {value["error"]}')
                        return value['result']
                raise TimeoutError(method)
            try:
                request(1, 'initialize', {'clientInfo': {'name': 'compositor_provider_ci', 'version': '0.3.0'},
                                          'capabilities': {'experimentalApi': True}})
                send({'method': 'initialized'})
                account = request(2, 'account/read', {'refreshToken': False})
                assert account.get('requiresOpenaiAuth') is False, 'custom provider incorrectly requires ChatGPT login'
                models = request(3, 'model/list', {})
                assert any(m.get('model') == 'deepseek-flash' or m.get('id') == 'deepseek-flash' for m in models.get('data', [])), 'production catalog not loaded'
                tools = [{'type': 'function', 'name': name, 'description': 'Loopback integration fixture',
                          'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': False}}
                         for name in ['compositor_get_document_info', 'compositor_get_canvas_preview']]
                thread = request(4, 'thread/start', {'model': 'deepseek-flash', 'cwd': str(workspace),
                    'approvalPolicy': 'never', 'sandbox': 'read-only', 'ephemeral': True,
                    'baseInstructions': 'Use only the two supplied tools.', 'dynamicTools': tools})['thread']['id']
                request(5, 'turn/start', {'threadId': thread, 'input': [{'type': 'text', 'text': 'Inspect the fixture.', 'text_elements': []}]})
                deadline = time.monotonic() + 90
                while not any(n.get('method') == 'turn/completed' for n in notifications):
                    if time.monotonic() >= deadline: raise TimeoutError('model/tool turn')
                    receive()
                terminal = next(n for n in notifications if n.get('method') == 'turn/completed')
                assert terminal['params']['turn']['status'] == 'completed', terminal
                assert called == ['compositor_get_document_info', 'compositor_get_canvas_preview'], called
                assert len(requests) == 3 and not failures, failures
                assert any('provider-mock-ready' in json.dumps(n) for n in notifications), 'final streamed text missing'
                print('PASS: real Codex -> custom Responses URL/model/credential -> editor tool results -> image input -> streamed completion')
                print('No real provider request, account, photo, or paid inference was used.')
            except Exception:
                print('Loopback assertions:', failures)
                print('Codex diagnostics:', ''.join(diagnostics)[-6000:].replace('compositor-loopback-test', '<mock-key>'))
                raise
            finally:
                process.stdin.close()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    try: process.wait(timeout=5)
                    except subprocess.TimeoutExpired: process.kill(); process.wait()
    finally:
        server.shutdown(); server.server_close()

if __name__ == '__main__':
    main()
