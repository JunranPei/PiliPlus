from pathlib import Path
import json
BASE=Path(__file__).resolve().parent
old=BASE/'r69-audio-bound-cancel-01/reviewed.json'
report=json.loads(old.read_text())
assert report['returnCleanupPassed'] and not report['cancelBeforeDrainVerified']
note={'sample':old.parent.name,'actualOutcome':'Return and cleanup passed after first frame; does not prove pre-frame cancellation.',
    'trigger':'queue.first at1509.8985ms; Android input command took458.7987ms, so target frame won before route departure.',
    'correction':'Use existing receive.first listener, earlier than decode-only reference flag. Keep original sample intact; use fresh output02.',
    'appChange':False}
(old.parent/'phase-not-preframe-reviewed.json').write_text(json.dumps(note,indent=2))
s=(BASE/'run-r69-audio-bound-cancel.py').read_text()
s=s.replace('r69-audio-bound-cancel-01','r69-audio-bound-cancel-02')
s=s.replace("if '[DECODE_ONLY] ' not in line or", "if '[CODEC_FLUSH] ' not in line or")
s=s.replace("try:e=json.loads(line.split('[DECODE_ONLY] ',1)[1])", "try:e=json.loads(line.split('[CODEC_FLUSH] ',1)[1])")
s=s.replace("if e['event']!='queue.first' or e['flags']!=32 or e['enabled']!=1:continue", "if e['event']!='receive.first':continue")
s=s.replace('Return requested after actual first decode-only reference frame','Return requested after current decoder receive.first')
s=s.replace("e['event']=='close' and e['applied']>0", "e['event']=='close' and e['enabled']==1")
s=s.replace("assert report['decodeOnlyWasApplied'] and report['decoderClosed']", "assert report['decoderClosed']")
s=s.replace('Actual native decode-only queue.first triggered external return request','Actual native receive.first triggered external return request')
name='run-r69-audio-bound-early-cancel.py';compile(s,name,'exec');(BASE/name).write_text(s)
s=(BASE/'review-r69-audio-bound-cancel.py').read_text().replace('r69-audio-bound-cancel-01','r69-audio-bound-cancel-02').replace('../startup-audio-decode-bound-cancel-01/audio-queue-cancel-events.json','../r69-audio-bound-cancel-01/phase-not-preframe-reviewed.json')
name='review-r69-audio-bound-early-cancel.py';compile(s,name,'exec');(BASE/name).write_text(s)
print('Retained post-frame return sample; prepared earlier receive listener in new capture directory.')
