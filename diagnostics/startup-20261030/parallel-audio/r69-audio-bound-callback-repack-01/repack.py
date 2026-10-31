from pathlib import Path
import hashlib,json,re,subprocess,zipfile,shutil
out=Path(__file__).resolve().parent;base=out.parent
native_dir=base/'native-codec-callback-01'
old=base/'r69-audio-bound-candidate.apk';target=base/'r69-audio-bound-callback.apk'
unsigned=out/'unsigned.apk';aligned=out/'aligned.apk'
lib=native_dir/'libmpv-codec-callback-x86_64.so';entry='lib/x86_64/libmpv.so'
sha=lambda data:hashlib.sha256(data).hexdigest()
meta=json.loads(old.with_suffix('.build.json').read_text(encoding='utf-8'))
native=json.loads((native_dir/'native-build-01.json').read_text());assert native['buildPassed'] and native['unmounted']
assert native['baselineNativeSha256']==meta['nativeLibraryOverride']['librarySha256']
assert all(native['effectiveSourceHashes'][k]==v for k,v in meta['nativeLibraryOverride']['nativeSourceHashes'].items())
assert sha(old.read_bytes())==meta['sha256'] and sha(lib.read_bytes())==native['librarySha256']
for p in [target,unsigned,aligned]:assert not p.exists(),p
def signature(n):return n=='META-INF/MANIFEST.MF' or (n.startswith('META-INF/') and n.endswith(('.SF','.RSA','.DSA','.EC')))
with zipfile.ZipFile(old) as src,zipfile.ZipFile(unsigned,'x') as dst:
    assert src.namelist().count(entry)==1
    for info in src.infolist():
        if not signature(info.filename):dst.writestr(info,lib.read_bytes() if info.filename==entry else src.read(info))
sdk=Path('D:/Android_studio_sdk/build-tools/36.0.0');java=Path('D:/Program Files/Eclipse Adoptium/jdk-21.0.7.6-hotspot/bin/java.exe')
signer=[str(java),'-jar',str(sdk/'lib/apksigner.jar')]
def command(args,name):
    r=subprocess.run(args,capture_output=True,timeout=120)
    (out/name).write_bytes(r.stdout+r.stderr);r.check_returncode();return r.stdout.decode(errors='replace')
original=command(signer+['verify','--print-certs',str(old)],'original-signature.txt')
command([str(sdk/'zipalign.exe'),'-f','-P','16','4',str(unsigned),str(aligned)],'zipalign.txt')
command(signer+['sign','--ks','C:/Users/10540/.android/debug.keystore','--ks-key-alias','androiddebugkey',
    '--ks-pass','pass:android','--key-pass','pass:android','--out',str(target),str(aligned)],'sign.txt')
signed=command(signer+['verify','--verbose','--print-certs',str(target)],'repacked-signature.txt')
pattern=r'Signer #1 certificate SHA-256 digest: (\w+)'
assert re.search(pattern,original).group(1)==re.search(pattern,signed).group(1)
command([str(sdk/'zipalign.exe'),'-c','-P','16','4',str(target)],'zipalign-verified.txt')
with zipfile.ZipFile(old) as a,zipfile.ZipFile(target) as b:
    names={n for n in a.namelist() if not signature(n)};assert names=={n for n in b.namelist() if not signature(n)}
    differences=[n for n in names if sha(a.read(n))!=sha(b.read(n))];assert differences==[entry],differences
    assert sha(b.read(entry))==native['librarySha256']
source_archive=target.with_suffix('.sources.zip');old_sources=old.with_suffix('.sources.zip')
with zipfile.ZipFile(old_sources) as a,zipfile.ZipFile(source_archive,'x',compression=zipfile.ZIP_DEFLATED) as b:
    for info in a.infolist():b.writestr(info,a.read(info))
    for n in [p.name for p in native_dir.iterdir() if p.suffix in ['.before','.after','.h']] + ['source-provenance.json','native-build-01.json','codec-callbacks.patch','PiliCodecCallbacks.embedded.java','embedded-helper.json']:
        b.write(native_dir/n,'native-codec-callback/'+n)
        meta['diagnosticSourcesSha256']['native-codec-callback/'+n]=sha((native_dir/n).read_bytes())

meta.update(apk=str(target),sha256=sha(target.read_bytes()),repackedFromApk=str(old),repackedFromSha256=sha(old.read_bytes()),
    nativeGateDiagnostic=True,nativeSelectedPtsDiagnostic=True,nativeLibraryOverride={'abi':'x86_64','library':str(lib),'librarySha256':native['librarySha256'],
    'apkLibrarySha256':native['librarySha256'],'repacked':True,'nativeSourceHashes':native['effectiveSourceHashes']})
with target.with_suffix('.build.json').open('x',encoding='utf-8') as f:json.dump(meta,f,indent=2)
report={'apkSha256':meta['sha256'],'nativeSha256':native['librarySha256'],'sameSigningCertificate':True,
    'sameNonSignatureEntries':len(names),'payloadDifferences':differences,'alignmentVerified':True,
    'flutterAndDartUnchanged':True,'sourceArchiveSha256':sha(source_archive.read_bytes()),'newBehavior':'API26+ callback-backed buffers on same selected HEVC Surface decoder. Embedded reviewed Java DEX; same binary debug.piliplus.codec_callbacks switch, default off. Round69 decode-only1 and round90 audioBound1 kept on in both arms; no queue worker or changes to timestamps, confidence checks, audio priming.'}
with (out/'repack-verified.json').open('x') as f:json.dump(report,f,indent=2)
print(json.dumps(report),flush=True)
