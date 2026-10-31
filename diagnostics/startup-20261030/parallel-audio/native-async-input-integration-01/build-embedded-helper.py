from pathlib import Path
import hashlib,json,subprocess
out=Path(__file__).resolve().parent;root=out.parents[3]
classes=out/'embedded-classes';dex=out/'embedded-dex';classes.mkdir(exist_ok=False);dex.mkdir(exist_ok=False)
java=Path('D:/Program Files/Eclipse Adoptium/jdk-21.0.7.6-hotspot/bin');sdk=Path('D:/Android_studio_sdk');platform=sdk/'platforms/android-36/android.jar'
helper=root/'tool/native_codec_callbacks/PiliCodecCallbacks.java'
def run(args,label):
 r=subprocess.run(args,capture_output=True,timeout=60)
 (out/(label+'.stdout.txt')).write_bytes(r.stdout);(out/(label+'.stderr.txt')).write_bytes(r.stderr);r.check_returncode()
run([str(java/'javac.exe'),'-source','8','-target','8','-classpath',str(platform),'-d',str(classes),str(helper)],'embedded-javac')
run([str(java/'java.exe'),'-cp',str(sdk/'build-tools/36.0.0/lib/d8.jar'),'com.android.tools.r8.D8','--lib',str(platform),'--min-api','26','--output',str(dex)]+[str(p) for p in classes.rglob('*.class')],'embedded-d8')
data=(dex/'classes.dex').read_bytes();assert data.startswith(b'dex\n')
header='/* Generated from the reviewed local Java helper; no runtime downloads. */\nstatic const unsigned char pili_codec_callbacks_dex[] = {\n'
header+=''.join('    '+','.join(f'0x{x:02x}' for x in data[i:i+16])+',\n' for i in range(0,len(data),16))+'};\n'
(out/'pili_codec_callbacks_dex.h').write_bytes(header.encode())
(out/'PiliCodecCallbacks.embedded.java').write_bytes(helper.read_bytes())
report={'javaSha256':hashlib.sha256(helper.read_bytes()).hexdigest(),'dexSha256':hashlib.sha256(data).hexdigest(),'dexBytes':len(data),'headerSha256':hashlib.sha256(header.encode()).hexdigest(),'minApi':26}
(out/'embedded-helper.json').write_text(json.dumps(report,indent=2));print(json.dumps(report))
