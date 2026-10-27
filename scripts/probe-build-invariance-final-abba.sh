#!/usr/bin/env bash
# Temporary D-C21 item6 diagnostic. Never merge; never replace required CI.
set -euo pipefail
exec python3 - "$0" "$@" <<'PY'
import collections,csv,datetime,gzip,hashlib,json,math,os,re,shutil,signal,stat,subprocess,sys,tarfile,tempfile,time
from pathlib import Path
SCRIPT=Path(sys.argv[1]).resolve();ARGS=sys.argv[2:]
A='4fd133373a3f674cbcc9d6a3548f036d5150ca57';B='22b7bfc90865dab1fe52a95b6b9db4d81c7d110d'
TREES={A:'e38496dbe7c12fef07c5b6e2cbe8809ed3a37767',B:'ba5cb24a4668643711fd7723e81daa2f198b1924'}
ORDER=[('A1',A),('B1',B),('B2',B),('A2',A)]
DIFF=['.github/workflows/ci.yml','perf/README.md','scripts/check-build-invariance.sh','scripts/lib-build-invariance-batch.sh','scripts/verify-build-invariance-batch.sh','src/TESTING.md']
SEED_TAG='stage0-20261026-232414-r40416526969';SEED_SHA='97f3341e65bdf36a24d01260cc34379a58d0975afca8567e57eb1d35ea03570c'
class Failure(Exception):pass
def need(ok,msg):
 if not ok:raise Failure(msg)
def atomic_text(p,text):
 p.parent.mkdir(parents=True,exist_ok=True)
 with tempfile.NamedTemporaryFile(mode='w',prefix=p.name+'.publishing.',dir=p.parent,delete=False)as f:
  f.write(text);f.flush();os.fsync(f.fileno());temp=Path(f.name)
 # Publishing a metadata update is atomic; failed temporary files are retained.
 os.replace(temp,p)
def dump(p,v):atomic_text(p,json.dumps(v,indent=2)+'\n')
def sha(p):
 h=hashlib.sha256()
 with p.open('rb')as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
def same(a,b):
 if a.stat().st_size!=b.stat().st_size:return False
 with a.open('rb')as x,b.open('rb')as y:
  while True:
   u=x.read(1048576);v=y.read(1048576)
   if u!=v:return False
   if not u:return True
def owned(p,root):
 root=root.resolve(strict=True);p=Path(p)
 need(root!=Path('/')and root.is_dir()and not root.is_symlink(),'invalid owned root')
 need(p.is_absolute()and root in p.parents,'path outside owned root: '+str(p))
 for q in [p,*list(p.parents)[:list(p.parents).index(root)]]:need(not q.is_symlink(),'symlink in owned path: '+str(q))
 return p
def regular(p):need(p.is_file()and not p.is_symlink()and p.stat().st_size>0,'missing/empty/symlink output: '+str(p))
def kv(p,sep='='):return dict(l.split(sep,1)for l in p.read_text().splitlines()if sep in l)
def command(args,cwd=None,env=None,timeout=120):return subprocess.check_output([str(x)for x in args],cwd=cwd,env=env,timeout=timeout,text=True).strip()
def git(root,*args):return command(['git','-C',root,*args])
def dt(s):return datetime.datetime.fromisoformat(s.replace('Z','+00:00')).timestamp()
def identity():return {'boot':Path('/proc/sys/kernel/random/boot_id').read_text().strip(),'affinity':sorted(os.sched_getaffinity(0)),'runner':os.getenv('RUNNER_NAME'),'image':os.getenv('ImageVersion')}
def expected_corpus(source):
 result=['selfhost_main_opt1|src/main.tl|1','selfhost_main_opt2|src/main.tl|2']
 for line in(source/'tests/integration/native.manifest').read_text().splitlines():
  if not line or line.startswith('#'):continue
  f=line.split('|');need(len(f)in(9,10),'malformed manifest')
  if f[1]not in('all','linux'):continue
  levels=f[2].split(',')
  for n in levels:result.append('integration_'+(f[0]if n=='-'or len(levels)==1 else f[0]+'_opt'+n)+'|'+f[3]+'|2')
 return result

def audit(trial,source,variant,reference=None,mock=False):
 raw=trial/'raw';original=source/'target/build-invariance';corpus=(raw/'corpus.txt').read_text().splitlines()
 need(corpus==expected_corpus(source),'corpus differs from authoritative manifest');need(len(set(corpus))==len(corpus),'duplicate corpus')
 need(len(corpus)==(5 if mock else 1805),'unexpected full inventory')
 outputs={};plans={};selfhost_jobs=set();expected_reports={'backend-tests.memory':8192};expected_queue={'backend-tests':'8192'};chunks={};chunk_total=0
 for prod in('opt1-built','opt2-built'):
  base=raw/'batches'/prod;prepared=[]
  for line in corpus:
   name,src,opt=line.split('|');actual=str(original/'inputs/integration_sym_i64_env/sym_i64_env/sym_i64_env.tl')if name=='integration_sym_i64_env'else src
   out=str(original/'compare'/prod/(name+'.s'));prepared.append('|'.join([name,src,actual,out,opt]));rel='compare/'+prod+'/'+name+'.s';p=owned(raw/rel,raw);regular(p);outputs[rel]=p
  need((base/'cases.txt').read_text().splitlines()==prepared,'prepared identity mismatch');ne=na=nc=0;producer_jobs=[]
  for opt in('1','2'):
   op=base/('opt'+opt);want=[x for x in prepared if x.split('|')[4]==opt];need((op/'cases.txt').read_text().splitlines()==want,'opt inventory');allrows=[]
   for cp in sorted((op/'chunks').glob('cases.*.txt')):
    records=cp.read_text().splitlines();need(0<len(records)<=64,'chunk logical ceiling');allrows+=records;canonical={};entries=[];aliases=[]
    for row in records:
     name,src,actual,out,level=row.split('|');need(level==opt,'mixed opt')
     if actual in canonical:aliases.append(canonical[actual]+'|'+out)
     else:canonical[actual]=out;entries.append(actual+'|'+out)
    suffix=cp.name.split('.')[1];need((cp.parent/('entries.'+suffix+'.txt')).read_text().splitlines()==entries,'canonical plan mismatch');need((cp.parent/('aliases.'+suffix+'.txt')).read_text().splitlines()==aliases,'alias plan mismatch')
    for alias in aliases:
     left,right=alias.split('|');lp=owned(raw/Path(left).relative_to(original),raw);rp=owned(raw/Path(right).relative_to(original),raw);regular(lp);regular(rp);need(same(lp,rp),'alias bytes differ')
    isself=len(records)==1 and records[0].split('|')[0]in('selfhost_main_opt1','selfhost_main_opt2');codegen=all(x.split('|')[2]=='src/tests/compiler_codegen_smoke_suite.tl'for x in records)
    job=prod+'.opt'+opt+'.'+suffix;cap=8192 if isself or codegen else 4096
    chunks[job]={'records':records,'selfhost':isself,'cap_mib':cap,'deadline_s':1200 if isself and variant=='B'else(None if isself else 600)}
    producer_jobs.append(job)
    if isself:selfhost_jobs.add(job)
    if not isself or variant=='B':
     expected_reports['codegen-smoke.memory'if prod=='opt1-built'and codegen else prod+'.opt'+opt+'.chunk'+suffix+'.memory']=cap;expected_queue[job]=str(cap)
    ne+=len(entries);na+=len(aliases);nc+=1
   need(allrows==want,'chunk coverage mismatch')
  need(nc==(3 if mock else(95 if variant=='A'else 59)),'chunk count');need(ne==(4 if mock else(895 if variant=='A'else 859)),'canonical count')
  plans[prod]={'logical':len(corpus),'chunks':nc,'entries':ne,'aliases':na};chunk_total+=nc
  for ordinal,job in enumerate(producer_jobs,1):chunks[job]['ordinal']=str(ordinal)+'/'+str(nc)
 need(len(selfhost_jobs)==4,'selfhost identities')
 for line in corpus:
  name=line.split('|')[0];need(same(outputs['compare/opt1-built/'+name+'.s'],outputs['compare/opt2-built/'+name+'.s']),'cross-producer mismatch '+name)
 # All standalone outputs and complete compiler/backend outputs are compared too.
 for prod in('opt1-built','opt2-built'):
  for name in('integration_aggregate_globals','integration_sym_i64_env'):
   rel='sentinels/'+prod+'/'+name+'.standalone.s';p=owned(raw/rel,raw);regular(p);need(same(p,outputs['compare/'+prod+'/'+name+'.s']),'sentinel mismatch');outputs[rel]=p
 for rel in('opt1/opt1','backend-memory/backend-tests'):
  p=owned(raw/rel,raw);regular(p);outputs[rel]=p
 marker=trial/'handoff.path';need(marker.read_text().strip()==str(original/'compare/opt2-built/selfhost_main_opt1.s'),'handoff identity')
 memfiles={p.name:p for p in(raw/'backend-memory').glob('*.memory')};need(set(memfiles)==set(expected_reports),'missing/extra enforced report')
 reports={}
 for name,p in memfiles.items():
  v=kv(p);need(v.get('schema_version')=='1'and v.get('host')=='linux'and v.get('backend')=='systemd-user-cgroup'and v.get('reason')=='success'and v.get('exit_code')=='0','failed enforced report '+name)
  peak,cap,wall=[int(v[k])for k in('peak_memory_bytes','limit_bytes','wall_ms')];need(0<peak<cap==expected_reports[name]*1048576,'invalid enforced headroom '+name)
  reports[name]={'wall_ms':wall,'peak_bytes':peak,'cap_bytes':cap}
 queue=dict(l.split('|')for l in(raw/'pool-queue.txt').read_text().splitlines());results=raw/'pool/results'
 need(queue==expected_queue,'queue identity/cap mismatch');need(set(p.name for p in results.iterdir())==set(queue),'missing/extra pool result')
 need(all((results/j).read_text().strip()=='0'for j in queue),'unsuccessful pool result')
 metrics=(raw/'chunk-metrics.tsv').read_text().splitlines();need(len(metrics)==chunk_total,'chunk metrics incomplete')
 metricmap={tuple(x.split('\t')[k]for k in(1,2,3)):int(x.split('\t')[0])for x in metrics};need(len(metricmap)==chunk_total,'duplicate chunk metric')
 if not mock:
  for job,c in chunks.items():c['wall_ms']=metricmap[(job.split('.')[0],job.split('.')[1][3:],c['ordinal'])]
 timing=list(csv.DictReader((trial/'timing.tsv').open(),delimiter='\t'));compare=[x for x in timing if x['phase']=='compare'];need([x['case_or_chunk']for x in compare]==[x.split('|')[0]for x in corpus]and all(x['exit']=='0'for x in compare),'comparison receipts incomplete')
 selftiming=[x for x in timing if x['phase']=='compile'and ':selfhost_main_'in x['case_or_chunk']];need(len(selftiming)==4 and all(x['exit']=='0'for x in selftiming),'selfhost timing labels')
 need(len(re.findall(r'\[build-invariance\] (?:opt1-built|opt2-built) standalone sentinel integration_', (trial/'gate.log').read_text()))==4,'sentinel receipts')
 compared=0
 if reference is not None:
  expected=json.loads((reference/'audit.json').read_text())['output_inventory'];need(set(expected)==set(outputs),'cross-trial output set differs')
  for rel,p in outputs.items():need(same(p,reference/'raw'/rel),'cross-trial byte mismatch '+rel);compared+=1
 inventory={rel:{'sha256':sha(p),'bytes':p.stat().st_size}for rel,p in sorted(outputs.items())}
 prov=kv(raw/'provenance.txt')if(raw/'provenance.txt').exists()else None
 if variant=='B':need(prov is not None and prov['logical_cases']==str(len(corpus))and prov['pool_workers']=='2','missing F1 provenance')
 construction_ms=sum(int(x['elapsed_ms'])for x in timing if x['case_or_chunk']=='compiler-opt1'and x['phase']in('compile','assemble-link'))
 if not mock:need(construction_ms>0,'missing unchanged compiler-construction timing')
 result={'variant':variant,'coverage':plans,'comparisons':len(corpus),'producer_sides':len(corpus)*2,'enforced_reports':reports,'pool_results':len(queue),'selfhost_jobs':sorted(selfhost_jobs),'chunks':chunks,'output_inventory':inventory,'cross_trial_exact_comparisons':compared,'opt1_sha256':sha(raw/'opt1/opt1'),'compiler_construction_ms':construction_ms,'selfhost_timings':selftiming,'provenance':prov}
 dump(trial/'audit.json',result);return result

def cas_add(p,work,index_key,index,freeze=False):
 need(p.is_file()and not p.is_symlink(),'invalid CAS input');digest=sha(p);cas=work/'evidence/cas';cas.mkdir(exist_ok=True);dest=owned(cas/digest,work)
 if dest.exists():need(same(p,dest),'CAS collision')
 else:
  if freeze:
   with p.open('rb')as src,dest.open('xb')as out:shutil.copyfileobj(src,out,1048576)
  else:os.link(p,dest)
 index[index_key]={'sha256':digest,'bytes':p.stat().st_size}
def raw_cas_path(relative):
 return relative.suffix in('.s','.o')or relative.as_posix()in('opt1/opt1','backend-memory/backend-tests')
def evidence_cas_path(relative):
 parts=relative.parts
 return len(parts)>=4 and parts[0]=='trials'and parts[2]=='raw'and raw_cas_path(Path(*parts[3:]))

def auxiliary_files(work):
 result=[]
 for p in(work/'toolchain').glob('*'):
  if p.is_file()and not p.is_symlink():result.append(p)
 source=work/'source'
 for directory in('target/build-stage0','target/embedded-stdlib-tlci'):
  for p in(source/directory).rglob('*'):
   if p.is_file()and not p.is_symlink():result.append(p)
 for p in(source/'target/bootstrap-fixpoint').rglob('*'):
  if p.is_file()and not p.is_symlink():result.append(p)
 for name in('ci-verify-stage1.path','ci-verify-stage2.path'):
  p=source/'target'/name
  if p.is_file()and not p.is_symlink():result.append(p)
 return sorted(set(result))
def capture_auxiliary(work):
 index={}
 for p in auxiliary_files(work):cas_add(p,work,str(p.relative_to(work)),index,freeze=True)
 dump(work/'evidence/bootstrap-content-index.json',index)
 return index

def pack(work,inject_failure=False):
 work=work.resolve(strict=True);e=work/'evidence';need(e.is_dir(),'missing evidence');initial=e/'bootstrap-content-index.json';index=json.loads(initial.read_text())if initial.exists()else{}
 if inject_failure=='before-index':raise Failure('injected index failure')
 for trial in sorted((e/'trials').glob('*')):
  raw=trial/'raw'
  if not raw.exists():continue
  for p in raw.rglob('*'):
   if p.is_file()and not p.is_symlink()and raw_cas_path(p.relative_to(raw)):
    cas_add(p,work,str(p.relative_to(e)),index)
 for p in auxiliary_files(work):
  key=str(p.relative_to(work))
  if key in index and index[key]['sha256']!=sha(p):key='final/'+key
  cas_add(p,work,key,index,freeze=True)
 dump(e/'content-index.json',index);archive=owned(work/'evidence.partial.tar.gz',work);complete=owned(work/'evidence.complete.tar.gz',work);need(not archive.exists()and not complete.exists(),'stale archive')
 with archive.open('xb')as f,gzip.GzipFile(fileobj=f,mode='wb',compresslevel=1)as gz,tarfile.open(fileobj=gz,mode='w|')as tar:
  for p in sorted(e.rglob('*')):
   if not p.is_file()or p.is_symlink():continue
   rel=p.relative_to(e);parts=rel.parts
   # Exactly the same path predicate selects CAS contents and tar exclusions.
   if evidence_cas_path(rel):
    need(str(rel)in index,'archive would drop evidence '+str(rel));continue
   tar.add(p,arcname=str(rel),recursive=False)
   if inject_failure:raise Failure('injected archive failure')
 dump(e/'archive.json',{'complete':True,'sha256':sha(archive),'bytes':archive.stat().st_size,'logical_content_files':len(index),'unique_blobs':len(list((e/'cas').iterdir()))})
 archive.rename(complete)

def upload_paths(work):
 complete=work/'evidence.complete.tar.gz';manifest=work/'evidence/archive.json'
 if complete.is_file()and manifest.is_file()and json.loads(manifest.read_text()).get('complete'):
  paths=[str(complete),str(work/'evidence/*.json'),str(work/'evidence/pack/**')];kind='complete_archive'
 else:
  # Complete raw/CAS fallback also works if CAS/index construction itself failed.
  paths=[str(work/'evidence/**'),str(work/'toolchain/**'),str(work/'source/target/**')];kind='raw_reconstructible_fallback'
 dump(work/'evidence/upload-selection.json',{'kind':kind,'paths':paths,'partial_archive_is_not_complete':True})
 return paths

def fingerprint(source):
 paths=set(git(source,'ls-files','-z','--cached','--others','--exclude-standard','--','src','stdlib','tests').split('\0'));paths.discard('')
 # Prose differs across A/F1. Only compiled/generated inputs enter this common key.
 paths={p for p in paths if p!='src/TESTING.md'}
 for d in('src','stdlib'):
  paths.update(str(p.relative_to(source))for p in(source/d).rglob('*.tl')if 'target'not in p.relative_to(source/d).parts)
 paths.add('tests/integration/wide_struct_literal_decls.tl')
 for directory in('target/build-stage0','target/embedded-stdlib-tlci'):
  for p in(source/directory).rglob('*'):
   if p.is_file():paths.add(str(p.relative_to(source)))
 h=hashlib.sha256()
 for p in sorted(paths):
  f=source/p
  if not f.exists():continue
  need(not f.is_symlink(),'symlink source input');h.update(p.encode()+b'\0'+bytes.fromhex(sha(f)))
 return h.hexdigest()

def payload(args):
 out=Path(args[0]);cwd=Path(args[1]);cpus=[int(x)for x in args[2].split(',')];useperf=args[3]=='1';cmd=args[4:];need(cmd and out.is_dir(),'payload args');os.sched_setaffinity(0,set(cpus))
 cg=Path('/proc/self/cgroup').read_text().strip();node=os.getenv('TYPELISP_LINUX_MEMORY_LIMIT_NODE');need(cg.startswith('0::')and node,'missing bounded hierarchy')
 units=re.findall(r'(?:^|/)(run-[^/]+\.service)(?:/|$)',cg[3:]);need(len(units)==1,'no exact enclosing run service')
 atomic_text(out/'service.unit',units[0]+'\n')
 dump(out/'payload.json',{'pid':os.getpid(),'cgroup':cg[3:],'node':node,'service':units[0],'identity':identity()})
 cpu=[os.getenv('PROBE_TIME_BIN','/usr/bin/time'),'-f','wall_seconds=%e\nuser_seconds=%U\nsystem_seconds=%S','-o',str(out/'cpu.tsv')]
 if useperf:cpu+=['perf','stat','-x','\t','--no-big-num','-e','cycles:u,instructions:u','-o',str(out/'perf.tsv'),'--']
 os.chdir(cwd);os.execvp(cpu[0],cpu+cmd)

def sample_telemetry(out):
 sample={'monotonic_s':time.monotonic(),'errors':{}}
 def read(path):
  try:return path.read_text().strip()
  except (OSError,ValueError)as ex:sample['errors'][str(path)]=repr(ex);return None
 sample['load']=read(Path('/proc/loadavg'));cpu=read(Path('/proc/stat'));sample['cpu']=cpu.splitlines()[0]if cpu else None;mem=read(Path('/proc/meminfo'));sample['meminfo']=[l for l in mem.splitlines()if l.startswith(('MemAvailable:','SwapFree:'))]if mem else None
 pp=out/'payload.json'
 if pp.exists():
  node=Path(json.loads(pp.read_text())['node']);need(str(node).startswith('/sys/fs/cgroup/'),'invalid node');sample['cgroup']={}
  for key in('memory.current','memory.peak','memory.events','memory.pressure','cpu.stat','cpu.pressure'):sample['cgroup'][key]=read(node/key)
 return sample

class Runner:
 def __init__(self,root,work,job):
  self.root=root;self.work=work;self.job=job;self.active=None;self.proc=None;self.service=None;self.identity=identity();self.deadline=time.monotonic()+max(0,dt(job['started_at'])+140*60-time.time());self.final_deadline=self.deadline+8*60
 def stop(self):
  if self.active is None:return
  proc=self.proc
  if proc is None:
   # Popen did not create a wrapper; no unit launch occurred.
   need(self.service is None,'service handle without wrapper');self.active=None;return
  # The independently managed service can outlive its systemd-run client.
  # Receipt discovery therefore never depends on wrapper liveness.
  until=time.monotonic()+5;receipt=self.active/'service.unit'
  while self.service is None and not receipt.is_file()and time.monotonic()<until:time.sleep(.05)
  if self.service is None:
   need(receipt.is_file(),'exact unit receipt missing;ownership retained')
   self.service=receipt.read_text().strip()
  unit=self.service;need(re.fullmatch(r'run-[A-Za-z0-9_.-]+\.service',unit)is not None,'invalid unit')
  with(self.work/'evidence/stop.log').open('a')as log:
   stopped=subprocess.run(['systemctl','--user','stop',unit],stdout=log,stderr=subprocess.STDOUT,timeout=25)
  # A collected unit makes stop return nonzero. Only positive inactive/empty
  # evidence permits release; a bus error or still-populated node does not.
  shown=subprocess.run(['systemctl','--user','show','--property=LoadState','--property=ActiveState','--property=ControlGroup',unit],capture_output=True,text=True,timeout=10)
  props=dict(l.split('=',1)for l in shown.stdout.splitlines()if'='in l)
  proof={'unit':unit,'stop_exit':stopped.returncode,'show_exit':shown.returncode,'properties':props,'show_stderr':shown.stderr,'wrapper_status':proc.poll()}
  dump(self.active/'termination.json',proof)
  need(props.get('LoadState')in('loaded','not-found')and props.get('ActiveState')in('inactive','failed'),'service termination not positively established;ownership retained')
  cg=props.get('ControlGroup');need(cg is not None,'missing cgroup termination property')
  if cg:
   need(cg.startswith('/')and ('/'+unit)in cg,'unexpected service cgroup')
   try:
    events=dict(l.split()for l in(Path('/sys/fs/cgroup')/cg.lstrip('/')/'cgroup.events').read_text().splitlines())
   except FileNotFoundError:events={'populated':'0','source':'inactive cgroup removed'}
   proof['cgroup_events']=events;dump(self.active/'termination.json',proof)
   need(events.get('populated')=='0','service cgroup still populated;ownership retained')
  proc.wait(timeout=30)
  self.proc=None;self.service=None;self.active=None
 def bounded(self,out,cwd,cmd,limit=6080,ceiling=2700,perf=False,final=False,env_extra=None):
  out.mkdir(parents=True,exist_ok=True);need(not(out/'phase.json').exists(),'repeated phase')
  remaining=(self.final_deadline if final else self.deadline)-time.monotonic();seconds=min(ceiling,int(remaining));need(seconds>0,'budget exhausted before phase')
  env=os.environ.copy();env.pop('BASH_ENV',None);env.update(env_extra or{});env['PROBE_TIME_BIN']='/usr/bin/time';env['LC_ALL']='C';cpus=','.join(str(x)for x in self.identity['affinity'])
  args=['env','-u','BASH_ENV',str(self.root/'scripts/run-memory-bounded.sh'),'--limit-mib',str(limit),'--timeout-seconds',str(seconds),'--report',str(out/'phase.memory'),'--','env','-u','BASH_ENV','bash',str(SCRIPT),'--payload',str(out),str(cwd),cpus,str(int(perf)),*map(str,cmd)]
  self.active=out;t=time.monotonic();status=None;proc=None;dump(out/'command.json',{'argv':args,'limit_mib':limit,'timeout_s':seconds})
  try:
   with(out/'gate.log').open('w')as log,(out/'telemetry.jsonl').open('w')as trace:
    proc=subprocess.Popen(args,cwd=cwd,env=env,stdout=log,stderr=subprocess.STDOUT);self.proc=proc
    while proc.poll()is None:
     sample=sample_telemetry(out)
     trace.write(json.dumps(sample)+'\n');trace.flush()
     if time.monotonic()>t+seconds+20:self.stop()
     time.sleep(.5)
    status=proc.poll();self.stop()
  except BaseException:
   # Monitoring/logging/receipt errors must stop and reap before any archival.
   try:self.stop()
   finally:
    if proc is not None and proc.poll()is not None:status=proc.returncode
   raise
  finally:
   dump(out/'phase.json',{'exit':status,'wall_s':time.monotonic()-t,'budget_timeout_s':seconds,'limit_mib':limit,'status':'success'if status==0 else'failed_or_interrupted'})
  need(status==0,'bounded phase failed '+str(out)+': '+str(status));need(identity()==self.identity,'runner identity/affinity changed')
  report=kv(out/'phase.memory');need(report['reason']=='success'and report['exit_code']=='0'and report['backend']=='systemd-user-cgroup'and 0<int(report['peak_memory_bytes'])<int(report['limit_bytes'])==limit*1048576,'outer resource report invalid')
  pp=json.loads((out/'payload.json').read_text());need(pp['identity']==self.identity,'payload affinity/runner differs')

def run_job(root,work):
 need(os.getenv('GITHUB_ACTIONS')=='true'and os.getenv('RUNNER_OS')=='Linux','hosted only');need(os.getenv('GITHUB_BASE_REF')=='t3/issue-7767-build-invariance-critical-path','wrong PR base');need(os.getenv('GITHUB_RUN_ATTEMPT')=='1','no reruns allowed')
 need(work==root/'target/issue7767-final-abba','unexpected scratch path');(root/'target').mkdir(exist_ok=True);need((root/'target').resolve()==root/'target','outer target escapes checkout');need(not work.exists(),'scratch not fresh');work.mkdir();e=work/'evidence';(e/'trials').mkdir(parents=True);(work/'toolchain').mkdir();dump(e/'status.json',{'status':'setup','trials':{n:'not_started'for n,_ in ORDER}})
 need(git(root,'rev-parse','HEAD')==os.environ['PROBE_EXPECTED_HEAD'],'diagnostic head mismatch');need(git(root,'merge-base','HEAD','0216b73b00e440c74663af1c1017127f4cf8db13')=='0216b73b00e440c74663af1c1017127f4cf8db13','wrong diagnostic base');need(git(root,'diff','--name-only','0216b73b00e440c74663af1c1017127f4cf8db13','HEAD').splitlines()==['.github/workflows/issue7767-final-abba.yml','scripts/probe-build-invariance-final-abba.sh'],'unexpected diagnostic diff');need(len(os.sched_getaffinity(0))==4,'expected4CPU allocation')
 need(Path('/usr/bin/time').is_file(),'GNU Time missing');need(command(['/usr/bin/time','--version']).startswith('time (GNU Time)'),'unsupported time tool')
 need(git(root,'diff','--name-only',A,B).splitlines()==DIFF,'unexpected experiment diff')
 for ref in(A,B):need(git(root,'rev-parse',ref+'^{tree}')==TREES[ref],'tree mismatch')
 meta=json.loads(command(['gh','api',f"repos/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}/jobs"]))
 jobs=[j for j in meta['jobs']if j['name']=='Full-corpus base F1 F1 base'];need(len(jobs)==1 and jobs[0]['started_at'],'job identity missing');job=jobs[0];dump(e/'job.json',job)
 dump(e/'environment.json',{'identity':identity(),'uname':command(['uname','-a']),'lscpu':command(['lscpu']),'as':command(['as','--version']),'ld':command(['ld','--version']),'time':command(['/usr/bin/time','--version']),'disk':shutil.disk_usage(work)._asdict(),'meminfo':Path('/proc/meminfo').read_text(),'perf_paranoid':Path('/proc/sys/kernel/perf_event_paranoid').read_text(),'scope':'complete Linux build-invariance only;not outergraph/Windows/SDEexecution or terminal milestone'})
 runner=Runner(root,work,job);state={'status':'setup','trials':{n:'not_started'for n,_ in ORDER}};source=work/'source';current=None;packed=False
 def interrupted(sig,frame):
  for value in(signal.SIGTERM,signal.SIGINT,signal.SIGHUP):signal.signal(value,signal.SIG_IGN)
  try:runner.stop()
  finally:
   for value in(signal.SIGTERM,signal.SIGINT,signal.SIGHUP):signal.signal(value,interrupted)
  raise Failure('signal '+str(sig))
 for sig in(signal.SIGTERM,signal.SIGINT,signal.SIGHUP):signal.signal(sig,interrupted)
 try:
  git(root,'worktree','add','--detach',str(source),A);need(source.resolve()==source,'source symlink');(source/'target').mkdir(exist_ok=True);need((source/'target').resolve()==source/'target','target symlink')
  seedmeta=json.loads(command(['gh','api',f'repos/JoNil-Botta/typelisp/releases/tags/{SEED_TAG}']));need(seedmeta['id']==424875273,'seed release changed');dump(e/'seed-release.json',seedmeta)
  command(['gh','release','download',SEED_TAG,'--repo','JoNil-Botta/typelisp','--pattern','typelisp-stage0-linux','--pattern','SHA256SUMS','--dir',str(work/'toolchain')])
  seed=work/'toolchain/typelisp-stage0-linux';need(sha(seed)==SEED_SHA and seed.stat().st_size==9989512,'seed bytes mismatch');need(any(len(l.split())==2 and l.split()[0]==SEED_SHA and l.split()[1].lstrip('*')=='typelisp-stage0-linux'for l in(work/'toolchain/SHA256SUMS').read_text().splitlines()),'seed manifest mismatch');seed.chmod(0o700)
  runner.bounded(e/'bootstrap',source,['bash','scripts/ci-verify.sh','--gates','bootstrap-fixpoint'],limit=8128,ceiling=1200,env_extra={'TYPELISP_BIN':str(seed),'TYPELISP_INLINE_TEST_WORKERS':'1','TYPELISP_BUILD_INVARIANCE_WORKERS':'1'})
  converged=Path((source/'target/ci-verify-stage2.path').read_text().strip());regular(converged);common=work/'toolchain/opt2';shutil.copyfile(converged,common);common.chmod(0o700);commonsha=sha(common)
  dump(e/'compiler.json',{'source_commit':A,'sha256':commonsha,'identity':command([common,'--producer-identity']),'path':str(common),'seed_sha256':SEED_SHA});need(command([common,'--producer-identity'])==A,'common compiler stamp')
  # Generate the ignored input before establishing the common input fingerprint.
  with(source/'tests/integration/wide_struct_literal_decls.tl').open('w')as f:subprocess.run(['awk','-f','tests/integration/wide_struct_literal_decls.awk'],cwd=source,stdout=f,check=True)
  auxiliary=capture_auxiliary(work);initial=fingerprint(source);dump(e/'inputs.json',{'common_digest':initial,'manifest_sha256':sha(source/'tests/integration/native.manifest'),'generated_and_bootstrap_inputs':auxiliary})
  perf=False;counter=e/'counter-check';counter.mkdir()
  if shutil.which('perf'):
   runner.bounded(counter,source,['bash',str(SCRIPT),'--counter-check',str(counter)],limit=256,ceiling=15)
   events=list(csv.reader((counter/'events.tsv').open(),delimiter='\t'));valid=[x for x in events if len(x)>=5 and x[2]in('cycles:u','instructions:u')and re.fullmatch(r'[0-9]+(?:\.[0-9]+)?',x[0]or'')and float(x[0])>0 and float(x[4]or 0)>=90];perf=len(valid)==2 and (counter/'counter-exit.txt').read_text().strip()=='0'
  else:(counter/'unavailable.txt').write_text('perf executable unavailable\n')
  dump(e/'counters.json',{'available':perf,'scope':'user-only native gate payload and descendants,including nested wrappers/samplers;excludes outer aggregate sampler/coordinator;unavailable is missing not zero'})
  for name,ref in ORDER:
   current=e/'trials'/name;current.mkdir();state['status']='running';state['trials'][name]='running';dump(e/'status.json',state)
   git(source,'switch','--detach',ref);need(git(source,'rev-parse','HEAD')==ref and git(source,'rev-parse','HEAD^{tree}')==TREES[ref],'phase checkout mismatch');need(not git(source,'status','--porcelain','--untracked-files=no'),'dirty tracked inputs')
   need(fingerprint(source)==initial and sha(common)==commonsha,'input changed before trial');need(not(source/'target/build-invariance').exists()and not(source/'target/opt1-reference.path').exists(),'stale trial output')
   dump(current/'identity.json',{'ref':ref,'tree':TREES[ref],'compiler_sha256':commonsha,'input_digest':initial,'control_head':os.environ['PROBE_EXPECTED_HEAD'],'runner':identity()})
   timing=current/'timing.tsv';timing.write_text('gate\tcase_or_chunk\tphase\telapsed_ms\texit\thost\n')
   runner.bounded(current,source,['bash','scripts/check-build-invariance.sh'],perf=perf,env_extra={'TYPELISP_BIN':str(common),'TYPELISP_INLINE_TEST_WORKERS':'1','TYPELISP_BUILD_INVARIANCE_WORKERS':'2','TYPELISP_BUILD_INVARIANCE_BATCH_SIZE':'64','TYPELISP_CI_TIMING':'1','TYPELISP_CI_TIMING_FILE':str(timing),'TYPELISP_CI_TIMING_HOST':'linux','TYPELISP_CI_TIMING_GATE':'stage2 opt1/opt2 build-invariance','TYPELISP_BUILD_INVARIANCE_OPT1_REFERENCE_PATH_FILE':str(source/'target/opt1-reference.path')})
   need(fingerprint(source)==initial and sha(common)==commonsha,'input changed during trial');(source/'target/build-invariance').rename(owned(current/'raw',work));(source/'target/opt1-reference.path').rename(owned(current/'handoff.path',work))
   # Audit and cross-trial comparisons are outside gate wall, inside total budget.
   runner.bounded(current/'audit-phase',source,['bash',str(SCRIPT),'--audit',str(current),str(source),'A'if ref==A else'B','-'if name=='A1'else str(e/'trials/A1')],ceiling=300,final=name=='A2')
   result=json.loads((current/'audit.json').read_text());state['trials'][name]='passed';dump(e/'status.json',state)
   print('[D-C21]',name,'wall',json.loads((current/'phase.json').read_text())['wall_s'],'all',result['comparisons'],'comparisons verified',flush=True)
  summarize(e);state['status']='all_four_passed';dump(e/'status.json',state)
 except BaseException as ex:
  state['status']='failed_or_incomplete';state['error']=repr(ex)
  if current is not None:state['trials'][current.name]='failed_or_incomplete'
  dump(e/'status.json',state);print('[D-C21] FAILED/INCOMPLETE',repr(ex),flush=True)
  runner.stop()
 finally:
  need(runner.active is None and runner.proc is None and runner.service is None,'ownership unresolved;do not rename or archive a live payload')
  # Preserve even incomplete outputs before packaging; no cleanup/deletion.
  if current is not None:
   for src,dst in[(source/'target/build-invariance',current/'raw'),(source/'target/opt1-reference.path',current/'handoff.path')]:
    if src.exists()and not dst.exists():owned(src,work);src.rename(owned(dst,work))
  try:runner.bounded(e/'pack',root,['bash',str(SCRIPT),'--pack',str(work)],ceiling=480,final=True);packed=True
  except BaseException as ex:dump(e/'pack-failure.json',{'error':repr(ex)})
 need(state['status']=='all_four_passed'and packed,'four-trial protocol or evidence archive incomplete')

def counter_check(out):
 with(out/'perf.stderr').open('w')as err:
  status=subprocess.run(['perf','stat','-x','\t','--no-big-num','-e','cycles:u,instructions:u','-o',str(out/'events.tsv'),'--','sh','-c','i=0;while [ "$i" -lt 10000 ];do i=$((i+1));done'],stdout=subprocess.DEVNULL,stderr=err).returncode
 (out/'counter-exit.txt').write_text(str(status)+'\n')
 if not(out/'events.tsv').exists():(out/'events.tsv').write_text('')

def summarize(e):
 trials={n:json.loads((e/'trials'/n/'phase.json').read_text())for n,_ in ORDER};walls={n:v['wall_s']for n,v in trials.items()};audits={n:json.loads((e/'trials'/n/'audit.json').read_text())for n,_ in ORDER}
 result={'raw_trials':trials,'wall_s':walls,'paired_ratios':{'B1_over_A1':walls['B1']/walls['A1'],'B2_over_A2':walls['B2']/walls['A2']},'sum_ratio':(walls['B1']+walls['B2'])/(walls['A1']+walls['A2']),'drift':{'A2_over_A1':walls['A2']/walls['A1'],'B2_over_B1':walls['B2']/walls['B1']},'dispersion_range_s':{'A':abs(walls['A2']-walls['A1']),'B':abs(walls['B2']-walls['B1'])},'native_cpu':{n:kv(e/'trials'/n/'cpu.tsv')for n,_ in ORDER},'gate_over_construction':{n:walls[n]/(v['compiler_construction_ms']/1000)for n,v in audits.items()},'ordinary_chunks':{}}
 def chunks(a):
  return {json.dumps([job.split('.')[0],c['records']],separators=(',',':')):c['wall_ms']for job,c in a['chunks'].items()if not c['selfhost']}
 maps={n:chunks(a)for n,a in audits.items()};common=set.intersection(*(set(v)for v in maps.values()));result['common_ordinary_chunks']=len(common)
 result['ordinary_chunks']={hashlib.sha256(k.encode()).hexdigest():{n:maps[n][k]for n,_ in ORDER}for k in sorted(common)}
 ratios=result['paired_ratios'];result['direction']='faster_in_both_pairs'if all(v<1 for v in ratios.values())else('slower_in_both_pairs'if all(v>1 for v in ratios.values())else'mixed_or_equal_inconclusive')
 result['direction_is_descriptive_only']=True;result['scope']='raw paired signs;no magnitude threshold or automatic acceptance,inspect dispersion/resources and full evidence'
 dump(e/'summary.json',result)

# Local protocol fixtures exercise both planners, result enforcement, exact bytes,
# symlink rejection and complete deduplicated archive reconstruction. No compiler.
def mock_trial(trial,source,variant):
 raw=trial/'raw';raw.mkdir(parents=True);original=source/'target/build-invariance';corpus=expected_corpus(source);(raw/'corpus.txt').write_text('\n'.join(corpus)+'\n');queue=['backend-tests|8192'];metrics=[];timing=[]
 for prod in('opt1-built','opt2-built'):
  base=raw/'batches'/prod;prepared=[]
  for line in corpus:
   name,src,opt=line.split('|');actual=str(original/'inputs/integration_sym_i64_env/sym_i64_env/sym_i64_env.tl')if name=='integration_sym_i64_env'else src;out=original/'compare'/prod/(name+'.s');prepared.append('|'.join([name,src,actual,str(out),opt]));p=raw/'compare'/prod/(name+'.s');p.parent.mkdir(parents=True,exist_ok=True);p.write_text('assembly '+src+' opt'+opt+'\n')
  base.mkdir(parents=True,exist_ok=True);(base/'cases.txt').write_text('\n'.join(prepared)+'\n')
  for opt in('1','2'):
   op=base/('opt'+opt);cp=op/'chunks';cp.mkdir(parents=True);rs=[l for l in prepared if l.split('|')[4]==opt];(op/'cases.txt').write_text('\n'.join(rs)+'\n');groups=[[rs[0]]]if opt=='1'else[[rs[0]],rs[1:]]
   for n,group in enumerate(groups):
    suffix=f'{n:04d}';(cp/('cases.'+suffix+'.txt')).write_text('\n'.join(group)+'\n');canon={};en=[];al=[]
    for l in group:
     f=l.split('|')
     if f[2]in canon:al.append(canon[f[2]]+'|'+f[3])
     else:canon[f[2]]=f[3];en.append(f[2]+'|'+f[3])
    (cp/('entries.'+suffix+'.txt')).write_text('\n'.join(en)+'\n');(cp/('aliases.'+suffix+'.txt')).write_text(('\n'.join(al)+'\n')if al else'');selfhost=n==0;job=prod+'.opt'+opt+'.'+suffix;cap=8192 if selfhost else 4096
    if not selfhost or variant=='B':
     queue.append(job+'|'+str(cap));p=raw/'backend-memory'/(prod+'.opt'+opt+'.chunk'+suffix+'.memory');p.parent.mkdir(exist_ok=True);p.write_text(f'schema_version=1\nhost=linux\nbackend=systemd-user-cgroup\nreason=success\nexit_code=0\npeak_memory_bytes=1048576\nlimit_bytes={cap*1048576}\nwall_ms=10\n')
    metrics.append('10\t'+prod+'\t'+opt+'\t'+suffix+'\t1\t1048576')
    if selfhost:timing.append(['gate',prod+':selfhost_main_opt'+opt,'compile','10','0','linux'])
  for name in('integration_aggregate_globals','integration_sym_i64_env'):
   p=raw/'sentinels'/prod/(name+'.standalone.s');p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((raw/'compare'/prod/(name+'.s')).read_bytes())
 for name in('opt1/opt1','opt1/opt1.o','backend-memory/backend-tests'):
  p=raw/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b'fixed binary or object')
 (raw/'backend-memory/backend-tests.memory').write_text(f'schema_version=1\nhost=linux\nbackend=systemd-user-cgroup\nreason=success\nexit_code=0\npeak_memory_bytes=1048576\nlimit_bytes={8192*1048576}\nwall_ms=10\n');(raw/'pool-queue.txt').write_text('\n'.join(queue)+'\n');results=raw/'pool/results';results.mkdir(parents=True)
 for q in queue:(results/q.split('|')[0]).write_text('0\n')
 (raw/'chunk-metrics.tsv').write_text('\n'.join(metrics)+'\n');timing.extend(['gate',x.split('|')[0],'compare','0','0','linux']for x in corpus)
 with(trial/'timing.tsv').open('w')as f:w=csv.writer(f,delimiter='\t',lineterminator='\n');w.writerow(['gate','case_or_chunk','phase','elapsed_ms','exit','host']);w.writerows(timing)
 (trial/'gate.log').write_text('\n'.join('[build-invariance] '+p+' standalone sentinel integration_'+n+' opt2'for p in('opt1-built','opt2-built')for n in('aggregate_globals','sym_i64_env'))+'\n');(trial/'handoff.path').write_text(str(original/'compare/opt2-built/selfhost_main_opt1.s')+'\n')
 if variant=='B':(raw/'provenance.txt').write_text('logical_cases=5\npool_workers=2\n')
def test_monitor_ownership(work,source):
 import unittest.mock as mock
 out=work/'monitor-receipt-failure';stops=[];instances=[]
 class MockProcess:
  def __init__(self,*args,**kwargs):
   self.alive=True;self.returncode=None;self.waited=False;instances.append(self)
   atomic_text(out/'service.unit','run-fixture.service\n')
   (out/'payload.json').write_text('{partial publication')
  def poll(self):return None if self.alive else self.returncode
  def wait(self,timeout=None):
   need(not self.alive,'wrapper reaped before exact service stop');self.waited=True;return self.returncode
 def stop_command(argv,**kwargs):
  if argv==['systemctl','--user','stop','run-fixture.service']:
   stops.append(argv);instances[0].alive=False;instances[0].returncode=-15
   return subprocess.CompletedProcess(argv,0)
  need(argv==['systemctl','--user','show','--property=LoadState','--property=ActiveState','--property=ControlGroup','run-fixture.service'],'wrong service query')
  return subprocess.CompletedProcess(argv,0,stdout='LoadState=not-found\nActiveState=inactive\nControlGroup=\n',stderr='')
 runner=Runner(SCRIPT.parent.parent,work,{'started_at':datetime.datetime.now(datetime.timezone.utc).isoformat()})
 with mock.patch.object(subprocess,'Popen',MockProcess),mock.patch.object(subprocess,'run',stop_command):
  try:runner.bounded(out,source,['unused-fixture-command'],limit=32,ceiling=10)
  except json.JSONDecodeError:pass
  else:raise Failure('partial receipt did not exercise monitor exception')
 need(len(stops)==1 and instances[0].waited and not instances[0].alive and runner.active is None and runner.proc is None,'monitor lost service ownership')
 original=Path.read_text
 dump(out/'payload.json',{'node':'/sys/fs/cgroup/fixture-teardown'})
 def cgroup_teardown(path,*args,**kwargs):
  if str(path).startswith('/sys/fs/cgroup/fixture-teardown'):raise OSError(19,'No such device')
  return original(path,*args,**kwargs)
 with mock.patch.object(Path,'read_text',cgroup_teardown):
  observed=sample_telemetry(out);need(len(observed['errors'])==6 and all(v is None for v in observed['cgroup'].values()),'ENODEV telemetry not retained as missing')


def test_exited_wrapper_live_service(work,source):
 import unittest.mock as mock
 for mode in('direct-stop','bounded-exit'):
  out=work/('exited-wrapper-'+mode);out.mkdir();state={'service_live':True,'stop_calls':0,'waited':False}
  atomic_text(out/'service.unit','run-exited-fixture.service\n')
  class ExitedWrapper:
   returncode=-9
   def __init__(self,*args,**kwargs):pass
   def poll(self):return -9
   def wait(self,timeout=None):
    need(not state['service_live'],'reaped/cleared before live service stopped');state['waited']=True;return -9
  def systemctl(argv,**kwargs):
   if argv==['systemctl','--user','stop','run-exited-fixture.service']:
    state['service_live']=False;state['stop_calls']+=1;return subprocess.CompletedProcess(argv,0)
   need(argv[-1]=='run-exited-fixture.service'and 'show'in argv,'wrong service queried')
   return subprocess.CompletedProcess(argv,0,stdout='LoadState=loaded\nActiveState=inactive\nControlGroup=\n',stderr='')
  runner=Runner(SCRIPT.parent.parent,work,{'started_at':datetime.datetime.now(datetime.timezone.utc).isoformat()})
  with mock.patch.object(subprocess,'Popen',ExitedWrapper),mock.patch.object(subprocess,'run',systemctl):
   if mode=='direct-stop':runner.active=out;runner.proc=ExitedWrapper();runner.stop()
   else:
    try:runner.bounded(out,source,['unused-command'],limit=32,ceiling=10)
    except Failure as ex:need('bounded phase failed'in str(ex),'wrong exited-wrapper failure')
    else:raise Failure('killed wrapper accepted')
  need(state['stop_calls']==1 and state['waited']and not state['service_live']and runner.active is None and runner.proc is None and runner.service is None,'exited wrapper lost service ownership')

def test_input_and_fallback(work,source,parent):
 import unittest.mock as mock
 (source/'src').mkdir(exist_ok=True);(source/'stdlib').mkdir(exist_ok=True);(source/'src/main.tl').write_text('source fixture')
 image=source/'target/embedded-stdlib-tlci/stdlib.tlci';image.parent.mkdir(parents=True);image.write_bytes(b'image-original')
 (image.parent/'stdlib.tlci.tlch').write_bytes(b'envelope');stamp=source/'target/build-stage0/git-hash.txt';stamp.parent.mkdir();stamp.write_text(A)
 asm=source/'target/bootstrap-fixpoint/stage2.s';asm.parent.mkdir();asm.write_bytes(b'bootstrap-assembly')
 (work/'toolchain/typelisp-stage0-linux').write_bytes(b'seed-fixture');(work/'toolchain/SHA256SUMS').write_text('fixture-manifest')
 frozen=capture_auxiliary(work)
 with mock.patch.dict(globals(),{'git':lambda *args:'src/main.tl\0tests/integration/native.manifest'}):
  before=fingerprint(source);image.write_bytes(b'image-mutated');need(fingerprint(source)!=before,'generated image mutation not fingerprinted')
 old=frozen['source/target/embedded-stdlib-tlci/stdlib.tlci'];need((work/'evidence/cas'/old['sha256']).read_bytes()==b'image-original','frozen image bytes changed through source mutation')
 for failure in('before-index','during-archive'):
  fresh=Path(tempfile.mkdtemp(prefix='archive-failure.',dir=parent)).resolve();shutil.copytree(work/'evidence/trials',fresh/'evidence/trials');shutil.copytree(work/'source',fresh/'source');shutil.copytree(work/'toolchain',fresh/'toolchain')
  try:pack(fresh,inject_failure=failure)
  except Failure:pass
  else:raise Failure('archive fault injection failed')
  need(not(fresh/'evidence.complete.tar.gz').exists(),'partial archive labelled complete')
  paths=upload_paths(fresh);need(paths==[str(fresh/'evidence/**'),str(fresh/'toolchain/**'),str(fresh/'source/target/**')],'incomplete fallback selection')
  for trial in(fresh/'evidence/trials').iterdir():
   inv=json.loads((trial/'audit.json').read_text())['output_inventory']
   for rel,v in inv.items():need(sha(trial/'raw'/rel)==v['sha256'],'raw fallback failed reconstruction')
  need((fresh/'toolchain/SHA256SUMS').is_file()and(fresh/'source/target/embedded-stdlib-tlci/stdlib.tlci').is_file()and(fresh/'source/target/bootstrap-fixpoint/stage2.s').is_file(),'auxiliary fallback incomplete')
 return frozen

def selftest(parent):
 parent.mkdir(parents=True,exist_ok=True);w=Path(tempfile.mkdtemp(prefix='mock-final-abba.',dir=parent)).resolve();source=w/'source';(source/'tests/integration').mkdir(parents=True);(source/'tests/integration/native.manifest').write_text('aggregate_globals|all|-|tests/integration/agg.tl|0|-|-|-|-\nsym_i64_env|all|-|tests/integration/sym_i64_env.tl|0|-|-|-|-\naggregate_alias|all|-|tests/integration/agg.tl|0|-|-|-|-\n');(w/'evidence/trials').mkdir(parents=True);(w/'toolchain').mkdir()
 for name,ref in ORDER:
  t=w/'evidence/trials'/name;t.mkdir();mock_trial(t,source,'A'if ref==A else'B');audit(t,source,'A'if ref==A else'B',None if name=='A1'else w/'evidence/trials/A1',True)
 # Separate fresh fixtures preserve every failed probe's evidence.
 for defect in('missing','symlink','alias','result','different_bytes'):
  t=w/'evidence'/('negative-'+defect);t.mkdir();mock_trial(t,source,'B');p=t/'raw/compare/opt2-built/integration_aggregate_globals.s'
  if defect=='missing':p.rename(t/'preserved-missing.s')
  if defect=='symlink':p.rename(t/'preserved-symlink.s');p.symlink_to(t/'preserved-symlink.s')
  if defect=='alias':(t/'raw/batches/opt1-built/opt2/chunks/aliases.0001.txt').write_text('wrong|wrong\n')
  if defect=='result':next((t/'raw/pool/results').iterdir()).write_text('9\n')
  if defect=='different_bytes':p.write_bytes(b'wrong')
  try:audit(t,source,'B',w/'evidence/trials/A1',True)
  except Failure:pass
  else:raise Failure('negative fixture accepted '+defect)
 test_monitor_ownership(w,source)
 test_exited_wrapper_live_service(w,source)
 test_input_and_fallback(w,source,parent)
 archive_input={str(p.relative_to(w/'evidence')):sha(p)for p in(w/'evidence').rglob('*')if p.is_file()and not p.is_symlink()}
 pack(w)
 need(upload_paths(w)[0]==str(w/'evidence.complete.tar.gz'),'completed archive selection')
 with tarfile.open(w/'evidence.complete.tar.gz','r:gz')as tar:
  idx=json.load(tar.extractfile('content-index.json'))
  need({'toolchain/typelisp-stage0-linux','toolchain/SHA256SUMS','source/target/bootstrap-fixpoint/stage2.s','source/target/embedded-stdlib-tlci/stdlib.tlci','source/target/build-stage0/git-hash.txt'}<=set(idx),'archive auxiliary identities missing')
  for v in idx.values():need(hashlib.sha256(tar.extractfile('cas/'+v['sha256']).read()).hexdigest()==v['sha256'],'CAS reconstruction')
  archived={m.name for m in tar.getmembers()if m.isfile()}
  for relative,digest in archive_input.items():
   if relative in archived:restored=hashlib.sha256(tar.extractfile(relative).read()).hexdigest()
   else:
    need(relative in idx,'regular evidence omitted from tar and CAS: '+relative);restored=hashlib.sha256(tar.extractfile('cas/'+idx[relative]['sha256']).read()).hexdigest()
   need(restored==digest,'regular evidence byte reconstruction failed')
  for name,_ in ORDER:
   need('trials/'+name+'/raw/pool/results/backend-tests'in archived,'backend result receipt omitted')
   need('trials/'+name+'/raw/opt1/opt1.o'in idx,'opt1 object omitted')

 expired=Runner(SCRIPT.parent.parent,w,{'started_at':'2000-01-01T00:00:00Z'})
 try:expired.bounded(w/'expired-budget',source,['false'])
 except Failure as ex:need('budget exhausted' in str(ex),'wrong budget failure')
 else:raise Failure('expired budget launched a command')
 need(not(w/'expired-budget/phase.memory').exists(),'expired budget entered wrapper')
 print('SELFTEST PASS all4 mock trials,5 negative fixtures,complete CAS,ownership/error-stop,exited-wrapper/live-service stop+proof,generated-input mutation,archive-failure fallback,all-regular-file reconstruction,ENODEV telemetry,expired-budget rejection;no timing evidence',w)

try:
 mode=ARGS[0]if ARGS else''
 if mode=='--payload':payload(ARGS[1:])
 elif mode=='--pack':pack(Path(ARGS[1]))
 elif mode=='--counter-check':counter_check(Path(ARGS[1]))
 elif mode=='--upload-paths':print('\n'.join(upload_paths(Path(ARGS[1]))))
 elif mode=='--audit':audit(Path(ARGS[1]),Path(ARGS[2]),ARGS[3],None if ARGS[4]=='-'else Path(ARGS[4]))
 elif mode=='--self-test':selftest(Path(ARGS[1]).resolve())
 elif mode=='--run':run_job(Path(ARGS[1]).resolve(strict=True),Path(ARGS[2]).absolute())
 else:raise Failure('expected --run ROOT FRESH_WORK or --self-test FRESH_PARENT')
except BaseException as ex:
 import traceback
 traceback.print_exc()
 if ARGS and ARGS[0]=='--run'and len(ARGS)>2:
  e=Path(ARGS[2])/'evidence'
  if e.is_dir()and not e.is_symlink():dump(e/'fatal.json',{'error':repr(ex),'phase':'see retained status/trials;no retry'})
 print('[D-C21] ERROR',repr(ex),file=sys.stderr,flush=True);sys.exit(1)
PY
