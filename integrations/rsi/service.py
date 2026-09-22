"""Persistent Windows service: actual DeepSeek UI, private GPU gateway, learning queue.

The front endpoint never exposes adapter mutation or evaluator files. A kernel
lock serializes every model request against complete training/evaluation cycles.
Unverified chat traces are retained separately and are not admitted to training.
"""
import argparse
import hashlib
import hmac
import http.client
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit
from local_rsi import ROOT,PORT,guard,read,write_new,atomic,now,digest,champion,controller_lock,calculate
from model_runtime import ensure,stop,alive

FRONT_PORT=18803
STATE={'state':'starting','pid':os.getpid(),'learning':None,'last_request':time.time()}
QUEUE=threading.Lock()
SHUTDOWN=threading.Event()
WARMUP=threading.Lock()
KEY=(ROOT/'records/local-server.key').read_text().strip()
READINESS={'checked':0,'value':None}

def learning_data(force=False):
    if force or time.monotonic()-READINESS['checked']>15 or READINESS['value'] is None:
        from learning_readiness import readiness
        try:value=readiness()
        except Exception as error:value={'error':str(error),'new_or_corrected_examples':0}
        READINESS.update(checked=time.monotonic(),value=value)
    return READINESS['value']

def wake_model():
    if WARMUP.acquire(blocking=False):
        STATE['model_state']='loading'
        def run():
            try:
                with controller_lock(timeout=900):
                    from runtime_context import synchronize
                    synchronize()
                    ensure('inference',champion().get('adapter'))
                    (ROOT/'records/model-activity').touch()
                STATE['model_state']='ready';STATE.pop('model_error',None)
            except Exception as error:
                STATE.update(model_state='error',model_error=str(error))
            finally:WARMUP.release()
        threading.Thread(target=run,daemon=True).start()
    return {'model_state':STATE.get('model_state','loading')}

def status():
    from memory_store import statistics
    generation=champion()
    current=STATE.copy()
    if not current.get('learning'):
        completed=list((ROOT/'records').glob('job-*.json'))
        if completed:current['learning']=read(max(completed,key=lambda p:p.stat().st_mtime))
    if (current.get('learning') or {}).get('state') in ('running','queued'):
        current['model_state']='learning'
    elif alive():current['model_state']='ready'
    elif current.get('model_state')=='ready':current['model_state']='idle'
    current.update(champion=generation['id'],parent=generation.get('parent'),adapter=generation.get('adapter'),memory=statistics(),
      context_policy=generation.get('native_policy',''),model=Path(generation['base']['path']).name,
      gateway='127.0.0.1:'+str(FRONT_PORT),backend='127.0.0.1:'+str(PORT),
      runtime='DeepSeek Harness with project-local plugin and state',
      workspace=str(ROOT/'deepseek/work'),learning_data=learning_data(),
      automatic_learning={'enabled':learning_enabled(),'minimum_new_verified_examples':16,'minimum_interval_seconds':7200,'max_cycles_per_24h':3},
      limitations=['Output-projection parameter adaptation; no body-layer QLoRA',
        'Protected benchmark is a small engineering integration suite',
        'Executable evolution covers memory ranking and training-data/curriculum selection; strategy changes require descendant comparisons'],
      executable_harness=generation.get('executable_harness'),meta_policy=generation.get('meta_policy'),
      training_strategy=generation.get('training_strategy'),training_strategy_decision=generation.get('training_strategy_decision'))
    if current.get('learning',{}):
        cycles=sorted([*(ROOT/'cycles').glob('cycle-*/status.json'),*(ROOT/'evolution-cycles').glob('evolution-*/status.json')],key=lambda p:p.stat().st_mtime,reverse=True)
        if cycles:
            item=read(cycles[0]);current['cycle']={k:item.get(k) for k in ('id','parent','candidate','phase','promoted','error','finished')}
    return current

def learning_enabled():
    path=ROOT/'learning-settings.json'
    return path.exists() and read(path).get('automatic_learning') is True

def automatic_budget_available():
    cutoff=time.time()-86400
    return sum(read(p).get('automatic') is True for p in (ROOT/'records').glob('job-*.json') if p.stat().st_mtime>=cutoff)<3

def queue_learning(reason,automatic=False,executable_only=False):
    if not QUEUE.acquire(blocking=False):return {'queued':False,'reason':'A learning job is already queued or running.'}
    job='job-'+str(time.time_ns())
    STATE['learning']={'id':job,'state':'queued','reason':str(reason)[:1000],'automatic':automatic,'timestamp':now(),
      'kind':'executable_and_meta' if executable_only else 'coupled_software_and_parameters'}
    def run():
        log=ROOT/'records'/(job+'.log');proc=None
        try:
            STATE['learning']['state']='running'
            with log.open('wb') as out:
                script='evolution_loop.py' if executable_only else 'improvement_cycle.py'
                proc=subprocess.Popen([sys.executable,'-B','-u',str(ROOT/script)],cwd=ROOT,
                  stdin=subprocess.DEVNULL,stdout=out,stderr=out,creationflags=subprocess.CREATE_NO_WINDOW)
                deadline=time.monotonic()+3600
                while proc.poll() is None:
                    if SHUTDOWN.wait(.5) or time.monotonic()>deadline:
                        (ROOT/'STOP').touch();proc.terminate();break
                proc.wait(timeout=20)
            STATE['learning'].update(state='completed' if proc.returncode==0 else 'failed',exit_code=proc.returncode,log=str(log),finished=now())
        except Exception as error:STATE['learning'].update(state='failed',error=str(error),log=str(log))
        finally:
            if proc is not None and proc.poll() is None:proc.kill();proc.wait()
            write_new(ROOT/'records'/(job+'.json'),STATE['learning'])
            READINESS['checked']=0
            QUEUE.release()
    threading.Thread(target=run,daemon=True).start()
    return {'queued':True,'job':job,'promotion':'Protected evaluation only; improvement is not assumed.'}

def arithmetic_evidence(expression):
    if not isinstance(expression,str) or len(expression)>200:raise ValueError('Expression must be at most 200 characters')
    value=calculate(expression);target=str(value)
    task='Evaluate '+expression+'. Reply with exactly the numeric result and no explanation.'
    event={'task':task,'target':target,'original_attempt':None,'outcome':'deterministically_verified_tool_result',
      'correction':None,'verifier':'arithmetic_v1','inputs':[expression],
      'verification':{'method':'arithmetic_v1','inputs':[expression],'result':target,'deterministic':True},
      'generation':champion()['id'],'confidence':1.0,'split':'train','timestamp':now(),
      'source':'Actual DeepSeek rsi_calculate tool invocation; task wording canonicalized by controller',
      'training_eligible':True}
    event['evidence_id']='ev-'+digest(event)[:20]
    write_new(ROOT/'experience'/(event['evidence_id']+'.json'),event)
    return {'result':value,'verified':True,'method':'restricted arithmetic interpreter',
      'evidence_id':event['evidence_id'],'generation':event['generation']}

def local_decision(data):
    """Run the local prefill-only decision head under the active champion."""
    with controller_lock(timeout=900):
        guard(); generation=champion()
        from runtime_context import synchronize
        synchronize()
        ensure('inference',generation.get('adapter'))
        from jev_local import decide
        return decide(data)

class Handler(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args):pass
    def handle_error(self,request,client_address):
        # The memory panel and the harness poll this front over keep-alive
        # connections and drop them as soon as a request is superseded, so a
        # client reset is normal traffic here. socketserver's default reporter
        # prints a full traceback for each one, which would fill the front's log
        # when it runs detached from the desktop launcher. Anything else is a
        # real fault and still gets reported.
        error=sys.exc_info()[1]
        if isinstance(error,(ConnectionResetError,ConnectionAbortedError,BrokenPipeError)):return
        super().handle_error(request,client_address)
    def reply(self,code,value):
        raw=json.dumps(value,ensure_ascii=False).encode()
        self.send_response(code);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)))
        self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(raw)
    def authorized(self):
        return hmac.compare_digest(self.headers.get('Authorization',''),'Bearer '+KEY) and not self.headers.get('Origin')
    def do_GET(self):
        if not self.authorized():return self.reply(403,{'error':'Local application authentication required'})
        if self.path=='/rsi/status':return self.reply(200,status())
        if self.path=='/health':return self.reply(200,{'status':'ok','service':STATE['state']})
        if self.path=='/v1/models':return self.reply(200,{'object':'list','data':[{'id':'local-champion','object':'model','owned_by':'local'}]})
        self.reply(404,{'error':'Unavailable route'})
    def do_POST(self):
        if not self.authorized():return self.reply(403,{'error':'Local application authentication required'})
        try:
            size=int(self.headers.get('Content-Length','0'))
            if not 0<size<=32*2**20:raise ValueError('Request size limit')
            data=json.loads(self.rfile.read(size))
            if self.path=='/rsi/ui':
                from local_ui import dispatch
                return self.reply(200,dispatch(data,sys.modules[__name__]))
            if self.path=='/rsi/wake':return self.reply(200,wake_model())
            if self.path=='/rsi/shutdown':
                # Only the authenticated project launcher may request shutdown.
                (ROOT/'STOP').touch()
                return self.reply(200,{'stopping':True,'scope':'project service and CUDA model'})
            if self.path=='/v1/chat/completions':return self.inference(data)
            if self.path=='/rsi/calculate':return self.reply(200,arithmetic_evidence(data['expression']))
            if self.path=='/rsi/decide':return self.reply(200,local_decision(data))
            if self.path=='/rsi/memory/store':
                from memory_store import remember
                return self.reply(200,remember(data['title'],data['body'],data.get('kind','note'),data['source'],
                  scope=data.get('scope','project'),expires_at=data.get('expires_at')))
            if self.path=='/rsi/memory/search':
                from memory_store import retrieve
                return self.reply(200,retrieve(data['query'],data.get('limit',5),data.get('scope'),bool(data.get('semantic',False))))
            if self.path=='/rsi/memory/index':
                from semantic_memory import index
                return self.reply(200,index(data.get('limit',256),data.get('scope')))
            if self.path=='/rsi/memory/link':
                from memory_store import link
                return self.reply(200,link(data['subject'],data['relation'],data['object'],data['source_memory']))
            if self.path=='/rsi/memory/update':
                from memory_store import revise
                return self.reply(200,revise(data['memory_id'],data['body'],data['source']))
            if self.path=='/rsi/memory/revoke':
                from memory_store import revoke
                return self.reply(200,revoke(data['memory_id'],data['source']))
            if self.path=='/rsi/memory/purge':
                from memory_store import purge
                return self.reply(200,purge(data['memory_id'],data['confirmation'],data['source']))
            if self.path=='/rsi/unlearning/request':
                from unlearning import request
                return self.reply(200,request(data['target'],data['reason'],data.get('source','local agent request')))
            if self.path=='/rsi/unlearning/status':
                from unlearning import status
                return self.reply(200,status())
            if self.path=='/rsi/rewind/file':
                from project_agent import rewind
                return self.reply(200,rewind(data['project'],data['run_id'],data['confirmation']))
            if self.path=='/rsi/rewind/chat':
                from chat_rewind import rewind
                return self.reply(200,rewind(data['task_id'],data['confirmation']))
            if self.path=='/rsi/learn':return self.reply(200,queue_learning(data.get('reason','Local agent requested an experiment')))
            if self.path=='/rsi/evolve':return self.reply(200,queue_learning(data.get('reason','Local executable evolution request'),executable_only=True))
            if self.path=='/rsi/feedback':
                row={k:str(data[k])[:16000] for k in ('task','original_attempt','correction')}
                row.update(timestamp=now(),generation=champion()['id'],verification='unverified',training_eligible=False,
                  source='model-facing feedback tool; requires deterministic or user-confirmed admission')
                identity='feedback-'+digest(row)[:20];write_new(ROOT/'feedback'/(identity+'.json'),row)
                return self.reply(200,{'record':identity,'training_eligible':False,'status':'retained for review'})
            return self.reply(404,{'error':'Unavailable route'})
        except (BrokenPipeError,ConnectionResetError):pass
        except Exception as error:self.reply(400,{'error':str(error)})
    def inference(self,data):
        STATE['last_request']=time.time()
        with controller_lock(timeout=900):
            guard();generation=champion()
            from runtime_context import synchronize
            synchronize()
            ensure('inference',generation.get('adapter'))
            messages=data.get('messages')
            if not isinstance(messages,list):raise ValueError('Messages required')
            policy=generation.get('native_policy','')
            if policy:messages=[{'role':'system','content':policy},*messages]
            from memory_store import context
            last_user=next((m.get('content','') for m in reversed(messages) if m.get('role')=='user'),'')
            if isinstance(last_user,list):last_user=' '.join(x.get('text','') for x in last_user if isinstance(x,dict))
            retrieved=context(str(last_user))
            if retrieved:messages=[{'role':'system','content':retrieved},*messages]
            data={**data,'messages':messages,'model':'local-champion'}
            # Never let an agent choose adapters or change the release conditions.
            data.pop('lora',None);data.pop('lora_adapters',None)
            # The provider advertises the remaining local context window. Do not
            # impose a second 4096-token ceiling in the controller.
            configured=int(read(ROOT/'model.json').get('context',128512))
            requested=int(data.get('max_tokens',min(4096,configured)))
            data['max_tokens']=max(1,min(requested,configured))
            data.pop('max_completion_tokens',None)
            request_id='chat-'+str(time.time_ns());started=time.monotonic()
            conn=http.client.HTTPConnection('127.0.0.1',PORT,timeout=300);captured=bytearray();http_status=None
            try:
                (ROOT/'records/model-activity').touch()
                conn.request('POST','/v1/chat/completions',json.dumps(data).encode(),
                  {'Authorization':'Bearer '+KEY,'Content-Type':'application/json'})
                response=conn.getresponse();http_status=response.status
                self.send_response(response.status);self.send_header('Content-Type',response.getheader('Content-Type','application/json'))
                self.send_header('Connection','close');self.send_header('Cache-Control','no-store');self.end_headers();self.close_connection=True
                while chunk:=response.read1(8192):
                    if len(captured)+len(chunk)>32*2**20:raise ValueError('Response size limit')
                    captured.extend(chunk);self.wfile.write(chunk);self.wfile.flush()
            finally:
                conn.close();STATE['last_request']=time.time()
                write_new(ROOT/'traces'/(request_id+'.json'),{'id':request_id,'timestamp':now(),'generation':generation['id'],
                  'request':data,'response':captured.decode('utf-8',errors='replace'),'http_status':http_status,
                  'seconds':time.monotonic()-started,'verification':'unverified','training_eligible':False})

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--resume',action='store_true')
    parser.add_argument('--front-only',action='store_true',
      help='Serve only the local HTTP front (18803: /rsi/ui, /rsi/status, /rsi/memory/*, ...). '
           'Skips wake_model() and the bundled DeepSeek web application, so the Memory & learning '
           'panel mounted inside DSH works without the CUDA model and without a second browser UI.')
    args=parser.parse_args()
    with controller_lock('service.lock'):
        if args.resume:(ROOT/'STOP').unlink(missing_ok=True)
        guard()
        server=ThreadingHTTPServer(('127.0.0.1',FRONT_PORT),Handler);server.daemon_threads=True
        threading.Thread(target=server.serve_forever,daemon=True).start()
        if args.front_only:
            # Everything the panel calls (local_ui.dispatch: overview, memory,
            # memory-trash/history/detail, save/update/link/revoke/restore/purge,
            # evolution, lineage, correction, approve-answer, learning, evolve,
            # automatic) reads local records, SQLite and the filesystem. None of
            # it touches the model, so the model is deliberately not started.
            STATE.update(state='front-only')
            atomic(ROOT/'records/service.json',STATE)
            print('Local RSI front listening on http://127.0.0.1:%d (front-only; CUDA model not started)'%FRONT_PORT,flush=True)
            try:
                while not (ROOT/'STOP').exists():time.sleep(1)
            finally:
                SHUTDOWN.set();STATE['state']='stopped';atomic(ROOT/'records/service.json',STATE)
                server.shutdown();server.server_close();stop()
            return
        from deepseek_app import environment
        from agent_worker import NODE
        logs=ROOT/'deepseek/logs';logs.mkdir(parents=True,exist_ok=True)
        stamp=str(time.time_ns());stdout=logs/('web-'+stamp+'.stdout.log');stderr=logs/('web-'+stamp+'.stderr.log')
        proc=None
        try:
            wake_model()
            with stdout.open('wb') as out,stderr.open('wb') as err:
                proc=subprocess.Popen([str(NODE),'--import',(ROOT/'deepseek_guard.mjs').as_uri(),str(ROOT/'runtime/deepseek/lib/bin.js'),
                  '--profile','web','--host','127.0.0.1','--port','18801','--no-open'],
                  cwd=ROOT/'deepseek/work',env=environment(),stdin=subprocess.DEVNULL,stdout=out,stderr=err,creationflags=subprocess.CREATE_NO_WINDOW)
            STATE.update(state='running',app_pid=proc.pid,stdout=str(stdout),stderr=str(stderr))
            atomic(ROOT/'records/service.json',STATE)
            deadline=time.monotonic()+90
            while time.monotonic()<deadline:
                if proc.poll() is not None:raise RuntimeError('DeepSeek startup failed; '+str(stderr))
                text=stdout.read_text(encoding='utf-8',errors='replace')
                matches=re.findall(r'http://127\.0\.0\.1:18801/[^\s\x1b]*',text)
                if matches:
                    atomic(ROOT/'records/browser-launch.json',{'url':matches[-1],'timestamp':now(),'app_pid':proc.pid});break
                time.sleep(.5)
            else:raise RuntimeError('DeepSeek did not report its browser address')
            print('DeepSeek application ready; CUDA model starts independently.',flush=True)
            last_cycle=time.time();automatic_cycles=0
            # A restart must not erase evidence readiness or the cooldown.
            from datetime import datetime
            completed=learning_data().get('last_completed_comparison')
            if completed:last_cycle=datetime.fromisoformat(completed).timestamp()
            while not (ROOT/'STOP').exists() and proc.poll() is None:
                try:
                    from activity_store import sync
                    sync()
                    STATE.pop('activity_error',None)
                except Exception as error:
                    STATE['activity_error']=str(error)
                ready=learning_data()
                if learning_enabled() and ready.get('new_or_corrected_examples',0)>=16 and time.time()-STATE['last_request']>120 and time.time()-last_cycle>=7200 and automatic_budget_available():
                    queued=queue_learning('At least 16 new or corrected verified examples are ready; local agent is idle',True)
                    if queued['queued']:last_cycle=time.time();automatic_cycles+=1
                time.sleep(1)
        finally:
            SHUTDOWN.set();STATE['state']='stopped';atomic(ROOT/'records/service.json',STATE)
            if proc is not None and proc.poll() is None:proc.terminate();proc.wait(timeout=20)
            server.shutdown();server.server_close();stop()

if __name__=='__main__':main()
