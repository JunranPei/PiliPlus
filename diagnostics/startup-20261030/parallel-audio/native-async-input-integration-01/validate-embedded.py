from pathlib import Path
import hashlib,json,subprocess,zipfile
out=Path(__file__).resolve().parent; sdk=Path('D:/Android_studio_sdk');java=Path('D:/Program Files/Eclipse Adoptium/jdk-21.0.7.6-hotspot/bin')
platform=sdk/'platforms/android-36/android.jar'
source=(out.parent/'native-callback-wait-01/CallbackLifecycleProbe.java').read_text().replace('import com.personal.piliplus.PiliCodecCallbacks;','').replace('CallbackLifecycleProbe','EmbeddedLifecycleProbe').replace('PiliCodecCallbacks','Bridge')
bridge='''
    static Class<?> helper;
    static boolean asyncInput;
    static final class Bridge {
        final Object object;
        Bridge(MediaCodec codec) {
            try { object=helper.getConstructor(MediaCodec.class,boolean.class).newInstance(codec,asyncInput); }
            catch(Exception e) { throw new IllegalStateException(e); }
        }
        Object call(String name,Class<?>[] types,Object...args) {
            try {return helper.getMethod(name,types).invoke(object,args);}
            catch(java.lang.reflect.InvocationTargetException e) {
                Throwable t=e.getCause();if(t instanceof RuntimeException)throw (RuntimeException)t;throw new IllegalStateException(t);
            } catch(Exception e) {throw new IllegalStateException(e);}
        }
        int dequeueInputBuffer(long us){return (Integer)call("dequeueInputBuffer",new Class[]{long.class},us);}
        int dequeueOutputBuffer(MediaCodec.BufferInfo info,long us){return (Integer)call("dequeueOutputBuffer",new Class[]{MediaCodec.BufferInfo.class,long.class},info,us);}
        MediaFormat getOutputFormat(){return (MediaFormat)call("getOutputFormat",new Class[]{});}
        void queueInputBuffer(int i,int o,int s,long p,int f){call("queueInputBuffer",new Class[]{int.class,int.class,int.class,long.class,int.class},i,o,s,p,f);}
        void flush(){call("flush",new Class[]{});}
        void awaitActivity(long us){call("awaitActivity",new Class[]{long.class},us);}
        void close(){call("close",new Class[]{});}
        long[] snapshot(){return (long[])call("snapshot",new Class[]{});}
    }
'''
source=source.replace('public final class EmbeddedLifecycleProbe {','public final class EmbeddedLifecycleProbe {'+bridge)
source=source.replace('JSONObject report=new JSONObject();','''JSONObject report=new JSONObject();
        asyncInput=Boolean.parseBoolean(args[2]);
        report.put("asyncInput",asyncInput);
        ByteBuffer dex=ByteBuffer.wrap(java.nio.file.Files.readAllBytes(java.nio.file.Paths.get(args[1])));
        ClassLoader loader=new dalvik.system.InMemoryDexClassLoader(dex,ClassLoader.getSystemClassLoader());
        helper=loader.loadClass("com.personal.piliplus.PiliCodecCallbacks");
        if(helper.getClassLoader()!=loader)throw new AssertionError("Helper came from parent classpath");
        report.put("loadedFromEmbeddedDex",true);''')
source=source.replace('state[6]!=0)', 'state[6]!=0||state.length!=15||state[7]!=(asyncInput?1:0)||state[11]!=0||state[12]!=0||state[13]!=0)')
source=source.replace('waiting.dequeueInputBuffer(-1)','waiting.awaitActivity(-1)')
(out/'EmbeddedLifecycleProbe.java').write_text(source)
classes=out/'loader-classes';dex=out/'loader-dex';classes.mkdir();dex.mkdir()
def run(args,name,timeout=60):
 r=subprocess.run(args,capture_output=True,timeout=timeout)
 (out/(name+'.stdout.txt')).write_bytes(r.stdout);(out/(name+'.stderr.txt')).write_bytes(r.stderr);r.check_returncode();return r.stdout
run([str(java/'javac.exe'),'-source','8','-target','8','-classpath',str(platform),'-d',str(classes),str(out/'EmbeddedLifecycleProbe.java'),str(out.parent/'codec-queue-probe-02/CodecQueueProbe.java')],'loader-javac')
assert not any(classes.rglob('*PiliCodecCallbacks*'))
run([str(java/'java.exe'),'-cp',str(sdk/'build-tools/36.0.0/lib/d8.jar'),'com.android.tools.r8.D8','--lib',str(platform),'--min-api','26','--output',str(dex)]+[str(p)for p in classes.rglob('*.class')],'loader-d8')
jar=out/'embedded-lifecycle.jar'
with zipfile.ZipFile(jar,'x')as z:z.write(dex/'classes.dex','classes.dex')
adb=[str(sdk/'platform-tools/adb.exe'),'-s','emulator-5554'];remote='/data/local/tmp/pili-async-input87'
run(adb+['push',str(jar),remote+'.jar'],'loader-push-probe')
run(adb+['push',str(out/'embedded-dex/classes.dex'),remote+'.dex'],'loader-push-dex')
reports=[]
for mode in ['false','true']:
 raw=run(adb+['shell','env','CLASSPATH='+remote+'.jar','app_process','/','EmbeddedLifecycleProbe','/data/local/tmp/pili-codec-queue70-v2/fixture.mp4',remote+'.dex',mode],'loader-lifecycle-'+mode,120)
 r=json.loads(next(l for l in raw.decode().splitlines()if l.startswith('{')))
 reports.append(r);(out/('embedded-device-'+mode+'.json')).write_text(json.dumps(r,indent=2));print(json.dumps(r),flush=True);assert r['passed']
report={'passed':all(r['passed']for r in reports),'modes':reports,'helper':json.loads((out/'embedded-helper.json').read_text()),'scope':'Actual embedded loader both modes with full PTS EOS/seek/partial flush/repeated close/blocked-owner wake. Pending submissions and both worker exits checked. Application timing pending.'}
(out/'embedded-device-reviewed.json').write_text(json.dumps(report,indent=2))
