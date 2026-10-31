"""Reject old source/input/texture evidence when the same process opens a CID again."""
import json
from pathlib import Path
import tempfile
import unittest

from capture_startup_listener import summarize


class CaptureWindowTests(unittest.TestCase):
    def test_repeated_cid_uses_the_new_native_sequence_window(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            names = ['native-1-1000.jsonl', 'flutter-1-1000000.jsonl']
            rows = []
            for request, origin, latency in [(1, 1_000_000_000, 50_000_000), (2, 2_000_000_000, 120_000_000)]:
                identity = dict(cid=42, requestId=request, sourceRevision=request, textureId=0, playerId=1)
                for event, timestamp, data in [
                    ('input.touch', origin, dict(action=0, x=800, y=1047, eventUptimeMs=origin//1_000_000)),
                    ('source.open.begin', origin+10_000_000, identity),
                    ('texture.consumed', origin+latency, dict(requestContext=identity, textureId=0,
                        textureTimestampNs=33_000_000, callbackMonoNs=origin+latency,
                        sameTimestampAsPrevious=False, surfaceValid=True)),
                ]:
                    rows.append(dict(stream='android', seq=len(rows)+1, event=event, monoNs=timestamp, data=data))
            (path/names[0]).write_text(''.join(json.dumps(row)+'\n' for row in rows), encoding='utf-8')
            (path/names[1]).write_text('', encoding='utf-8')
            result = summarize(path, 42, names, after_native_sequence=3)
            self.assertTrue(result['validInput'])
            self.assertEqual(result['sourceIdentity']['requestId'], 2)
            self.assertEqual(result['firstChangedTextureConsumedAfterInputMs'], 120)
            self.assertEqual(result['inputDispatchMonoNs'], 2_000_000_000)
            self.assertEqual(result['firstChangedTextureTimestampNs'], 33_000_000)
            missing = summarize(path, 42, names, after_native_sequence=6)
            self.assertFalse(missing['validSource'])


if __name__ == '__main__':
    unittest.main()
