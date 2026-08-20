#!/usr/bin/env python3
import json, os, subprocess, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs

HOST=os.getenv('IMONITOR_MONITOR_HOST','0.0.0.0')
PORT=int(os.getenv('IMONITOR_MONITOR_PORT','10000'))
POLICY=Path(os.getenv('IMONITOR_RELEASE_POLICY','/opt/imonitor-erp/policy/update.env'))
REPO='alimirzae/iMonitor-ERP'


def run(cmd, timeout=8):
    try:
        p=subprocess.run(cmd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout,check=False)
        return p.stdout.strip()
    except Exception as e:
        return f'[error] {e}'


def load_policy():
    data={}
    if POLICY.exists():
        for line in POLICY.read_text().splitlines():
            if '=' in line and not line.startswith('#'):
                k,v=line.split('=',1); data[k]=v
    return data


def save_policy(data):
    POLICY.parent.mkdir(parents=True,exist_ok=True)
    order=['IMONITOR_RELEASE_CHANNEL','IMONITOR_SOURCE_CHANNEL','IMONITOR_UPDATE_MINUTES','IMONITOR_UPDATE_WINDOW_START','IMONITOR_UPDATE_WINDOW_END','IMONITOR_UPDATE_TIMEZONE','IMONITOR_DASHBOARD_PORT']
    POLICY.write_text('\n'.join(f'{k}={data.get(k,"")}' for k in order)+'\n')


def health(port):
    raw=run(['curl','-fsS','--max-time','2',f'http://127.0.0.1:{port}/health'],3)
    try:return json.loads(raw)
    except:return {'status':'offline','raw':raw}


def github_head():
    raw=run(['gh','api',f'repos/{REPO}/branches/test','--jq','.commit.sha'],6)
    return raw if raw and not raw.startswith('[error]') else None


def snapshot():
    p=load_policy()
    head=github_head()
    test=health(8081)
    local_sha=test.get('git_sha') if isinstance(test,dict) else None
    return {
      'time':time.strftime('%Y-%m-%d %H:%M:%S'),
      'policy':p,
      'runner':run(['bash','-lc',"ps -eo pid,etimes,%cpu,%mem,cmd --sort=-%cpu | grep -E 'Runner.Listener|Runner.Worker|docker build|pytest|alembic|docker compose' | grep -v grep || true"]),
      'docker':run(['docker','ps','-a','--format','{{.Names}} | {{.Image}} | {{.Status}} | {{.Ports}}']),
      'githubRuns':run(['gh','run','list','--repo',REPO,'--branch','test','--limit','8']) if run(['bash','-lc','command -v gh >/dev/null && echo yes'])=='yes' else 'gh not installed',
      'testHealth':test,
      'stableHealth':health(8080),
      'githubTestHead':head,
      'localMatchesLatestTest': bool(head and local_sha and head==local_sha),
    }

HTML='''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>iMonitor ERP Dev Center</title><style>body{font-family:system-ui;background:#0b1220;color:#e5e7eb;margin:0}header{padding:16px 20px;background:#111827;position:sticky;top:0}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(380px,1fr));gap:12px;padding:12px}.c{background:#111827;border:1px solid #263244;border-radius:12px;padding:14px}pre{white-space:pre-wrap;word-break:break-word;font-size:12px}.ok{color:#86efac}.bad{color:#fca5a5}input,select,button{padding:8px;border-radius:8px;border:1px solid #475569;background:#0f172a;color:#fff;margin:4px}button{cursor:pointer}</style></head><body><header><b>iMonitor ERP Developer Control Center</b> — localhost:10000 <span id="match"></span></header><div class="grid"><div class="c"><h3>Update policy</h3><form id="f"><label>Channel <select name="channel"><option>development</option><option>test</option><option>stable</option></select></label><br><label>Check minutes <input name="minutes" type="number" min="1"></label><br><label>Stable window <input name="start" type="time"> تا <input name="end" type="time"></label><br><label>Timezone <input name="tz" value="Asia/Tehran"></label><br><button>Save</button><button type="button" onclick="forceUpdate()">Force update now</button></form></div><div class="c"><h3>Test health</h3><pre id="test"></pre></div><div class="c"><h3>Stable health</h3><pre id="stable"></pre></div><div class="c"><h3>Runner activity</h3><pre id="runner"></pre></div><div class="c"><h3>GitHub Actions</h3><pre id="runs"></pre></div><div class="c"><h3>Docker</h3><pre id="docker"></pre></div></div><script>
async function load(){let d=await (await fetch('/api/status')).json();test.textContent=JSON.stringify(d.testHealth,null,2);stable.textContent=JSON.stringify(d.stableHealth,null,2);runner.textContent=d.runner;runs.textContent=d.githubRuns;docker.textContent=d.docker;match.textContent=d.localMatchesLatestTest?'✓ localhost test = latest test HEAD':'⚠ localhost test differs from latest test HEAD';match.className=d.localMatchesLatestTest?'ok':'bad';let p=d.policy;f.channel.value=p.IMONITOR_RELEASE_CHANNEL||'test';f.minutes.value=p.IMONITOR_UPDATE_MINUTES||5;f.start.value=p.IMONITOR_UPDATE_WINDOW_START||'02:00';f.end.value=p.IMONITOR_UPDATE_WINDOW_END||'05:00';f.tz.value=p.IMONITOR_UPDATE_TIMEZONE||'Asia/Tehran'}
f.onsubmit=async e=>{e.preventDefault();let x=new URLSearchParams(new FormData(f));await fetch('/api/policy',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:x});load()};async function forceUpdate(){await fetch('/api/force-update',{method:'POST'});setTimeout(load,1500)}load();setInterval(load,3000)</script></body></html>'''

class H(BaseHTTPRequestHandler):
    def sendj(self,obj,code=200):
        b=json.dumps(obj,ensure_ascii=False).encode();self.send_response(code);self.send_header('Content-Type','application/json; charset=utf-8');self.end_headers();self.wfile.write(b)
    def do_GET(self):
        if self.path=='/api/status': return self.sendj(snapshot())
        if self.path=='/':
            b=HTML.encode();self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.end_headers();self.wfile.write(b);return
        self.send_error(404)
    def do_POST(self):
        n=int(self.headers.get('Content-Length','0')); body=self.rfile.read(n).decode(); q=parse_qs(body)
        if self.path=='/api/policy':
            p=load_policy(); ch=q.get('channel',['test'])[0]; p['IMONITOR_RELEASE_CHANNEL']=ch; p['IMONITOR_SOURCE_CHANNEL']='main' if ch=='stable' else ch; p['IMONITOR_UPDATE_MINUTES']=q.get('minutes',['5'])[0]; p['IMONITOR_UPDATE_WINDOW_START']=q.get('start',['02:00'])[0]; p['IMONITOR_UPDATE_WINDOW_END']=q.get('end',['05:00'])[0]; p['IMONITOR_UPDATE_TIMEZONE']=q.get('tz',['Asia/Tehran'])[0]; p['IMONITOR_DASHBOARD_PORT']=str(PORT); save_policy(p); return self.sendj({'ok':True})
        if self.path=='/api/force-update':
            p=load_policy(); ch=p.get('IMONITOR_RELEASE_CHANNEL','test'); cmd=f"curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP.sh | sudo bash -s -- --channel {ch} --force-update"; subprocess.Popen(['bash','-lc',cmd],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); return self.sendj({'ok':True,'started':True})
        self.send_error(404)
    def log_message(self,*a):pass

ThreadingHTTPServer((HOST,PORT),H).serve_forever()
