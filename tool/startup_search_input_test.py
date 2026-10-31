import json,tempfile,unittest
from pathlib import Path
from xml.sax.saxutils import escape
from capture_startup_listener import fill_verified_search_uri

class SearchInputTests(unittest.TestCase):
    uri='bilibili://video/BV15BJX6dEoR?cid=42790290231&start_progress=61500'
    def xml(self,text):
        return ('<hierarchy><node package="com.personal.piliplus" class="android.widget.EditText" enabled="true" focused="true" text="'+escape(text,{'"':'&quot;'})+'" bounds="[147,74][802,200]"/><node package="com.personal.piliplus" content-desc="清空" clickable="true" enabled="true" bounds="[802,74][928,200]"/></hierarchy>').encode()
    def run_case(self,texts,fail=False):
        calls=[];responses=iter(texts)
        def adb(*args):
            calls.append(args)
            return self.xml(next(responses)) if args[:2]==('shell','cat') else b''
        with tempfile.TemporaryDirectory()as folder:
            if fail:
                with self.assertRaisesRegex(RuntimeError,'still differs'):fill_verified_search_uri(adb,Path(folder),self.uri,sleep=lambda _:None)
            else:
                xml=fill_verified_search_uri(adb,Path(folder),self.uri,sleep=lambda _:None)
                self.assertEqual(xml,self.xml(self.uri))
            self.assertFalse(any(c[:4]==('shell','input','touchscreen','tap') and c[-2:]!=('865','137') for c in calls))
            return calls,json.loads((Path(folder)/'search-input-preparation.json').read_text())
    def test_complete_fast_input_has_no_refill(self):
        calls,_=self.run_case(['',self.uri]);self.assertFalse(any('for ch in' in c[-1]for c in calls))
    def test_actual_missing_character_repaired_without_submission(self):
        calls,records=self.run_case(['',self.uri.replace('bilibili','bilbili'),self.uri])
        self.assertEqual(sum('for ch in' in c[-1]for c in calls),1)
        self.assertEqual(records[1]['text'],self.uri.replace('bilibili','bilbili'))
    def test_failed_repair_never_becomes_measured_input(self):
        self.run_case(['','wrong','still wrong'],fail=True)

if __name__=='__main__':unittest.main()
