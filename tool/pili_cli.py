"""ADB control and accessibility-tree operations. No image recognition."""
import argparse,json,subprocess,time,uuid,pathlib,re,xml.etree.ElementTree as ET

COMMANDS=['launch','app-home','open','status','seek','play','pause','export','audio-output','controls','fullscreen','pip','speed','ui','videos','select-video','progress','click-progress','drag-progress','tap-text','tap-desc','tap-id','tap','swipe','back','home']

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--serial',required=True)
    p.add_argument('--adb',default='D:/Android_studio_sdk/platform-tools/adb.exe')
    p.add_argument('--out',type=pathlib.Path)
    p.add_argument('--index',type=int)
    p.add_argument('command',choices=COMMANDS)
    p.add_argument('value',nargs='?')
    a=p.parse_args()
    def adb(*args,check=True):
        r=subprocess.run([a.adb,'-s',a.serial,*args],capture_output=True,timeout=25)
        if check and r.returncode:raise RuntimeError(r.stderr.decode('utf8','replace'))
        return r.stdout.decode('utf8','replace').strip()
    def bridge(command,value=None):
        if not adb('shell','pidof','com.personal.piliplus'):raise RuntimeError('target app is not running')
        request=uuid.uuid4().hex
        args=['shell','am','broadcast','-a','com.personal.piliplus.DIAGNOSTIC_CONTROL','-p','com.personal.piliplus','--es','requestId',request,'--es','command',command]
        if command=='seek':args+=['--el','positionMs',str(round(float(value)*1000))]
        elif value is not None:args+=['--es','value',value]
        adb(*args)
        remote=f'/sdcard/Android/data/com.personal.piliplus/files/playback-diagnostics/control-{request}.json'
        deadline=time.monotonic()+18
        while time.monotonic()<deadline:
            try:result=json.loads(adb('shell','cat',remote,check=False))
            except ValueError:time.sleep(.2);continue
            if result.get('status')=='accepted':time.sleep(.2);continue
            return result
        raise TimeoutError('No CLI reply from diagnostic bridge')
    def tree():
        state=adb('shell','dumpsys','activity','activities')
        if not re.search(r'topResumedActivity=.*com.personal.piliplus',state):
            raise RuntimeError('PiliPlus is not foreground; UI input refused')
        focus=adb('shell','dumpsys','window')
        if not re.search(r'mCurrentFocus=.*com.personal.piliplus',focus):
            raise RuntimeError('Another window covers PiliPlus; UI input refused')
        adb('shell','uiautomator','dump','/sdcard/pili-cli-ui.xml')
        raw=adb('shell','cat','/sdcard/pili-cli-ui.xml')
        nodes=[]
        for n in ET.fromstring(raw).iter('node'):
            b=list(map(int,re.findall(r'\d+',n.get('bounds',''))))
            if len(b)!=4:continue
            nodes.append({'text':n.get('text'),'description':n.get('content-desc'),'id':n.get('resource-id'),'class':n.get('class'),'bounds':b,'clickable':n.get('clickable')=='true','enabled':n.get('enabled')=='true'})
        return nodes
    def tap(b):return adb('shell','input','tap',str((b[0]+b[2])//2),str((b[1]+b[3])//2))
    def choose(nodes):
        nodes=[n for n in nodes if n['enabled'] and n['bounds'][2]>n['bounds'][0] and n['bounds'][3]>n['bounds'][1]]
        if not nodes:raise RuntimeError('No matching visible control')
        if a.index is not None:
            if not 0<=a.index<len(nodes):raise ValueError('index is outside the visible matches')
            return nodes[a.index]
        if len(nodes)!=1:raise RuntimeError('Several matches; select --index: '+json.dumps(nodes,ensure_ascii=False))
        return nodes[0]
    def emit(result):
        if a.out:
            a.out.parent.mkdir(parents=True,exist_ok=True)
            a.out.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf8')
        print(json.dumps(result,ensure_ascii=False))
    if adb('get-state')!='device':raise RuntimeError('target device not online')
    if a.command in ['launch','app-home']:
        args=['shell','am','start','-W','-n','com.personal.piliplus/.MainActivity']
        if a.command=='app-home':args+=['-a','android.intent.action.VIEW','-d','bilibili://root']
        emit({'command':a.command,'activity':adb(*args)});return
    if a.command=='open':
        match=re.search(r'BV[0-9A-Za-z]+',a.value or '')
        if not match:raise ValueError('open requires a BV id or video URL')
        adb('shell','am','start','-W','-a','android.intent.action.VIEW','-d',f'bilibili://video/{match[0]}','-n','com.personal.piliplus/.MainActivity')
        time.sleep(1)
        deadline=time.monotonic()+25
        while time.monotonic()<deadline:
            result=bridge('status')
            if result.get('status')=='complete' and (result.get('result',{}).get('decodedDisplaySize') or [None])[0]:
                emit(result);return
            if result.get('status')=='error' and result.get('result',{}).get('code')!='NO_PLAYER':
                emit(result);raise RuntimeError('open failed')
            time.sleep(.3)
        raise TimeoutError('video has not produced playback state')
    if a.command in ['ui','videos','progress']:
        nodes=tree()
        if a.command=='videos':nodes=[n for n in nodes if n['clickable'] and re.search(r'^\d+:\d+\n',n['description'] or '')]
        if a.command=='progress':nodes=[n for n in nodes if n['class']=='android.widget.SeekBar']
        emit({'command':a.command,'nodes':nodes});return
    if a.command in ['select-video','tap-text','tap-desc','tap-id']:
        field={'select-video':'description','tap-text':'text','tap-desc':'description','tap-id':'id'}[a.command]
        nodes=tree()
        if a.command=='select-video':
            nodes=[n for n in nodes if n['clickable'] and re.search(r'^\d+:\d+\n',n['description'] or '')]
        node=choose([n for n in nodes if (a.value and a.value in (n[field] or '')) or (a.command=='select-video' and a.value is None and a.index is not None)])
        b=node['bounds']
        tap(b);emit({'command':a.command,'selected':node,'input':{'type':'tap','x':(b[0]+b[2])//2,'y':(b[1]+b[3])//2}});return
    if a.command in ['click-progress','drag-progress']:
        pct=float(a.value)
        if not 0<=pct<=100:raise ValueError('percentage must be 0..100')
        tree()  # Refuse before changing control visibility if another UI covers us.
        shown=bridge('controls','show')
        if shown.get('status')!='complete':emit(shown);raise RuntimeError('could not show controls')
        try:
            time.sleep(.2)
            node=choose([n for n in tree() if n['class']=='android.widget.SeekBar' and n['bounds'][3]-n['bounds'][1]>12])
            b=node['bounds'];y=(b[1]+b[3])//2
            # Slider thumbs stop at the inset track ends, not the semantics box.
            # ProgressBar uses barHeight=3.5, thumbRadius=7: track cap is 1/8
            # of this semantics box height, independent of device density.
            inset=(b[3]-b[1])/8
            left,right=b[0]+inset,b[2]-inset
            target=round(left+(right-left)*pct/100)
            if a.command=='click-progress':
                injected={'type':'tap','x':target,'y':y}
                adb('shell','input','tap',str(target),str(y))
            else:
                # Flutter's ProgressBar semantics percentage can lag its painted
                # thumb. Use the current player position for the drag origin.
                current=bridge('status')
                state=current.get('result',{})
                duration=state.get('durationMs') or 0
                if current.get('status')!='complete' or duration<=0:
                    raise RuntimeError('current playback position unavailable')
                ratio=max(0,min(1,state['positionMs']/duration))
                start=round(left+(right-left)*ratio)
                injected={'type':'swipe','fromX':start,'fromY':y,'toX':target,'toY':y,'durationMs':350}
                adb('shell','input','swipe',str(start),str(y),str(target),str(y),'350')
        finally:bridge('controls','hide')
        time.sleep(1)
        emit({'command':a.command,'targetPercent':pct,'selected':node,'input':injected,'after':bridge('status')});return
    if a.command in ['tap','swipe']:
        coords=(a.value or '').split(',')
        if len(coords) not in ([2] if a.command=='tap' else [4,5]):raise ValueError('coordinates must be comma-separated')
        if not all(x.isdigit() for x in coords):raise ValueError('coordinates must be integers')
        tree()
        adb('shell','input',a.command,*coords);emit({'command':a.command,'coordinates':coords});return
    if a.command in ['back','home']:
        adb('shell','input','keyevent',a.command.upper());emit({'command':a.command});return
    result=bridge(a.command,a.value)
    emit(result)
    if result.get('status')!='complete':raise RuntimeError('command did not complete')
    if a.command=='export' and a.out:adb('pull',result['result']['path'],str(a.out.with_suffix('.zip')))

if __name__=='__main__':main()
