#!/usr/bin/env sh
# #6883's canonical provenance fields/key, extended with a versioned transport
# envelope. Historical implementation: #6909, removed by #8118. Commit stamps
# and tree producer identities retain lib-build-provenance.sh semantics.
# Source this library; no compiler consumes an envelope in D-C27 slice 1.
ci_compiler_artifact_key() { ci_compiler_artifact key "$@"; }
ci_compiler_artifact() {
    node - "$@" <<'JS'
'use strict';
const fs = require('fs'), path = require('path'), cp = require('child_process');
const crypto = require('crypto');
const args = process.argv.slice(2), op = args.shift();
const VERSION = 3, CONTRACT = 'ci-compiler-artifact';
needNodeVersion();
function needNodeVersion() { if(Number(process.versions.node.split('.')[0])<20) throw Error('Node 20 or newer required'); }
const FIELDS = ['producer_sha256','producer_identity','host','target','cwd',
  'source_roots','stdlib_roots','cfg','opt_level','profile','environment','argv',
  'source_set_sha256','output_kind'];
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
const need = (ok, why) => { if (!ok) throw Error(why); };
const hex = (s,n) => typeof s === 'string' && new RegExp('^[0-9a-f]{'+n+'}$').test(s);
const json = value => JSON.stringify(value, null, 2)+'\n';
const order = (a,b) => Buffer.compare(Buffer.from(a),Buffer.from(b));
function key(fields) {
  // Byte-compatible with #6883 ci_compiler_artifact_key (schema=1), including
  // field order, LF framing and the conservative normalized source manifest.
  for (const k of FIELDS) need(typeof fields[k]==='string' && fields[k].length &&
    !/[\x00-\x1f\x7f]/.test(fields[k]), 'unsafe provenance field '+k);
  return sha('schema=1\n'+FIELDS.map(k=>k+'='+fields[k]+'\n').join(''));
}
function hash(file) {
  const h=crypto.createHash('sha256'), b=Buffer.alloc(1024*1024), fd=fs.openSync(file,'r');
  try { for (;;) { const n=fs.readSync(fd,b,0,b.length,null); if (!n) break; h.update(b.subarray(0,n)); } }
  finally { fs.closeSync(fd); }
  return h.digest('hex');
}
function safeRel(s) {
  need(typeof s==='string' && s.length && !/[\\:\x00-\x1f\x7f]/.test(s) &&
    !s.startsWith('/') && s.split('/').every(x=>x && x!=='.' && x!=='..'), 'unsafe relative path '+s);
  return s;
}
function below(base, relative, regular=false) {
  safeRel(relative); let p=base;
  for (const part of relative.split('/')) {
    p=path.join(p,part);
    if (fs.existsSync(p) || (()=>{try{return fs.lstatSync(p).isSymbolicLink();}catch{return false;}})())
      need(!fs.lstatSync(p).isSymbolicLink(),'symlink path '+p);
  }
  if (regular) need(fs.lstatSync(p).isFile(),'not a regular file '+p);
  return p;
}
function owned(root, p) {
  p=path.resolve(p); const rel=path.relative(root,p).split(path.sep).join('/');
  need(rel.startsWith('target/'),'envelope must be inside owned target/'); below(root,rel);
  return p;
}
function write(p,value) { fs.mkdirSync(path.dirname(p),{recursive:true}); fs.writeFileSync(p,value,{flag:'wx'}); }
function load(p) { need(fs.statSync(p).size<=4*1024*1024,'oversized metadata '+p); const text=fs.readFileSync(p,'utf8'), value=JSON.parse(text); need(text===json(value),'noncanonical/duplicate JSON fields '+p); return value; }
function git(root,...a) { return cp.execFileSync('git',['-C',root,...a],{encoding:'utf8'}).trim(); }
function normal(root,value) {
  const r=root.replace(/\\/g,'/'), s=value.replace(/\\/g,'/');
  return s===r ? '{root}' : s.startsWith(r+'/') ? '{root}/'+s.slice(r.length+1) : s;
}
function native(root,value) { return path.resolve(root,value); }
function regularInput(root,p) {
  const rel=path.relative(root,p).split(path.sep).join('/');
  if(rel && !rel.startsWith('../') && !path.isAbsolute(rel)) below(root,rel,true);
  else need(fs.lstatSync(p).isFile()&&!fs.lstatSync(p).isSymbolicLink(),'invalid external input');
  return p;
}
function identity(file) {
  const x=cp.execFileSync(file,['--producer-identity'],{encoding:'utf8'}).trim();
  need(hex(x,40),'malformed producer identity'); return x;
}
function context(root,host,local=false,e=process.env) {
  need(['linux','windows'].includes(host),'unsupported envelope host');
  const commit=git(root,'rev-parse','HEAD'), tree=git(root,'rev-parse','HEAD^{tree}');
  if (local) { need(e.GITHUB_ACTIONS!=='true','local envelope mode forbidden in CI');
    return {scope:'local',repository:'local',run_id:'local',attempt:0,commit,tree,head:commit,workflow_ref:'local',workflow_sha:commit,host}; }
  need(e.GITHUB_ACTIONS==='true','hosted context required');
  need(e.GITHUB_SHA===commit && hex(e.GITHUB_WORKFLOW_SHA,40),'checkout/workflow differs from trusted event');
  need(/^\d+$/.test(e.GITHUB_RUN_ID||'') && /^[1-9]\d*$/.test(e.GITHUB_RUN_ATTEMPT||''),'missing run/attempt');
  need(cp.spawnSync('git',['-C',root,'diff','--quiet','HEAD'],{stdio:'ignore'}).status===0,'dirty tracked checkout');
  need(e.GITHUB_EVENT_NAME==='pull_request','required PR workflow context expected');
  const event=JSON.parse(fs.readFileSync(e.GITHUB_EVENT_PATH,'utf8'));
  need(event.repository.full_name===e.GITHUB_REPOSITORY && hex(event.pull_request.head.sha,40),'event repository/head mismatch');
  need(e.GITHUB_WORKFLOW_REF.startsWith(e.GITHUB_REPOSITORY+'/.github/workflows/ci.yml@'),'wrong workflow');
  return {scope:'github',repository:e.GITHUB_REPOSITORY,run_id:e.GITHUB_RUN_ID,attempt:Number(e.GITHUB_RUN_ATTEMPT),
    commit,tree,head:event.pull_request.head.sha,workflow_ref:e.GITHUB_WORKFLOW_REF,workflow_sha:e.GITHUB_WORKFLOW_SHA,host};
}
function walk(base) {
  const out=[]; let count=0;
  function scan(rel) {
    for (const n of fs.readdirSync(path.join(base,rel)).sort(order)) {
      need(++count<=10000,'too many envelope entries');
      const r=rel ? rel+'/'+n : n, p=below(base,r), s=fs.lstatSync(p);
      if (s.isDirectory()) scan(r); else { need(s.isFile(),'special file '+p); out.push(r); }
    }
  }
  scan(''); return out.sort(order);
}
function sources(root) {
  // Canonical #6883 manifest framing; tracked src/stdlib/tests form a
  // conservative closure. Explicit generated inputs are bound separately.
  // Ignored fixtures created later by other gates cannot change this closure.
  const files=cp.execFileSync('git',['-C',root,'ls-files','-z','--','src','stdlib','tests'],{encoding:'utf8',maxBuffer:8*1024*1024}).split('\0').filter(Boolean).sort(order);
  need(files.length>0,'source closure empty');
  const manifest=files.map(p=>hash(below(root,p,true))+'  {root}/'+p+'\n').join('');
  return {manifest,sha256:sha(manifest)};
}

function inventory(root) {
  return Object.fromEntries(['scripts/ci-gates.tsv','scripts/ci-compiler-artifacts.tsv','scripts/expand-integration-manifest.awk','tests/integration/native.manifest']
    .map(p=>[p,hash(below(root,p,true))]));
}
function recipeHashes(root) { return Object.fromEntries(['scripts/check-bootstrap-fixpoint.sh','scripts/lib-native-link.sh','scripts/lib-build-provenance.sh','scripts/check-build-invariance.sh','scripts/lib-build-invariance-batch.sh','scripts/ci-compiler-artifact.sh','scripts/lib-ci-compiler-artifact.sh'].map(p=>[p,hash(below(root,p,true))])); }
function generatedPaths(host) { return ['target/build-stage0/git-hash.txt','target/build-stage0/tree-hash.txt','target/embedded-stdlib-tlci/stdlib.tlci','target/embedded-stdlib-tlci/stdlib.tlci.tlch','target/embedded-stdlib-tlci/source-hash.txt','target/embedded-stdlib-tlci/modules.txt','target/embedded-stdlib-tlci/prelude-surface-'+host+'.rodata']; }
function expectedCorpus(root) {
  const rows=cp.execFileSync('awk',['-v','host=linux','-f',path.join(root,'scripts/expand-integration-manifest.awk'),path.join(root,'tests/integration/native.manifest')],{cwd:root,encoding:'utf8'}).trim().split('\n').filter(Boolean);
  return 'selfhost_main_opt1|src/main.tl|1\nselfhost_main_opt2|src/main.tl|2\n'+rows.map(x=>{const f=x.split('|');need(f[0]&&f[1],'invalid authoritative inventory');return 'integration_'+f[0]+'|'+f[1]+'|2\n';}).join('');
}
function artifactName(c) { return 'ci-stage-envelope-'+(c.host==='linux'?'Linux':'Windows')+'-r'+c.run_id+'-a'+c.attempt; }
function expectedRoles(host) { return host==='linux' ? ['bootstrap-converged','build-invariance-opt1-reference'] : ['bootstrap-converged']; }
function state(root,work,host) {
  const d=owned(root,path.join(work,'draft')); const c=load(below(d,'context.json',true));
  need(json(c)===json(context(root,host,c.scope==='local')),'producer workflow context changed');
  return {d,c};
}
function copy(root,dir,source,dest,files) {
  const p=path.resolve(source); need(fs.lstatSync(p).isFile() && !fs.lstatSync(p).isSymbolicLink(),'invalid snapshot input '+p);
  regularInput(root,p); const before=hash(p), size=fs.statSync(p).size; need(size>0,'empty snapshot input '+p);
  const q=below(dir,dest); fs.mkdirSync(path.dirname(q),{recursive:true}); fs.copyFileSync(p,q,fs.constants.COPYFILE_EXCL);
  need(before===hash(q) && before===hash(p),'input changed while publishing '+p);
  files[dest]={sha256:before,bytes:size,source:normal(root,p)}; return files[dest];
}
function binaryShape(file,host) {
  const b=Buffer.alloc(64),fd=fs.openSync(file,'r'); try { need(fs.readSync(fd,b,0,64,0)===64,'short compiler'); } finally {fs.closeSync(fd);}
  if(host==='linux') need(b.subarray(0,4).equals(Buffer.from([127,69,76,70])) && b[4]===2 && b.readUInt16LE(18)===62,'wrong ELF target');
  else {
    need(b[0]===77 && b[1]===90,'wrong PE target'); const offset=b.readUInt32LE(60), pe=Buffer.alloc(6), fd2=fs.openSync(file,'r');
    try{need(offset>=64&&offset+6<=fs.statSync(file).size&&fs.readSync(fd2,pe,0,6,offset)===6,'truncated PE');}finally{fs.closeSync(fd2);}
    need(pe.subarray(0,4).equals(Buffer.from([80,69,0,0]))&&pe.readUInt16LE(4)===0x8664,'wrong PE architecture');
  }
}
function record(root,work,host,label,argv) {
  const {d}=state(root,work,host); let wrapper=[];
  if (argv[0].endsWith('run-memory-bounded.sh')) {const i=argv.indexOf('--');need(i>0,'bad wrapper argv');wrapper=argv.slice(0,i);argv=argv.slice(i+1);}
  need(argv[1]==='compile' && argv.includes('--target'),'compiler invocation missing');
  const producer=regularInput(root,native(root,argv[0])); const rec={producer_version:cp.execFileSync(producer,['--version'],{encoding:'utf8'}).split(/\r?\n/)[0],argv:argv.map(x=>normal(root,x)),producer_path:normal(root,producer),producer_sha256:hash(producer),producer_identity:identity(producer),wrapper:wrapper.map(x=>normal(root,x))};
  if (label!=='reference') {
    const out=argv[argv.indexOf('-o')+1]; need(argv.includes('-o') && path.basename(out)===label+'.s','wrong recorded output');
    rec.compiled_output={path:normal(root,out),sha256:hash(out),bytes:fs.statSync(out).size};
  }
  if (label==='reference') {
    const batch=argv[argv.indexOf('--batch')+1]; need(argv.includes('--batch'),'reference was not a batch');
    const text=fs.readFileSync(batch,'utf8'); const rows=text.trim().split('\n'); need(rows.length===1,'reference must be a singleton batch');
    const [source,out]=rows[0].split('|'); need(source==='src/main.tl' && out.endsWith('/selfhost_main_opt1.s'),'wrong reference entry');
    const normalized=text.split(root).join('{root}'); rec.batch_manifest={text:normalized,sha256:sha(normalized),raw_sha256:hash(batch)};
  } else need(['stage1','stage2','stage3','stage4'].includes(label),'unexpected bootstrap record');
  write(below(d,'records/'+label+'.json'),json(rec));
}
function flags(rec,host,role) {
  const a=rec.argv, values=k=>a.flatMap((x,i)=>x===k?[a[i+1]]:[]), target=host+'-x86_64';
  need(values('--target').length===1 && values('--target')[0]===target,'wrong target');
  const base=host==='linux'?['linux','unix','target-linux','os-linux']:['windows','target-windows','os-windows'];
  const cfg=base.concat(role==='bootstrap-converged'?['compiler-build-identity','embedded-stdlib-tlci']:[]);
  need(JSON.stringify(values('--cfg'))===JSON.stringify(cfg),'cfg substitution');
  need(JSON.stringify(values('--opt-level'))===JSON.stringify([role==='bootstrap-converged'?'2':'1']),'opt-level substitution');
  const roots=values('--stdlib-root');
  need(JSON.stringify(roots)===JSON.stringify(role==='bootstrap-converged'?['{root}/src']:['stdlib','src']),'stdlib roots changed');
  if(role!=='bootstrap-converged') need(JSON.stringify(values('--backend-mode'))==='["scalar"]','backend changed');
  const producerPath=a[0]; need(/^\{root\}\/target\/bootstrap-fixpoint\/stage[234](?:\.exe)?$/.test(producerPath),'producer outside bootstrap handoff');
  let expected;
  if(role==='bootstrap-converged') {
    const stage=Number(producerPath.match(/stage([234])/)[1])+1;
    need(stage===3||stage===4,'invalid producing generation');
    expected=[producerPath,'compile','src/main.tl','-o','{root}/target/bootstrap-fixpoint/stage'+stage+'.s','--target',target,...cfg.flatMap(x=>['--cfg',x]),'--stdlib-root','{root}/src','--opt-level','2'];
  } else {
    const batch=a[3];need(/^\{root\}\/target\/build-invariance\/batches\/opt2-built\/opt1\/chunks\/entries\.[0-9]+\.txt$/.test(batch),'wrong reference batch path');
    expected=[producerPath,'compile','--batch',batch,'--target',target,...cfg.flatMap(x=>['--cfg',x]),'--backend-mode','scalar','--opt-level','1','--stdlib-root','stdlib','--stdlib-root','src'];
  }
  need(JSON.stringify(a)===JSON.stringify(expected),'normalized invocation changed');
  return {target,cfg:cfg.join(','),opt:role==='bootstrap-converged'?'2':'1',roots:roots.join(',')};
}
function producer(root,p,tree) { regularInput(root,p); const r={sha256:hash(p),identity:identity(p),path:normal(root,p)};need(r.identity===tree,'producer tree identity mismatch');return r; }
function publish(root,work,host,role,argv) {
  const started=process.hrtime.bigint(), {d,c}=state(root,work,host); need(expectedRoles(host).includes(role),'wrong host role');
  const dir=below(d,'roles/'+role+'.publishing'); need(!fs.existsSync(dir),'stale partial role'); fs.mkdirSync(dir,{recursive:true}); const files={};
  const selected=path.resolve(argv[0]); let rec,proof={},generated={};
  if(role==='bootstrap-converged') {
    const stage=path.basename(selected).replace(/\.exe$/,''); need(['stage3','stage4'].includes(stage),'unconverged stage');
    need(selected===path.join(root,'target/bootstrap-fixpoint',stage+(host==='windows'?'.exe':'')),'unexpected converged path');
    rec=load(below(d,'records/'+stage+'.json',true)); const prev=path.join(path.dirname(selected),stage==='stage3'?'stage2':'stage3')+(host==='windows'?'.exe':'');
    const p=producer(root,prev,c.tree); need(p.sha256===rec.producer_sha256 && p.identity===rec.producer_identity && rec.producer_version==='typelisp '+c.commit,'bootstrap producer changed');
    const w=path.dirname(selected), pair=stage==='stage3'?['stage2.s','stage3.s']:['stage3.s','stage4.s'];
    for(const name of new Set([...pair,'stage3.s','stage3-embedded.s'])) proof[name]={sha256:hash(path.join(w,name)),bytes:fs.statSync(path.join(w,name)).size};
    need(proof[pair[0]].sha256===proof[pair[1]].sha256 && proof['stage3.s'].sha256===proof['stage3-embedded.s'].sha256,'fixpoint/parity failed');
    need(rec.compiled_output.sha256===proof[stage+'.s'].sha256 && rec.compiled_output.path==='{root}/target/bootstrap-fixpoint/'+stage+'.s','compiled output changed');
    proof.compile_receipt=rec.compiled_output; proof.fixpoint_pair=pair; proof.selected_stage=stage; proof.seed={sha256:hash(argv[1]),identity:identity(argv[1]),path:normal(root,path.resolve(argv[1]))};
    const output=producer(root,selected,c.tree); binaryShape(selected,host); copy(root,dir,selected,'payload/compiler',files);
    const previous=path.resolve(argv[2]); producer(root,previous,c.tree); binaryShape(previous,host); copy(root,dir,previous,'payload/previous-stage',files); proof.output_identity=output.identity;
    const gen=generatedPaths(host);
    for(const p of gen) generated[p]=copy(root,dir,below(root,p,true),'generated/'+p,files);
    need(fs.readFileSync(below(root,gen[0]),'utf8')===c.commit && fs.readFileSync(below(root,gen[1]),'utf8')===c.tree,'stamp changed before snapshot');
  } else {
    rec=load(below(d,'records/reference.json',true)); const p=producer(root,path.resolve(argv[1]),c.tree); need(p.sha256===rec.producer_sha256 && rec.producer_version==='typelisp '+c.commit,'reference producer changed');
    const boot=load(below(d,'roles/bootstrap-converged/manifest.json',true));need(p.sha256===boot.files['payload/compiler'].sha256,'reference did not use converged compiler');proof.seed=boot.proof.seed;proof.parent_provenance_key=boot.provenance_key;
    need(selected===path.join(root,'target/build-invariance/compare/opt2-built/selfhost_main_opt1.s'),'unexpected reference path');
    proof.batch_manifest=rec.batch_manifest;
    const other=selected.replace('/opt2-built/','/opt1-built/'); need(other!==selected && hash(other)===hash(selected),'reference comparison missing');
    copy(root,dir,selected,'payload/reference.s',files); proof.compared_output_sha256=hash(other);
    copy(root,dir,path.join(root,'target/build-invariance/corpus.txt'),'inventory/corpus.txt',files);
  }
  proof.input_producer_sha256=rec.producer_sha256;
  const f=flags(rec,host,role), src=sources(root); write(below(dir,'source-set.sha256'),src.manifest);
  const recipes=recipeHashes(root);
  const relevantEnv=Object.fromEntries(Object.entries(process.env).filter(([k])=>k.startsWith('TYPELISP_')||['CC','CFLAGS','LDFLAGS','LANG','LC_ALL'].includes(k)).sort(([a],[b])=>order(a,b)).map(([k,v])=>[k,sha(normal(root,v))]));
  const environment=JSON.stringify({producer_commit:c.commit,producer_version:rec.producer_version,toolchain:load(below(d,'toolchain.json',true)),generated_inputs:generated,seed:proof.seed||null,parent_provenance_key:proof.parent_provenance_key||null,recipes,variables_sha256:relevantEnv,resource_wrapper:rec.wrapper,batch_manifest:rec.batch_manifest?{text:rec.batch_manifest.text,sha256:rec.batch_manifest.sha256}:null});
  const fields={producer_sha256:rec.producer_sha256,producer_identity:rec.producer_identity,host,target:f.target,cwd:'{root}',source_roots:'src,stdlib,tests',stdlib_roots:f.roots,cfg:f.cfg,opt_level:f.opt,profile:'none',environment,argv:JSON.stringify(rec.argv),source_set_sha256:src.sha256,output_kind:role==='bootstrap-converged'?'compiler-binary':'compiler-assembly'};
  const meta={schema:VERSION,contract:CONTRACT,role,context:c,fields,provenance_key:key(fields),files,generated_inputs:generated,proof,inventory:inventory(root),packaging_ms:Number(process.hrtime.bigint()-started)/1e6};
  write(below(dir,'manifest.json'),json(meta)); const dest=below(d,'roles/'+role);need(!fs.existsSync(dest),'duplicate role publication');fs.renameSync(dir,dest);
  console.error('[ci-compiler-artifact] snapshot '+role+' '+meta.packaging_ms.toFixed(3)+'ms');
}
function init(root,work,host,local) {
  const c=context(root,host,local);need(!fs.existsSync(work),'envelope root is not fresh');owned(root,work);fs.mkdirSync(path.join(work,'draft'),{recursive:true});write(path.join(work,'draft/context.json'),json(c));
  const tools={node:process.version};
  for(const name of host==='linux'?['as','ld']:['clang','lld-link']) {
    const override=host==='windows'?process.env[name==='clang'?'TYPELISP_WINDOWS_CLANG':'TYPELISP_WINDOWS_LINK']:undefined;
    const exe=override||name;const located=override||cp.execFileSync(process.platform==='win32'?'where.exe':'which',[exe],{encoding:'utf8'}).trim().split(/\r?\n/)[0];
    tools[name]={path:normal(root,located),sha256:hash(fs.realpathSync(located)),version:cp.execFileSync(exe,['--version'],{encoding:'utf8'}).trim()};
  }
  write(path.join(work,'draft/toolchain.json'),json(tools));
}
function seal(root,work,host) {
  const {d,c}=state(root,work,host);return sealDirectory(work,host,d,c);
}
function sealDirectory(work,host,d,c,quiet=false) {
  const started=process.hrtime.bigint(),roles={};
  for(const role of expectedRoles(host)) {const rel='roles/'+role+'/manifest.json',m=load(below(d,rel,true));need(m.role===role,'wrong completed role');roles[role]=hash(below(d,rel,true));}
  need(fs.readdirSync(path.join(d,'roles')).sort().join(',')===expectedRoles(host).sort().join(','),'extra/partial roles');
  const files=Object.fromEntries(walk(d).map(p=>[p,{sha256:hash(below(d,p,true)),bytes:fs.statSync(below(d,p,true)).size}]));
  const bundle={schema:VERSION,contract:CONTRACT,context:c,roles,files};write(path.join(d,'bundle.json'),json(bundle)); const digest=hash(path.join(d,'bundle.json'));
  need(!fs.existsSync(path.join(work,'complete')),'duplicate complete bundle');fs.renameSync(d,path.join(work,'complete'));
  if(!quiet){console.error('[ci-compiler-artifact] seal '+Number(process.hrtime.bigint()-started)/1e6+'ms');console.log(host+'_envelope_sha='+digest);}return digest;
}
function verify(root,dir,host,expected,expectedContext,transport) {
  need(hex(expected,64),'trusted bundle digest is missing'); need(hash(below(dir,'bundle.json',true))===expected,'bundle differs from producer job output');
  const b=load(below(dir,'bundle.json',true));need(b.schema===VERSION&&b.contract===CONTRACT,'envelope version mismatch');need(json(b.context)===json(expectedContext),'trusted workflow context mismatch');
  need(Object.keys(b.roles).sort().join(',')===expectedRoles(host).sort().join(','),'missing/extra roles');
  const actual=walk(dir).filter(p=>p!=='bundle.json');need(actual.join('\n')===Object.keys(b.files).sort(order).join('\n'),'missing/extra/partial files');
  for(const p of actual){const file=below(dir,p,true),m=b.files[p];need(fs.statSync(file).size===m.bytes&&hash(file)===m.sha256,'corrupt payload '+p);}
  const inv=inventory(root), src=sources(root);
  for(const role of expectedRoles(host)) {
    const base=path.join(dir,'roles',role),mp=path.join(base,'manifest.json');need(hash(mp)===b.roles[role],'role manifest mismatch');const m=load(mp);
    need(m.schema===VERSION&&m.contract===CONTRACT&&m.role===role&&json(m.context)===json(expectedContext),'role/context substitution');
    need(m.provenance_key===key(m.fields)&&m.fields.producer_identity===expectedContext.tree&&hex(m.fields.producer_sha256,64)&&m.proof.input_producer_sha256===m.fields.producer_sha256,'producer substitution');
    need(m.fields.source_set_sha256===src.sha256&&fs.readFileSync(path.join(base,'source-set.sha256'),'utf8')===src.manifest,'source-set substitution');
    need(json(m.inventory)===json(inv),'authoritative inventory changed');const rec={argv:JSON.parse(m.fields.argv)};const f=flags(rec,host,role);
    need(m.fields.host===host&&m.fields.target===f.target&&m.fields.cfg===f.cfg&&m.fields.opt_level===f.opt&&m.fields.stdlib_roots===f.roots&&m.fields.profile==='none'&&m.fields.cwd==='{root}'&&m.fields.source_roots==='src,stdlib,tests','provenance field substitution');
    const roleFiles=role==='bootstrap-converged'?['payload/compiler','payload/previous-stage',...generatedPaths(host).map(p=>'generated/'+p)]:['payload/reference.s','inventory/corpus.txt'];
    need(Object.keys(m.files).sort(order).join('\n')===roleFiles.sort(order).join('\n')&&m.fields.output_kind===(role==='bootstrap-converged'?'compiler-binary':'compiler-assembly'),'role file/kind substitution');
    for(const [p,v]of Object.entries(m.files)){need(v.source.startsWith('{root}/'),'external payload source');safeRel(v.source.slice(7));const file=below(base,p,true);need(hash(file)===v.sha256&&fs.statSync(file).size===v.bytes,'role payload corrupt');}
    const env=JSON.parse(m.fields.environment);need(json(env.generated_inputs)===json(m.generated_inputs)&&env.producer_commit===expectedContext.commit&&env.producer_version==='typelisp '+expectedContext.commit,'generated input/commit declaration differs');
    need(json(env.recipes)===json(recipeHashes(root)),'recipe substitution');
    need(env.toolchain&&typeof env.toolchain.node==='string'&&(host==='linux'?['as','ld']:['clang','lld-link']).every(k=>hex(env.toolchain[k]?.sha256,64)&&typeof env.toolchain[k].version==='string'),'toolchain binding missing');
    for(const [p,v]of Object.entries(m.generated_inputs)) need(json(v)===json(m.files['generated/'+p]),'generated input missing from payload');
    if(role==='bootstrap-converged') {
      need(json(env.seed)===json(m.proof.seed),'seed binding differs');
      need(Object.keys(m.generated_inputs).sort(order).join('\n')===generatedPaths(host).sort(order).join('\n'),'generated input closure incomplete');
      binaryShape(below(base,'payload/compiler',true),host);binaryShape(below(base,'payload/previous-stage',true),host);
      need(m.proof.output_identity===expectedContext.tree&&hex(m.proof.seed.sha256,64)&&hex(m.proof.seed.identity,40),'seed/output identity missing');
      need(m.proof.compile_receipt.sha256===m.proof[m.proof.selected_stage+'.s'].sha256&&m.proof.compile_receipt.path==='{root}/target/bootstrap-fixpoint/'+m.proof.selected_stage+'.s','compile receipt differs');
      const pair=m.proof.fixpoint_pair;need(json(pair)===json(m.proof.selected_stage==='stage3'?['stage2.s','stage3.s']:['stage3.s','stage4.s']),'fixpoint stage mismatch');
      need(m.proof[pair[0]].sha256===m.proof[pair[1]].sha256&&m.proof['stage3.s'].sha256===m.proof['stage3-embedded.s'].sha256,'fixpoint/parity proof missing');
      need(fs.readFileSync(below(base,'generated/target/build-stage0/git-hash.txt'),'utf8')===expectedContext.commit&&fs.readFileSync(below(base,'generated/target/build-stage0/tree-hash.txt'),'utf8')===expectedContext.tree,'generated stamps mismatch');
    }else {
      need(m.proof.compared_output_sha256===m.files['payload/reference.s'].sha256,'reference comparison missing');
      need(fs.readFileSync(below(base,'inventory/corpus.txt',true),'utf8')===expectedCorpus(root),'reference inventory missing cases');
      const expectedText='src/main.tl|{root}/target/build-invariance/compare/opt2-built/selfhost_main_opt1.s\n';
      need(m.proof.batch_manifest.text===expectedText&&m.proof.batch_manifest.sha256===sha(expectedText)&&env.batch_manifest.text===expectedText&&env.batch_manifest.sha256===sha(expectedText),'reference batch substitution');
      const boot=load(path.join(dir,'roles/bootstrap-converged/manifest.json'));need(m.fields.producer_sha256===boot.files['payload/compiler'].sha256&&m.proof.parent_provenance_key===boot.provenance_key&&env.parent_provenance_key===boot.provenance_key&&json(env.seed)===json(boot.proof.seed)&&json(m.proof.seed)===json(boot.proof.seed),'reference producer role substitution');
    }
  }
  if(transport) verifyTransport(expectedContext,transport);
  return {schema:VERSION,host,context:expectedContext,roles:Object.keys(b.roles),bundle_sha256:expected,status:'ok'};
}
function verifyTransport(c,t) {
  const jobName=c.host==='linux'?'Test + Integration':'Test + Integration (windows-latest)';
  const jobs=t.jobs.jobs.filter(j=>j.name===jobName);need(jobs.length===1,'producer job ambiguous');const j=jobs[0];
  need(j.run_id===Number(c.run_id)&&j.run_attempt===c.attempt&&j.head_sha===c.head&&j.status==='completed'&&j.conclusion==='success','producer attempt/job did not succeed');
  const arts=t.artifacts.artifacts.filter(a=>a.name===artifactName(c)&&!a.expired);need(arts.length===1,'artifact missing/ambiguous');const a=arts[0];
  need(a.workflow_run.id===Number(c.run_id)&&a.workflow_run.head_sha===c.head&&/^sha256:[0-9a-f]{64}$/.test(a.digest),'artifact run binding failed');
  need(Date.parse(a.created_at)>=Date.parse(j.started_at)&&Date.parse(a.created_at)<=Date.parse(j.completed_at),'artifact from a different producer attempt');
}

function selfTest(actualRoot,work) {
  need(!fs.existsSync(work),'self-test directory must be fresh');fs.mkdirSync(work,{recursive:true});
  const source=path.join(work,'source');fs.mkdirSync(source);const results=[];
  for(const [p,v]of Object.entries({'src/main.tl':'fixture source\n','stdlib/prelude.tl':'fixture stdlib\n','scripts/ci-gates.tsv':'fixture gate inventory\n','scripts/ci-compiler-artifacts.tsv':'fixture role inventory\n'}))write(path.join(source,p),v);
  for(const name of Object.keys(recipeHashes(actualRoot)))if(!fs.existsSync(path.join(source,name)))write(path.join(source,name),'fixture recipe '+name+'\n');
  write(path.join(source,'scripts/expand-integration-manifest.awk'),fs.readFileSync(path.join(actualRoot,'scripts/expand-integration-manifest.awk')));
  write(path.join(source,'tests/integration/native.manifest'),fs.readFileSync(path.join(actualRoot,'tests/integration/native.manifest'),'utf8').split('\n').find(l=>l&&!l.startsWith('#'))+'\n');
  cp.execFileSync('git',['init','-q',source]);cp.execFileSync('git',['-C',source,'add','src','stdlib','tests','scripts']);
  const src=sources(source), inventoryValue=inventory(source), c={scope:'github',repository:'owner/repo',run_id:'1234',attempt:2,commit:'a'.repeat(40),tree:'b'.repeat(40),head:'c'.repeat(40),workflow_ref:'owner/repo/.github/workflows/ci.yml@refs/pull/1/merge',workflow_sha:'d'.repeat(40)};
  const golden=['1'.repeat(64),'2'.repeat(40),'linux','linux-x86_64','{root}','src,stdlib','stdlib,src','linux,unix','2','none','baseline','compile src/main.tl','3'.repeat(64),'compiler-assembly'];
  need(key(Object.fromEntries(FIELDS.map((k,i)=>[k,golden[i]])))==='5ece1550f75aff6115c39ab8301dc7ddc2e45bf953641f0658a63b4988d1919e','legacy #6883 key changed');
  results.push({case:'legacy-key-vector',status:'pass'});
  function fakeBinary(host) {const b=Buffer.alloc(128);if(host==='linux'){b.set([127,69,76,70,2]);b.writeUInt16LE(62,18);}else{b.set([77,90]);b.writeUInt32LE(64,60);b.set([80,69,0,0],64);b.writeUInt16LE(0x8664,68);}return b;}
  function fixture(host) {
    const contextValue={...c,host}, w=path.join(work,'base-'+host),draft=path.join(w,'draft');write(path.join(draft,'context.json'),json(contextValue));
    for(const role of expectedRoles(host)) {
      const base=path.join(draft,'roles',role),files={},generated={},proof={};fs.mkdirSync(base,{recursive:true});
      function put(p,data) {const q=path.join(base,p);write(q,data);files[p]={sha256:hash(q),bytes:fs.statSync(q).size,source:'{root}/'+p};return files[p];}
      let argv,kind,opt,roots,cfg;
      const nativeCfg=host==='linux'?['linux','unix','target-linux','os-linux']:['windows','target-windows','os-windows'];
      if(role==='bootstrap-converged') {
        put('payload/compiler',fakeBinary(host));put('payload/previous-stage',fakeBinary(host));
        for(const name of generatedPaths(host))generated[name]=put('generated/'+name,name.endsWith('/git-hash.txt')?c.commit:name.endsWith('/tree-hash.txt')?c.tree:'fixture '+name+'\n');
        const asm={sha256:sha('assembly'),bytes:8};Object.assign(proof,{'stage2.s':asm,'stage3.s':asm,'stage3-embedded.s':asm,selected_stage:'stage3',fixpoint_pair:['stage2.s','stage3.s'],output_identity:c.tree,seed:{sha256:'4'.repeat(64),identity:'5'.repeat(40),path:'{root}/target/stage0/typelisp'},compile_receipt:{...asm,path:'{root}/target/bootstrap-fixpoint/stage3.s'}});
        cfg=nativeCfg.concat(['compiler-build-identity','embedded-stdlib-tlci']);kind='compiler-binary';opt='2';roots='{root}/src';
        argv=['{root}/target/bootstrap-fixpoint/stage2'+(host==='windows'?'.exe':''),'compile','src/main.tl','-o','{root}/target/bootstrap-fixpoint/stage3.s','--target',host+'-x86_64',...cfg.flatMap(x=>['--cfg',x]),'--stdlib-root','{root}/src','--opt-level','2'];
      } else {
        put('payload/reference.s','assembly');put('inventory/corpus.txt',expectedCorpus(source));proof.compared_output_sha256=sha('assembly');const parent=load(path.join(draft,'roles/bootstrap-converged/manifest.json'));proof.seed=parent.proof.seed;proof.parent_provenance_key=parent.provenance_key;
        const text='src/main.tl|{root}/target/build-invariance/compare/opt2-built/selfhost_main_opt1.s\n';proof.batch_manifest={text,sha256:sha(text),raw_sha256:'6'.repeat(64)};
        cfg=nativeCfg;kind='compiler-assembly';opt='1';roots='stdlib,src';argv=['{root}/target/bootstrap-fixpoint/stage3','compile','--batch','{root}/target/build-invariance/batches/opt2-built/opt1/chunks/entries.0000.txt','--target','linux-x86_64',...cfg.flatMap(x=>['--cfg',x]),'--backend-mode','scalar','--opt-level','1','--stdlib-root','stdlib','--stdlib-root','src'];
      }
      const tools={node:'fixture'},toolNames=host==='linux'?['as','ld']:['clang','lld-link'];for(const n of toolNames)tools[n]={sha256:'7'.repeat(64),version:'fixture version'};
      const env={producer_commit:c.commit,producer_version:'typelisp '+c.commit,toolchain:tools,generated_inputs:generated,seed:proof.seed||null,parent_provenance_key:proof.parent_provenance_key||null,recipes:recipeHashes(source),variables_sha256:{},resource_wrapper:[],batch_manifest:proof.batch_manifest?{text:proof.batch_manifest.text,sha256:proof.batch_manifest.sha256}:null};
      const fields={producer_sha256:role==='bootstrap-converged'?'8'.repeat(64):sha(fakeBinary(host)),producer_identity:c.tree,host,target:host+'-x86_64',cwd:'{root}',source_roots:'src,stdlib,tests',stdlib_roots:roots,cfg:cfg.join(','),opt_level:opt,profile:'none',environment:JSON.stringify(env),argv:JSON.stringify(argv),source_set_sha256:src.sha256,output_kind:kind};
      proof.input_producer_sha256=fields.producer_sha256;
      write(path.join(base,'source-set.sha256'),src.manifest);write(path.join(base,'manifest.json'),json({schema:VERSION,contract:CONTRACT,role,context:contextValue,fields,provenance_key:key(fields),files,generated_inputs:generated,proof,inventory:inventoryValue,packaging_ms:0}));
    }
    const digest=sealDirectory(w,host,draft,contextValue,true);return {dir:path.join(w,'complete'),digest,context:contextValue,host};
  }
  function transport(f) {return {jobs:{jobs:[{name:f.host==='linux'?'Test + Integration':'Test + Integration (windows-latest)',run_id:1234,run_attempt:2,head_sha:c.head,status:'completed',conclusion:'success',started_at:'2026-10-27T00:00:00Z',completed_at:'2026-10-27T00:00:10Z'}]},artifacts:{artifacts:[{name:artifactName(f.context),expired:false,workflow_run:{id:1234,head_sha:c.head},digest:'sha256:'+'9'.repeat(64),created_at:'2026-10-27T00:00:05Z'}]}};}
  const fixtures=['linux','windows'].map(fixture);
  for(const f of fixtures){verify(source,f.dir,f.host,f.digest,f.context,transport(f));results.push({case:'complete-'+f.host,status:'pass'});}
  let serial=0;
  function clone(f){const dir=path.join(work,'negative-'+(++serial));fs.cpSync(f.dir,dir,{recursive:true,errorOnExist:true,force:false});return {...f,dir};}
  function rebind(f) {const p=path.join(f.dir,'bundle.json'),b=load(p);for(const role of Object.keys(b.roles))b.roles[role]=hash(path.join(f.dir,'roles',role,'manifest.json'));b.files=Object.fromEntries(walk(f.dir).filter(p=>p!=='bundle.json').map(p=>[p,{sha256:hash(below(f.dir,p,true)),bytes:fs.statSync(below(f.dir,p,true)).size}]));fs.writeFileSync(p,json(b));f.digest=hash(p);}
  function change(f,edit){const p=path.join(f.dir,'roles/bootstrap-converged/manifest.json'),m=load(p);edit(m);m.provenance_key=key(m.fields);fs.writeFileSync(p,json(m));rebind(f);}
  function reject(name,fn){let error;try{fn();}catch(e){error=e.message;}need(error,'fixture accepted '+name);results.push({case:name,status:'rejected',reason:error});}
  const base=fixtures[0];
  for(const [name,edit]of [
    ['producer-identity',m=>{m.fields.producer_identity='e'.repeat(40);}],
    ['producer-digest',m=>{m.fields.producer_sha256='f'.repeat(64);}],
    ['output-kind',m=>{m.fields.output_kind='wrong-kind';}],
    ['target',m=>{m.fields.target='windows-x86_64';}],
    ['cfg',m=>{m.fields.cfg+=',compile-profile';}],
    ['opt',m=>{m.fields.opt_level='0';}],
    ['source-set',m=>{m.fields.source_set_sha256='f'.repeat(64);}],
    ['inventory',m=>{m.inventory['scripts/ci-gates.tsv']='f'.repeat(64);}],
    ['seed-binding',m=>{m.proof.seed.sha256='f'.repeat(64);}],
    ['missing-generated',m=>{m.generated_inputs={};const env=JSON.parse(m.fields.environment);env.generated_inputs={};m.fields.environment=JSON.stringify(env);}],
    ['partial-fixpoint',m=>{m.proof['stage2.s'].sha256='f'.repeat(64);}],
    ['path-escape',m=>{m.files['../outside']={sha256:'f'.repeat(64),bytes:1};}],
    ['absolute-path',m=>{m.files['/tmp/outside']={sha256:'f'.repeat(64),bytes:1};}]
  ]){const f=clone(base);change(f,edit);reject(name,()=>verify(source,f.dir,f.host,f.digest,f.context,transport(f)));}
  {const f=clone(base);fs.appendFileSync(path.join(f.dir,'roles/bootstrap-converged/payload/compiler'),'corrupt');reject('payload-corruption',()=>verify(source,f.dir,f.host,f.digest,f.context,transport(f)));}
  {const f=clone(base);fs.appendFileSync(path.join(f.dir,'bundle.json'),' ');reject('untrusted-resealed-root',()=>verify(source,f.dir,f.host,f.digest,f.context,transport(f)));}
  {const f=clone(base), b=load(path.join(f.dir,'bundle.json'));b.context.attempt=1;fs.writeFileSync(path.join(f.dir,'bundle.json'),json(b));f.digest=hash(path.join(f.dir,'bundle.json'));reject('attempt-N-minus-1',()=>verify(source,f.dir,f.host,f.digest,base.context,transport(f)));}
  {const f=clone(base),t=transport(f);t.jobs.jobs[0].run_attempt=1;reject('producer-job-N-minus-1',()=>verify(source,f.dir,f.host,f.digest,f.context,t));}
  {const f=clone(base),t=transport(f);t.artifacts.artifacts[0].created_at='2026-10-26T23:59:59Z';reject('old-artifact-renamed-for-N',()=>verify(source,f.dir,f.host,f.digest,f.context,t));}
  {const f=clone(base),t=transport(f);t.jobs.jobs[0].conclusion='failure';reject('producer-failed',()=>verify(source,f.dir,f.host,f.digest,f.context,t));}
  {const f=clone(base),t=transport(f);t.jobs.jobs[0].head_sha='f'.repeat(40);reject('producer-head-substitution',()=>verify(source,f.dir,f.host,f.digest,f.context,t));}
  {const f=clone(base),t=transport(f);t.artifacts.artifacts[0].workflow_run.id=1233;reject('artifact-run-substitution',()=>verify(source,f.dir,f.host,f.digest,f.context,t));}
  {const f=clone(base),t=transport(f);t.artifacts.artifacts[0].expired=true;reject('expired-artifact',()=>verify(source,f.dir,f.host,f.digest,f.context,t));}
  for(const [name,value]of [['repository','other/repo'],['tree','e'.repeat(40)],['workflow_sha','f'.repeat(40)]]) {
    const f=clone(base),expectedContext={...f.context,[name]:value};
    reject('trusted-'+name+'-substitution',()=>verify(source,f.dir,f.host,f.digest,expectedContext,transport(f)));
  }
  {const f=clone(base),t=transport(f);t.artifacts.artifacts.push(t.artifacts.artifacts[0]);reject('duplicate-artifact',()=>verify(source,f.dir,f.host,f.digest,f.context,t));}
  {const f=clone(base);write(path.join(f.dir,'roles/bootstrap-converged/payload/unlisted'),'extra');reject('extra-payload',()=>verify(source,f.dir,f.host,f.digest,f.context,transport(f)));}
  {const f=clone(base),b=load(path.join(f.dir,'bundle.json'));b.roles={};fs.writeFileSync(path.join(f.dir,'bundle.json'),json(b));f.digest=hash(path.join(f.dir,'bundle.json'));reject('missing-role',()=>verify(source,f.dir,f.host,f.digest,f.context,transport(f)));}
  {const partial=path.join(work,'unpublished');write(path.join(partial,'draft/roles/bootstrap-converged.publishing/data'),'partial');reject('partial-publication',()=>verify(source,partial,'linux',base.digest,base.context,transport(base)));need(!fs.existsSync(path.join(partial,'complete')),'partial became complete');}
  {const f=clone(base),outside=path.join(work,'outside');fs.mkdirSync(outside);write(path.join(outside,'marker'),'untouched');fs.symlinkSync(outside,path.join(f.dir,'redirect'),'junction');reject('junction-escape',()=>verify(source,f.dir,f.host,f.digest,f.context,transport(f)));need(fs.readFileSync(path.join(outside,'marker'),'utf8')==='untouched','escape wrote outside');}
  reject('Windows-absolute-relative-path',()=>safeRel('C:/outside'));
  reject('backslash-escape',()=>safeRel('a\\..\\outside'));
  reject('partial-seal',()=>sealDirectory(path.join(work,'bad-seal'),'linux',path.join(work,'unpublished/draft'),base.context,true));
  const report={schema:VERSION,status:'pass',cases:results};write(path.join(work,'self-test.json'),json(report));console.log(json(report));console.log('ci-compiler-artifact self-tests passed: '+results.length+' cases');
}

function main() {
  if(op==='key') {need(args.length===14,'key expects #6883 fourteen fields');console.log(key(Object.fromEntries(FIELDS.map((k,i)=>[k,args[i]]))));return;}
  const root=fs.realpathSync(args.shift()),work=owned(root,args.shift()),host=args.shift().toLowerCase();
  if(op==='self-test')selfTest(root,work);
  else if(op==='init'||op==='init-local')init(root,work,host,op==='init-local');
  else if(op==='record')record(root,work,host,args.shift(),args);
  else if(op==='publish')publish(root,work,host,args.shift(),args);
  else if(op==='seal')seal(root,work,host);
  else if(op==='verify'||op==='verify-local') {
    const started=process.hrtime.bigint(),expected=args.shift(),ctx=context(root,host,op==='verify-local');
    const transport=op==='verify'?{jobs:JSON.parse(fs.readFileSync(args.shift(),'utf8')),artifacts:JSON.parse(fs.readFileSync(args.shift(),'utf8'))}:null;
    const result=verify(root,work,host,expected,ctx,transport);result.readback_ms=Number(process.hrtime.bigint()-started)/1e6;console.log(json(result));
  } else throw Error('unknown operation '+op);
}
try { main(); } catch(e) {console.error('[ci-compiler-artifact] '+e.message);process.exitCode=1;}
JS
}
