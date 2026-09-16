#!/usr/bin/env python3
"""Validate the implementation handoff package, NOT a Symphony product build."""
from pathlib import Path
import argparse, csv, hashlib, json, re, sys
import yaml
from jsonschema import Draft202012Validator, FormatChecker
from openapi_spec_validator import validate as validate_openapi

ROOT=Path(__file__).resolve().parents[1]
checks=[]
def check(name, fn):
    try:
        detail=fn()
        checks.append({'check':name,'status':'passed','detail':str(detail or 'ok')})
    except Exception as exc:
        checks.append({'check':name,'status':'failed','detail':str(exc)})
def read(p):return (ROOT/p).read_text(encoding='utf-8')
def data(p):return json.loads(read(p))
def require(condition,msg):
    if not condition:raise AssertionError(msg)
def sha(p):return hashlib.sha256((ROOT/p).read_bytes()).hexdigest()

def inventory():
    required=['START_HERE.md','PRD.md','SPEC.md','TECHNICAL_WHITEPAPER.md','AGENTS.md','IMPLEMENTATION_GOAL.md','docs/SPEC_EXTENSION.md','docs/CONFORMANCE.md','docs/ARCHITECTURE.md','docs/DOMAIN_MODEL.md','docs/STATE_AND_CONSISTENCY.md','docs/API_CONTRACT.md','docs/INTERNAL_CONTRACTS.md','docs/UI_ACTIONS.md','docs/GIT_WORKFLOW.md','docs/GIT_ACCEPTANCE.md','planning/git-policy.json','scripts/check_commit_message.py','scripts/commit-msg.hook.example','scripts/refresh_manifest.py','upstream/pull_request_template.original.md','docs/INTERACTION_SPEC.md','docs/VISUAL_SPEC.md','docs/ARCHIFY_INTEGRATION.md','docs/DEVICE_EVIDENCE.md','docs/ACCEPTANCE.md','docs/IMPLEMENTATION_PLAN.md','docs/OPERATIONS.md','docs/DECISIONS.md','contracts/entities.schema.json','contracts/openapi.yaml','contracts/agent-tools.json','contracts/device-frame.schema.json','contracts/architecture-manifest.schema.json','contracts/workbench-config.schema.json','design/tokens.json','design/tokens.css','design/README.md','design/reference/design-prompt.md','design/soft-glass/README.md','design/soft-glass/manifest.json','design/soft-glass/design/Symphony-Soft-Glass-guide.md','design/soft-glass/previews/01-issues.png','design/soft-glass/previews/02-investigation.png','design/soft-glass/previews/03-devices.png','design/soft-glass/previews/04-review.png','docs/DESIGN_UPDATE_SOFT_GLASS.md','planning/tasks.json','planning/test-catalog.json','planning/traceability.csv','fixtures/demo.json','config/WORKFLOW.example.md','config/embedded-profile.yaml','config/devices.example.yaml','config/environment.example.yaml','prompts/archify-project.md','prompts/archify-delta.md','prompts/archify-review.md','templates/handoff.md','templates/release-report.md','sources.lock.json','requirements-validation.txt']
    for path in required:require((ROOT/path).is_file() and (ROOT/path).stat().st_size>0,'missing/empty '+path)
    return f'{len(required)} required entrypoints exist'
def baseline():
    lock=data('sources.lock.json')
    require(sha('upstream/SPEC.original.md')==lock['symphony']['spec_sha256'],'upstream SPEC differs from inspected baseline')
    expected=(ROOT/'upstream/SPEC.original.md').read_bytes()+b'\n\n---\n\n'+(ROOT/'docs/SPEC_EXTENSION.md').read_bytes()
    require((ROOT/'SPEC.md').read_bytes()==expected,'combined SPEC differs from exact original + extension')
    for item in lock['attachments']:require(sha(item['package_path'])==item['sha256'],'attachment changed: '+item['package_path'])
    return 'Original SPEC and all current Soft Glass source files preserved; combined SPEC synchronized'
def syntax():
    j=list(ROOT.rglob('*.json'));y=list(ROOT.rglob('*.yaml'))
    for p in j:json.loads(p.read_text())
    for p in y:yaml.safe_load(p.read_text())
    return f'{len(j)} JSON and {len(y)} YAML files parsed'
def schemas():
    files=list((ROOT/'contracts').glob('*.schema.json'))
    for p in files:Draft202012Validator.check_schema(json.loads(p.read_text()))
    return f'{len(files)} JSON Schema Draft 2020-12 documents valid'
def ventity(name,value):
    schema=data('contracts/entities.schema.json')
    Draft202012Validator({'$schema':schema['$schema'],'$defs':schema['$defs'],'$ref':'#/$defs/'+name},format_checker=FormatChecker()).validate(value)
def fixtures():
    n=0
    for p in (ROOT/'fixtures/entities').glob('*.json'):
        ventity(p.stem,json.loads(p.read_text()));n+=1
    demo=data('fixtures/demo.json')
    for field,entity in [('issues','Issue'),('problems','ProblemCase'),('evidence','Evidence'),('validations','Validation'),('decisions','Decision'),('devices','Device'),('sessions','DeviceSession'),('operations','Operation'),('events','Event')]:
        for value in demo[field]:ventity(entity,value);n+=1
    df=Draft202012Validator(data('contracts/device-frame.schema.json'),format_checker=FormatChecker())
    for f in data('fixtures/device-frames.json'):df.validate(f);n+=1
    wf=yaml.safe_load(read('config/WORKFLOW.example.md').split('---',2)[1])
    Draft202012Validator(data('contracts/workbench-config.schema.json')).validate(wf['workbench'])
    return f'{n} entity/helper examples and workbench configuration valid'
def api():
    api=yaml.safe_load(read('contracts/openapi.yaml'));validate_openapi(api)
    defs=data('contracts/entities.schema.json')['$defs']
    def canonical(x):
        if isinstance(x,dict):return {k:(v.replace('#/components/schemas/','#/$defs/') if k=='$ref' else canonical(v)) for k,v in x.items()}
        if isinstance(x,list):return [canonical(v) for v in x]
        return x
    for name,val in defs.items():require(canonical(api['components']['schemas'][name])==val,'API schema drift: '+name)
    require(api['servers'][0]['url']=='/experience/v1','API scope collision')
    return f'OpenAPI 3.1 valid; {len(defs)} shared definitions identical'
def tools():
    manifest=data('contracts/agent-tools.json');defs=data('contracts/entities.schema.json')['$defs']
    require(manifest['definitions']==defs,'Agent definitions drift')
    names=[x['name'] for x in manifest['tools']];require(len(set(names))==len(names),'Duplicate tool name')
    for tool in manifest['tools']:Draft202012Validator.check_schema({'$defs':defs,**tool['inputSchema']})
    return f'{len(names)} agent tool input schemas valid'
def rejects():
    import copy
    count=0
    def invalid(name,v):
        nonlocal count
        try:ventity(name,v)
        except Exception:count+=1;return
        raise AssertionError('invalid input accepted: '+name)
    v=data('fixtures/entities/OperationRequest.json');v['actor']={'kind':'human','id':'spoof'};invalid('OperationRequest',v)
    v=data('fixtures/entities/OperationRequest.json');v['payload']['resume_after_apply']='yes';invalid('OperationRequest',v)
    v=data('fixtures/entities/Evidence.json');v['raw'][0]['blob_sha256']='not-a-hash';invalid('Evidence',v)
    v=data('fixtures/entities/Evidence.json');del v['binding'];invalid('Evidence',v)
    v=data('fixtures/entities/Event.json');v['project_seq']=0;invalid('Event',v)
    v=data('fixtures/entities/DeviceSession.json');v['binding_status']='verified';invalid('DeviceSession',v)
    v=data('fixtures/entities/Decision.json');v['status']='executed_and_verified';invalid('Decision',v)
    v=data('fixtures/entities/Operation.json');v['status']='success';invalid('Operation',v)
    return f'{count} malformed/ambiguous fixtures rejected (schema only, not service tests)'
def relationships():
    demo=data('fixtures/demo.json');counts={}
    for x in demo['issues']:counts[x['display_column']]=counts.get(x['display_column'],0)+1
    require(counts=={'待办':3,'进行中':3,'待审阅':1,'已完成':1},'8-card data drift')
    require(demo['decisions'][0]['status']=='draft' and demo['decisions'][0]['selected_option_id'] is None,'candidate selection became adoption')
    require(demo['evidence'][0]['binding']['build_id']=='demo-build','attachment evidence build drift')
    require(demo['devices'][0]['build_id']=='demo-build-12','attachment device build drift')
    require(demo['evidence'][0]['capture_session_id']!=demo['devices'][0]['active_session_id'],'unknown sessions falsely merged')
    for ev in demo['evidence']:
        for raw in ev['raw']:
            b=(ROOT/'fixtures/raw/E-017.txt').read_bytes()
            require(hashlib.sha256(b).hexdigest()==raw['blob_sha256'],'raw hash mismatch')
            require(0<=raw['start_byte']<=raw['end_byte_exclusive']<=len(b),'raw bounds wrong')
    require(len(read('fixtures/raw/E-017.txt').splitlines())==5,'evidence log line drift')
    require(len(read('fixtures/raw/Board-01-serial.txt').splitlines())==7,'device log line drift')
    return '8 cards, draft adoption, distinct unconfirmed build sessions and raw log hashes correct'
def trace():
    tasks=data('planning/tasks.json')['tasks'];tc=data('planning/test-catalog.json')['tests'];req={f'R{i:02}' for i in range(1,13)}
    ids={t['id'] for t in tasks};tids={t['id'] for t in tc}
    require(len(ids)==len(tasks),'duplicate task ids');require(len(tids)==24,'expected 24 acceptance scenarios')
    for t in tasks:
        require(set(t['depends_on'])<=ids,'unknown dependency '+t['id'])
        require(set(t['requirements'])<=req,'unknown requirement')
        require(set(t['acceptance_tests'])<=tids,'unknown TC')
        require(t['status']=='planned','package must not claim implementation complete')
    visited=set();active=set();by={t['id']:t for t in tasks}
    def visit(x):
        require(x not in active,'cyclic task dependencies')
        if x in visited:return
        active.add(x)
        for dep in by[x]['depends_on']:visit(dep)
        active.remove(x);visited.add(x)
    for x in ids:visit(x)
    rows=list(csv.DictReader(read('planning/traceability.csv').splitlines()))
    require({x['requirement_id'] for x in rows}==req,'trace requirement coverage incomplete')
    for row in rows:
        require(set(row['tasks'].split(';'))<=ids,'unknown traced task')
        require(set(row['acceptance_tests'].split(';'))<=tids,'unknown traced test')
        require(row['implementation_status']=='not_started' and row['evidence']=='','unrun product marked delivered')
    acceptance=read('docs/ACCEPTANCE.md')
    for t in tc:require(t['id'] in acceptance and t['status']=='not_run','test missing or false pass')
    return f'{len(req)} requirements, {len(tasks)} acyclic tasks, {len(tids)} planned acceptance scenarios'
def links():
    n=0
    for p in ROOT.rglob('*.md'):
        if 'upstream' in p.parts or p.name=='SPEC.md':continue # upstream relative links belong to upstream checkout
        for target in re.findall(r'\[[^\]]*\]\(([^)]+)\)',p.read_text()):
            if re.match(r'^[a-zA-Z][a-zA-Z0-9+.-]*:',target) or target.startswith('#'):continue
            path=target.split('#')[0]
            if not path:continue
            require((p.parent/path).exists(),f'broken link in {p.relative_to(ROOT)}: {target}');n+=1
    return f'{n} local Markdown links resolve'
def visual():
    t=data('design/tokens.json');css=read('design/tokens.css')
    src='design/soft-glass/design/'
    require((ROOT/'design/tokens.json').read_bytes()==(ROOT/(src+'Symphony-Soft-Glass.tokens.json')).read_bytes(),'token source copy drift')
    require((ROOT/'design/tokens.css').read_bytes()==(ROOT/(src+'Symphony-Soft-Glass.css')).read_bytes(),'CSS source copy drift')
    require((ROOT/'design/reference/design-prompt.md').read_bytes()==(ROOT/(src+'Symphony-design-prompt.md')).read_bytes(),'business source copy drift')
    for k,v in t['colors'].items():
        slug=re.sub(r'([A-Z])',lambda m:'-'+m.group(1).lower(),k)
        require(f'--sg-{slug}: {v};' in css,'CSS color mismatch: '+k)
    require(t['typography']['body']==15 and t['typography']['title']==28 and t['typography']['log']==13,'new font sizes drift')
    require(t['radius']=={'control':10,'card':16,'panel':20},'new radii drift')
    require(t['material']['contentOpacity']==1 and t['material']['blur']==16,'material boundary drift')
    require('prefers-reduced-motion' in css and 'prefers-reduced-transparency' in css,'material/motion fallback missing')
    require('--color-background' not in css,'obsolete CSS namespace')
    require('Soft Glass' in read('AGENTS.md') and 'Soft Glass' in read('IMPLEMENTATION_GOAL.md'),'agent entrypoints not updated')
    require('15px' in read('docs/ACCEPTANCE.md') and '44px' in read('docs/ACCEPTANCE.md'),'new acceptance criteria missing')
    return 'Soft Glass source copies, full color mapping, 15/28px typography, 10/16/20px radii and fallback declarations verified; browser behavior not tested'
def design_manifest():
    m=data('design/soft-glass/manifest.json')
    for item in m['files']:
        p=ROOT/'design/soft-glass'/item['path']
        require(p.is_file(),'missing source asset '+item['path'])
        require(p.stat().st_size==item['bytes'],'source size mismatch '+item['path'])
        require(hashlib.sha256(p.read_bytes()).hexdigest()==item['sha256'].lower(),'source digest mismatch '+item['path'])
    require(not (ROOT/'design/reference/four-screens-preview.png').exists(),'old preview still active')
    require(not (ROOT/'design/reference/image-generation-prompt.txt').exists(),'old generation prompt still active')
    return f"{len(m['files'])} vendor-manifest assets verified; obsolete preview/prompt removed"
def git_policy():
    import subprocess
    p=data('planning/git-policy.json')
    require(p['message']['scope_required'] and p['message']['header_max_characters']==72,'commit header policy drift')
    require(not p['branch']['force_push'] and not p['branch']['rewrite_published_history'],'published history protection drift')
    require('Merging' in read('docs/GIT_WORKFLOW.md') and 'land' in read('docs/GIT_WORKFLOW.md'),'original merge workflow missing')
    result=subprocess.run([sys.executable,str(ROOT/'scripts/check_commit_message.py'),'--self-test'],capture_output=True,text=True)
    require(result.returncode==0,'commit validator self-tests failed: '+result.stderr)
    require('GIT_WORKFLOW.md' in read('AGENTS.md') and 'GIT_WORKFLOW.md' in read('IMPLEMENTATION_GOAL.md'),'Git rules missing from agent entrypoints')
    return 'Conventional Commit project policy and 7 validator self-test groups passed; target hook/CI/remote operations not exercised'
def manifest():
    m=ROOT/'MANIFEST.sha256'
    if not m.exists():return 'not sealed yet; run with --require-manifest for release'
    listed=set()
    for line in m.read_text().splitlines():
        digest,path=line.split('  ',1);require(sha(path)==digest,'hash mismatch: '+path);listed.add(path)
    actual={str(p.relative_to(ROOT)) for p in ROOT.rglob('*') if p.is_file() and p.name!='MANIFEST.sha256' and '__pycache__' not in p.parts}
    require(listed==actual,'manifest file set differs')
    return f'{len(listed)} files sealed and matched'

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--json',action='store_true');parser.add_argument('--require-manifest',action='store_true');args=parser.parse_args()
    for name,fn in [('inventory',inventory),('baseline',baseline),('syntax',syntax),('schemas',schemas),('fixtures',fixtures),('openapi',api),('agent_tools',tools),('negative_fixtures',rejects),('fixture_relationships',relationships),('traceability',trace),('local_links',links),('visual_tokens',visual),('design_source_manifest',design_manifest),('git_policy',git_policy)]:check(name,fn)
    if args.require_manifest:check('manifest_present',lambda:require((ROOT/'MANIFEST.sha256').exists(),'missing manifest'))
    if (ROOT/'MANIFEST.sha256').exists():check('manifest',manifest)
    result={'scope':'implementation_package_only','product_test_status':'not_run','passed':sum(x['status']=='passed' for x in checks),'failed':sum(x['status']=='failed' for x in checks),'checks':checks}
    if args.json:print(json.dumps(result,ensure_ascii=False,indent=2))
    else:
        for c in checks:print(f"{c['status'].upper():6} {c['check']}: {c['detail']}")
        print(f"Package checks: {result['passed']} passed / {result['failed']} failed. Product tests: NOT RUN.")
    return bool(result['failed'])
if __name__=='__main__':sys.exit(main())
