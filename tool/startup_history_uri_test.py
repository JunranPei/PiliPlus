import unittest
from capture_startup_listener import search_video_uri


class HistoryUriTest(unittest.TestCase):
    def test_zero_start_remains_explicit(self):
        self.assertEqual(search_video_uri({'bvid':'BVtest','cid':42}),
                         'bilibili://video/BVtest?cid=42&start_progress=0')

    def test_fixed_resume_keeps_original_milliseconds(self):
        self.assertEqual(search_video_uri({'bvid':'BVtest','cid':42},60033),
                         'bilibili://video/BVtest?cid=42&start_progress=60033')

    def test_history_does_not_silently_force_zero(self):
        self.assertEqual(search_video_uri({'bvid':'BVtest','cid':42},history_resume=True),
                         'bilibili://video/BVtest?cid=42')


if __name__=='__main__':
    unittest.main()
