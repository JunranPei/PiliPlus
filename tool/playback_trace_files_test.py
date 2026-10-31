import unittest

from playback_trace_files import announced_trace_pair, validate_trace_pair


class TraceGenerationTests(unittest.TestCase):
    def test_reused_pid_selects_announced_generation_not_older_files(self):
        old = ['native-4635-1793299039411.jsonl', 'flutter-4635-1793299039438147.jsonl']
        current = ['native-4635-1793305052829.jsonl', 'flutter-4635-1793305052878278.jsonl']
        log = ('I PiliPlaybackTrace: configured file=/diagnostics/' + current[0] + '\n'
               'I flutter : [PLAYBACK_TRACE_FILE] /diagnostics/' + current[1] + '\n')
        self.assertEqual(announced_trace_pair(log, old + current, 4635), sorted(current))
        with self.assertRaises(ValueError):
            validate_trace_pair(old + current)

    def test_mixed_generation_is_rejected_even_with_same_pid(self):
        with self.assertRaises(ValueError):
            validate_trace_pair(['native-4635-1793299039411.jsonl',
                                 'flutter-4635-1793305052878278.jsonl'])

    def test_missing_current_file_is_not_replaced_by_old_one(self):
        log = ('configured file=/native-4635-1793305052829.jsonl\n'
               '[PLAYBACK_TRACE_FILE] /flutter-4635-1793305052878278.jsonl\n')
        with self.assertRaises(ValueError):
            announced_trace_pair(log, ['native-4635-1793305052829.jsonl'], 4635)

    def test_another_pid_cannot_supply_an_announcement(self):
        with self.assertRaises(ValueError):
            announced_trace_pair('configured file=/native-4250-1793305005336.jsonl', [], 4635)

    def test_exact_announcements_can_be_pulled_without_directory_enumeration(self):
        names = ['native-4635-1793305052829.jsonl', 'flutter-4635-1793305052878278.jsonl']
        log = 'configured file=/' + names[0] + '\n[PLAYBACK_TRACE_FILE] /' + names[1] + '\n'
        self.assertEqual(announced_trace_pair(log, None, 4635), sorted(names))
        with self.assertRaises(ValueError):
            announced_trace_pair(log, None, 9999)


if __name__ == '__main__':
    unittest.main()
