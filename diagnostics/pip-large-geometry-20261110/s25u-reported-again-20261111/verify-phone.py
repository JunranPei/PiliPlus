import subprocess,json,pathlib,time,sys
root=pathlib.Path(__file__).resolve().parent
if len(sys.argv)>1:
    root=root/sys.argv[1]
    root.mkdir(exist_ok=True)
cli=pathlib.Path('tool/pili_cli.py').resolve()
steps=[]
checks=[]
def run(name,command,value=None):
    args=[sys.executable,'-X','utf8',str(cli),'--serial','R5CY13T5Z3J','--out',str(root/(name+'.json')),command]
    if value is not None:args.append(str(value))
    result=subprocess.run(args,capture_output=True,text=True,encoding='utf8',timeout=65)
    (root/(name+'.log')).write_text(result.stdout+result.stderr,encoding='utf8')
    if result.returncode:raise RuntimeError(name+': '+result.stderr[-800:])
    data=json.loads((root/(name+'.json')).read_text(encoding='utf8'))
    state=data.get('after',data).get('result',{})
    if command=='open':
        for attempt in range(30):
            if state.get('native',{}).get('current-ao') and state.get('durationMs',0)>0 and not state.get('buffering'):break
            time.sleep(.5)
            ready=subprocess.run([sys.executable,'-X','utf8',str(cli),'--serial','R5CY13T5Z3J','status'],capture_output=True,text=True,encoding='utf8',timeout=25)
            (root/(name+'-ready.log')).open('a',encoding='utf8').write(ready.stdout+ready.stderr)
            if ready.returncode:continue
            data=json.loads(ready.stdout);state=data.get('result',{})
    if 'native' in state:
        assert state.get('deviceSdk')==37,state
        assert state.get('native',{}).get('current-ao')=='audiotrack',state
    steps.append({'name':name,'cid':state.get('cid'),'positionMs':state.get('positionMs'),'playing':state.get('playing'),'native':state.get('native'),'utcMs':data.get('after',data).get('utcMs')})
    print(json.dumps(steps[-1]),flush=True)
    (root/'phone-results.json').write_text(json.dumps(steps,indent=2),encoding='utf8')
    return state
def touch(name,command,value):
    first=run(name,command,value)
    for attempt in range(20):
        if not first.get('buffering') and first.get('native',{}).get('seeking')=='no':break
        time.sleep(.5)
        first=run(name+'-settled'+str(attempt),'status')
    if first.get('buffering') or first.get('native',{}).get('seeking')!='no':
        checks.append({'name':name,'cid':first.get('cid'),'outcome':'seek_not_completed','state':first})
        (root/'progress-checks.json').write_text(json.dumps(checks,indent=2),encoding='utf8')
        run(name+'-export','export')
        return
    time.sleep(3)
    later=run(name+'-later','status')
    assert first['playing'] and later['playing'],(name,'paused')
    delta=later['positionMs']-first['positionMs']
    outcome='continuous' if 2000<delta<6000 else ('stalled' if delta<200 else 'slow_or_interrupted')
    check={'name':name,'cid':later['cid'],'elapsedMs':steps[-1]['utcMs']-next(x['utcMs'] for x in reversed(steps[:-1]) if x['positionMs']==first['positionMs']),'advanceMs':delta,'outcome':outcome}
    if outcome!='continuous':
        time.sleep(3)
        extra=run(name+'-extended','status')
        check['extendedAdvanceMs']=extra['positionMs']-later['positionMs']
    checks.append(check)
    (root/'progress-checks.json').write_text(json.dumps(checks,indent=2),encoding='utf8')
plan=pathlib.Path(__file__).resolve().parent/'ten-video-plan.json'
videos=json.loads(plan.read_text(encoding='utf8')) if plan.exists() else [{'bvid':b} for b in ['BV1xU4E6iE9y','BV1zXTC63EWV','BV1xU4E6iE9y']]
for number,entry in enumerate(videos):
    if len(sys.argv)>2 and number<int(sys.argv[2]):continue
    video=entry['bvid']
    prefix=f'video{number+1}'
    opened=run(prefix+'-open','open',video)
    if entry.get('cid'):assert opened['cid']==entry['cid'],('wrong media',entry,opened)
    run(prefix+'-play','play')
    touch(prefix+'-click','click-progress',50 if number!=1 else 20)
    touch(prefix+'-drag','drag-progress',25 if number!=1 else 10)
run('pip-enter','pip')
run('pip-return','launch')
time.sleep(1)
run('pip-play','play')
touch('pip-after-click','click-progress',40)
run('final-export','export')
print('PROGRESS CHECKS RECORDED',flush=True)
