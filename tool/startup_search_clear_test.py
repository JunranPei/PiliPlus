import unittest
from pathlib import Path
from capture_startup_listener import search_clear_target

class SearchClearTests(unittest.TestCase):
    editor='<node package="com.personal.piliplus" class="android.widget.EditText" enabled="true" bounds="[147,74][802,200]"/>'
    def test_real_failed_capture_has_an_unambiguous_clear_control(self):
        # Reduced semantic controls from history-03/01-history/input.xml.
        xml='<hierarchy><node package="com.personal.piliplus" content-desc="清空" clickable="true" enabled="true" bounds="[802,74][928,200]"/><node package="com.personal.piliplus" content-desc="搜索" clickable="true" enabled="true" bounds="[928,74][1054,200]"/></hierarchy>'
        self.assertEqual(search_clear_target(xml.replace('<hierarchy>','<hierarchy>'+self.editor)),[865,137])

    def test_history_clear_is_excluded_by_the_actual_search_field_row(self):
        xml=(Path(__file__).resolve().parents[1]/'diagnostics/startup-20261030/parallel-audio/resume-hedge-01/nonboundary/search-before-clear.xml').read_bytes()
        self.assertEqual(search_clear_target(xml),[865,137])

    def test_missing_and_ambiguous_targets_are_rejected(self):
        node='<node package="com.personal.piliplus" content-desc="清空" clickable="true" enabled="true" bounds="[802,74][928,200]"/>'
        for body in ['',node+node,node.replace('enabled="true"','enabled="false"'),
                     node.replace('[802,74][928,200]','[802,74][802,74]')]:
            with self.subTest(body=body),self.assertRaises(ValueError):
                search_clear_target('<hierarchy>'+self.editor+body+'</hierarchy>')

if __name__=='__main__':unittest.main()
