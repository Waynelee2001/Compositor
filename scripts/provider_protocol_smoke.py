#!/usr/bin/env python3
"""Real pinned Codex + a loopback Responses fixture. No paid API, account, photo, or real key."""
from __future__ import annotations
import argparse
import gzip
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PIXEL = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=='
KEY = 'compositor-fixture-not-a-real-api-key'

def run(binary: Path, fixture: dict) -> None:
    requests: list[dict] = []
    failures: list[str] = []
    def response_events(number: int) -> list[dict]:
        rid = f'resp_{number}'
        events = [{'type': 'response.created', 'response': {'id': rid, 'object': 'response', 'status': 'in_progress'}}]
        if number == 1:
            item = {'id': 'fc_1', 'type': 'function_call', 'call_id': 'host_1', 'name': 'compositor_ci_probe', 'arguments': '{}', 'status': 'completed'}
            events += [{'type': 'response.output_item.added', 'output_index': 0, 'item': {**item, 'arguments': '', 'status': 'in_progress'}},
                       {'type': 'response.function_call_arguments.delta', 'item_id': 'fc_1', 'output_index': 0, 'delta': '{}'},
                       {'type': 'response.output_item.done', 'output_index': 0, 'item': item}]
        else:
            text = 'Provider bridge verified.'
            item = {'id': 'msg_2', 'type': 'message', 'role': 'assistant', 'status': 'completed', 'content': [{'type': 'output_text', 'text': text, 'annotations': []}]}
            events += [{'type': 'response.output_item.added', 'output_index': 0, 'item': {**item, 'status': 'in_progress', 'content': []}},
                       {'type': 'response.output_text.delta', 'item_id': 'msg_2', 'output_index': 0, 'content_index': 0, 'delta': text},
                       {'type': 'response.output_item.done', 'output_index': 0, 'item': item}]
        events.append({'type': 'response.completed', 'response': {'id': rid, 'object': 'response', 'status': 'completed', 'output': [item],
                       'usage': {'input_tokens': 100, 'output_tokens': 10, 'total_tokens': 110, 'input_tokens_details': {'cached_tokens': 0}, 'output_tokens_details': {'reasoning_tokens': 0}}}})
        return events
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_POST(self):
            try:
                if self.path != '/v1/responses': raise AssertionError('Wrong Responses route')
                if self.headers.get('Authorization') != 'Bearer ' + KEY: raise AssertionError('Child did not use the provider key')
                raw = self.rfile.read(int(self.headers.get('Content-Length', '0')))
                if self.headers.get('Content-Encoding') == 'gzip': raw = gzip.decompress(raw)
                body = json.loads(raw)
                if body['model'] != fixture['model']: raise AssertionError('Wrong model selected')
                if 'OTHER_PROVIDER_PRIVATE_HISTORY' in raw.decode(): raise AssertionError('History crossed providers')
                requests.append(body)
                data = ''.join('event: '+event['type']+'\ndata: '+json.dumps(event)+'\n\n' for event in response_events(len(requests))).encode()
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
            except Exception as error:
                failures.append(type(error).__name__ + ': ' + str(error))
                self.send_error(500, 'Fixture assertion failed')
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='compositor-provider-test-') as temporary:
        root = Path(temporary); home = root/'home'; work = root/'work'; home.mkdir(); work.mkdir()
        catalog = root/'models.json'; catalog.write_text(json.dumps(fixture['catalog']))
        environment = {k: v for k, v in os.environ.items() if k in {'PATH','HOME','USER','LOGNAME','TMPDIR','LANG'}}
        environment.update(CODEX_HOME=str(home), COMPOSITOR_PROVIDER_KEY=KEY, NO_PROXY='127.0.0.1,localhost')
        overrides = [x for x in fixture['overrides'] if not x.startswith('model_catalog_json=') and '.base_url=' not in x]
        overrides += ['model_catalog_json='+json.dumps(str(catalog)),
                      'model_providers.'+fixture['id']+'.base_url='+json.dumps(f'http://127.0.0.1:{server.server_port}/v1'),
                      'approval_policy="never"', 'sandbox_mode="read-only"', 'web_search="disabled"', 'features.shell_tool=false',
                      'features.unified_exec=false', 'features.apply_patch_freeform=false', 'features.apps=false', 'features.plugins=false',
                      'mcp_servers={}', 'cli_auth_credentials_store="file"']
        command = [str(binary),'app-server','--listen','stdio://'] + [v for x in overrides for v in ['-c', x]]
        process = subprocess.Popen(command, cwd=work, env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        messages: queue.Queue = queue.Queue(); diagnostics: list[str] = []
        def reader():
            try:
                for line in process.stdout:
                    if line.strip(): messages.put(json.loads(line))
            finally: messages.put(EOFError('App server disconnected'))
        def errors():
            for line in process.stderr:
                diagnostics.append(line.replace(KEY,'[fixture-key]'))
                if len(diagnostics)>80: diagnostics.pop(0)
        threading.Thread(target=reader,daemon=True).start(); threading.Thread(target=errors,daemon=True).start()
        def send(value):
            process.stdin.write(json.dumps(value)+'\n'); process.stdin.flush()
        def receive(deadline):
            value = messages.get(timeout=max(.1,deadline-time.monotonic()))
            if isinstance(value,Exception): raise value
            return value
        def request(id,method,params):
            send({'id':id,'method':method,'params':params}); deadline=time.monotonic()+40
            while time.monotonic()<deadline:
                message=receive(deadline)
                if message.get('id')==id and 'method' not in message:
                    if 'error' in message: raise RuntimeError(method+' failed: '+json.dumps(message['error']).replace(KEY,'[fixture-key]'))
                    return message['result']
            raise TimeoutError(method)
        try:
            request(1,'initialize',{'clientInfo':{'name':'compositor_provider_ci','version':'0.3.0'},'capabilities':{'experimentalApi':True}})
            send({'method':'initialized'})
            listed=request(2,'model/list',{})
            if fixture['model'] not in json.dumps(listed): raise AssertionError('Custom model missing from catalog')
            thread=request(3,'thread/start',{'model':fixture['model'],'modelProvider':fixture['id'],'cwd':str(work),'sandbox':'read-only',
                   'approvalPolicy':'never','ephemeral':True,'baseInstructions':'Use the supplied tool, then report completion.',
                   'dynamicTools':[{'type':'function','name':'compositor_ci_probe','description':'CI-only host tool','inputSchema':{'type':'object','properties':{},'additionalProperties':False}}]})
            send({'id':4,'method':'turn/start','params':{'threadId':thread['thread']['id'],'model':fixture['model'],
                  'input':[{'type':'text','text':'Run the provider bridge test.','text_elements':[]}]}})
            calls=0; streamed=False; deadline=time.monotonic()+60
            while time.monotonic()<deadline:
                message=receive(deadline); method=message.get('method')
                if method=='item/tool/call':
                    if message['params']['tool']!='compositor_ci_probe': raise AssertionError('Unexpected tool')
                    calls+=1
                    send({'id':message['id'],'result':{'success':True,'contentItems':[{'type':'inputText','text':'fixture ok'}, {'type':'inputImage','imageUrl':PIXEL}]}})
                elif method=='item/agentMessage/delta': streamed=True
                elif method=='turn/completed':
                    if message['params']['turn']['status']!='completed': raise AssertionError('Turn did not complete: '+json.dumps(message['params']['turn']).replace(KEY,'[fixture-key]'))
                    break
                elif 'id' in message and method:
                    send({'id':message['id'],'error':{'code':-32601,'message':'Unsupported test request'}})
                elif message.get('id')==4 and 'error' in message: raise AssertionError('turn/start rejected: '+str(message['error']))
            else: raise TimeoutError('Turn did not complete')
            assert not failures, failures
            assert len(requests)==2 and calls==1 and streamed, (len(requests), calls, streamed)
            assert PIXEL in json.dumps(requests[-1]), 'Inline preview did not reach the Responses provider'
            print('PASS:',fixture['id'],fixture['model'],'custom key + catalog + Responses streaming + host tool + image result')
        except Exception:
            print('Fixture diagnostics (no real credentials):\n'+''.join(diagnostics)[-5000:])
            print('Requests received:',len(requests),'fixture failures:',failures)
            raise
        finally:
            try: process.stdin.close()
            except BrokenPipeError: pass
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
            server.shutdown();server.server_close()

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--codex',type=Path,required=True);parser.add_argument('--fixture',type=Path,required=True)
    args=parser.parse_args()
    for fixture in json.loads(args.fixture.read_text()): run(args.codex.resolve(strict=True), fixture)
if __name__=='__main__': main()
