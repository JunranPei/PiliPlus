"""Pure metadata tests: python -m unittest discover -s tool -p ordinary_playback_tools_test.py"""

import json
from pathlib import Path
import tempfile
import unittest

from ordinary_playback_analyze import align_record, analyze_app, clock_anchors, scope_layers
from ordinary_playback_capture import perfetto_config, selected_logs


class PlaybackCaptureTests(unittest.TestCase):
    def test_config_is_bounded_and_contains_no_pixels(self):
        config = perfetto_config(25, "test")
        self.assertIn("duration_ms: 25000", config)
        self.assertIn("max_file_size_bytes: 134217728", config)
        self.assertIn("android.surfaceflinger.layers", config)
        self.assertIn("android.surfaceflinger.frametimeline", config)
        self.assertNotIn("screenshot", config)

    def test_unbounded_config_is_rejected(self):
        for seconds in (0, -5, 181):
            with self.assertRaises(ValueError):
                perfetto_config(seconds, "test")

    def test_log_selection_handles_micros_and_millis_and_process_restart(self):
        names = ["flutter-1791530000000000.jsonl", "flutter-1791530020000000.jsonl",
                 "flutter-1791530010000000.jsonl", "native-1791530000000.jsonl",
                 "native-1791530020000.jsonl", "../../secret", "other.log"]
        self.assertEqual(selected_logs(names, 1791530005000), [
            "flutter-1791530010000000.jsonl", "flutter-1791530020000000.jsonl",
            "native-1791530020000.jsonl"])

    def test_started_before_capture_latest_file_still_collected(self):
        self.assertEqual(selected_logs(["native-1791530000000.jsonl"], 1791530050000),
                         ["native-1791530000000.jsonl"])

    def test_actual_flutter_and_native_pid_timestamp_names(self):
        names = ["flutter-400-1791530000000000.jsonl", "native-400-1791530000000.jsonl",
                 "flutter-25-1791530020000000.jsonl", "native-25-1791530020000.jsonl"]
        self.assertEqual(selected_logs(names), ["flutter-25-1791530020000000.jsonl",
                                               "native-25-1791530020000.jsonl"])
        self.assertEqual(selected_logs(names, 1791529999000), sorted(names))


class PlaybackClockTests(unittest.TestCase):
    def test_round_trip_uncertainty_and_monotonic_mapping(self):
        anchors = clock_anchors([(1, {"event": "clock.sync", "seq": 10,
            "dartSendUs": 100, "dartReceiveUs": 120, "native": {"bootNs": 1000000}})])
        self.assertEqual(anchors[0]["uncertaintyNs"], 10000)
        mapped = align_record({"elapsedUs": 150}, anchors)
        self.assertEqual(mapped["bootNs"], 1040000)
        self.assertEqual(mapped["anchorSeq"], 10)

    def test_no_wall_clock_guess_without_anchor(self):
        self.assertIsNone(align_record({"elapsedUs": 50, "utcUs": 123456}, [])["bootNs"])

    def test_native_clock_not_replaced_by_dart_anchor(self):
        self.assertEqual(align_record({"bootNs": 123456}, [])["bootNs"], 123456)

    def test_invalid_clock_sample_does_not_calibrate(self):
        self.assertEqual(clock_anchors([(1, {"event": "clock.sync", "dartSendUs": 120,
            "dartReceiveUs": 100, "native": {"bootNs": 1000000}})]), [])

    def test_minimum_round_trip_anchor_wins_over_closer_slow_configure(self):
        anchors = [{"seq": 1, "elapsedUs": 0, "offsetNs": 100,
                    "uncertaintyNs": 5}, {"seq": 2, "elapsedUs": 100,
                    "offsetNs": 200, "uncertaintyNs": 7}]
        self.assertEqual(align_record({"elapsedUs": 90}, anchors)["anchorSeq"], 1)

    def test_nearest_anchor_breaks_equal_round_trip_ties(self):
        anchors = [{"seq": 1, "elapsedUs": 0, "offsetNs": 100,
                    "uncertaintyNs": 5}, {"seq": 2, "elapsedUs": 100,
                    "offsetNs": 200, "uncertaintyNs": 5}]
        self.assertEqual(align_record({"elapsedUs": 90}, anchors)["anchorSeq"], 2)


class PlaybackAnalysisTests(unittest.TestCase):
    def test_layer_scope_keeps_unnamed_children_and_ancestors_not_siblings(self):
        layers = {1: {"name": "root", "parent": None},
                  2: {"name": "com.personal.piliplus.dev/Main", "parent": 1},
                  3: {"name": "anonymous buffer", "parent": 2},
                  4: {"name": "other app", "parent": 1}}
        scoped = scope_layers(layers, "com.personal.piliplus.dev")
        self.assertEqual(set(scoped), {1, 2, 3})
        self.assertEqual(scoped[1]["role"], "ancestor")
        self.assertEqual(scoped[3]["role"], "app-descendant")

    def test_layer_scope_parent_cycle_does_not_hang(self):
        layers = {1: {"name": "app", "parent": 2}, 2: {"name": "parent", "parent": 1}}
        self.assertEqual(set(scope_layers(layers, "app")), {1, 2})

    def test_lost_rows_and_invalid_tail_preserved_in_summary(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            app = directory / "app"
            app.mkdir()
            records = [
                {"event": "clock.sync", "seq": 1, "elapsedUs": 10, "dartSendUs": 0,
                 "dartReceiveUs": 20, "native": {"bootNs": 1000000}},
                {"event": "geometry", "seq": 2, "elapsedUs": 25, "probe": 1,
                 "name": "video-content", "size": [100, 50], "owner": "A", "cid": 7},
                {"event": "geometry", "seq": 4, "elapsedUs": 30, "probe": 1,
                 "name": "video-content", "size": [0, 0], "owner": "A", "cid": 7},
                {"event": "media.textureRect", "seq": 5, "elapsedUs": 31, "rect": [0, 0, 0, 0]},
            ]
            (app / "flutter-1.jsonl").write_text("\n".join(map(json.dumps, records)) + '\n{"seq":',
                                                       encoding="utf-8")
            summary, events = analyze_app(app, directory)
            self.assertEqual(summary["records"], 4)
            self.assertEqual(summary["sequenceGaps"], [{"file": "flutter-1.jsonl", "after": 2, "before": 4}])
            self.assertEqual(len(summary["invalidRecords"]), 1)
            self.assertEqual(summary["changes"], 2)
            self.assertEqual(events[2]["bootNs"], 1020000)
            delta = json.loads((directory / "app-changes.jsonl").read_text().splitlines()[0])
            self.assertEqual(delta["changes"]["size"]["after"], [0, 0])

    def test_clock_anchor_never_crosses_process_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            app = directory / "app"
            app.mkdir()
            (app / "flutter-1.jsonl").write_text(json.dumps({"event": "clock.sync", "seq": 1,
                "dartSendUs": 0, "dartReceiveUs": 20, "native": {"bootNs": 1000000}}))
            (app / "flutter-2.jsonl").write_text(json.dumps({"event": "geometry", "seq": 1,
                "elapsedUs": 10, "utcUs": 9999999}))
            _, events = analyze_app(app, directory)
            second = next(event for event in events if event["file"] == "flutter-2.jsonl")
            self.assertIsNone(second["bootNs"])

    def test_native_wrapped_data_and_drop_counters(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            app = directory / "app"
            app.mkdir()
            records = [
                {"event": "window.geometry", "seq": 1, "bootNs": 1000, "data": {
                    "views": [{"id": 10, "width": 100, "height": 50, "alpha": 1.0}]}},
                {"event": "window.geometry", "seq": 2, "bootNs": 2000, "droppedBefore": 3,
                 "data": {"views": [{"id": 10, "width": 100, "height": 50, "alpha": 0.0}]}},
            ]
            (app / "native-400-1791530000000.jsonl").write_text("\n".join(map(json.dumps, records)))
            summary, _ = analyze_app(app, directory)
            self.assertEqual(summary["changes"], 1)
            self.assertEqual(len(summary["explicitLossOrCollectionErrors"]), 1)
            change = json.loads((directory / "app-changes.jsonl").read_text().strip())
            self.assertEqual(change["changes"]["alpha"], {"before": 1.0, "after": 0.0})

    def test_stop_and_end_loss_counts_use_actual_schema(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            app = directory / "app"
            app.mkdir()
            native = {"event": "trace.stopped", "seq": 1, "bootNs": 1000, "data": {"dropped": 7}}
            flutter = {"event": "trace.end", "seq": 1, "elapsedUs": 1000, "droppedRecords": 2}
            (app / "native-400-1791530000000.jsonl").write_text(json.dumps(native))
            (app / "flutter-400-1791530000000000.jsonl").write_text(json.dumps(flutter))
            summary, _ = analyze_app(app, directory)
            self.assertEqual(len(summary["explicitLossOrCollectionErrors"]), 2)


if __name__ == "__main__":
    unittest.main()
