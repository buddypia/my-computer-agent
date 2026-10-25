"""Tests the acceptance oracle and protocol, not desktop capability.

Live capability evidence is produced only by run.py --live.
"""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("live_acceptance", Path(__file__).with_name("run.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class OracleTests(unittest.TestCase):
    def setUp(self):
        self.state = {"order": "ORDER-A1B2C3", "saved_text": "ORDER-A1B2C3", "saves": 1,
                      "attempts": 1, "confirmed": True, "confirmation_clicks": 1,
                      "edits": 1, "receipt": "R-012345ABCDEF"}
        self.trace = [{"action": "screenshot", "image": "before.jpg", "saves_after": 0},
                      {"action": "left_click", "saves_after": 1},
                      {"action": "screenshot", "image": "after.jpg", "saves_after": 1}]

    def grade(self, state=None, answer="R-012345ABCDEF", trace=None):
        return runner.grade(self.state if state is None else state, answer,
                            self.trace if trace is None else trace, "agent")

    def test_complete_task_is_accepted(self):
        self.assertTrue(self.grade()["passed"])

    def test_each_independent_postcondition_is_required(self):
        for name, value in [("saved_text", "wrong"), ("saves", 0), ("saves", 2),
                            ("attempts", 2), ("confirmed", False), ("confirmation_clicks", 0),
                            ("edits", 0), ("receipt", "")]:
            with self.subTest(name=name, value=value):
                self.assertFalse(self.grade(state=self.state | {name: value})["passed"])

    def test_success_prose_and_guessed_receipt_are_not_evidence(self):
        for answer in ["Done", "Completed successfully", "R-FFFFFFFFFFFF", ""]:
            with self.subTest(answer=answer):
                self.assertFalse(self.grade(answer=answer)["passed"])

    def test_pre_save_picture_and_pictureless_tool_calls_are_not_reobservation(self):
        for trace in [self.trace[:2], self.trace[:2] + [{"action": "screenshot", "saves_after": 1}]]:
            self.assertFalse(self.grade(trace=trace)["checks"]["post_save_screenshot"])

    def test_no_input_negative_control_fails(self):
        empty = {"order": "ORDER-A1B2C3", "saved_text": "", "saves": 0,
                 "attempts": 0, "confirmed": False, "edits": 0, "receipt": ""}
        self.assertFalse(runner.grade(empty, "Done", self.trace[:1], "no-input")["passed"])
        self.assertFalse(runner.grade({}, "", [], "agent")["passed"])

    def test_smoke_is_not_a_model_reading_score(self):
        self.assertTrue(runner.grade(self.state, "", self.trace, "smoke")["passed"])
        self.assertFalse(self.grade(answer="")["passed"])


class BoundaryTests(unittest.TestCase):
    def test_dimensions_come_from_image_bytes_and_bad_images_fail_closed(self):
        jpeg = bytes.fromhex("FFD8FFE000044142FFC0001108035E053503011100021101031101FFD9")
        self.assertEqual(runner.jpeg_dimensions(jpeg), (1333, 862))
        for invalid in [b"", b"1333x862 px", b"\xff\xd8", jpeg[:12]]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                runner.jpeg_dimensions(invalid)

    def test_global_shortcuts_and_unbounded_input_are_refused(self):
        bad = [{"action": "key", "text": "cmd+q"}, {"action": "type", "text": "hello\n"},
               {"action": "left_click", "coordinate": [0, 0]},
               {"action": "left_click", "coordinate": [40, float("nan")]},
               {"action": "left_click", "coordinate": [True, 50]},
               {"action": "left_click", "coordinate": [50, 50], "text": "cmd"},
               {"action": "wait", "duration": 300}]
        for action in bad:
            with self.subTest(action=action), self.assertRaises(ValueError):
                runner.validate_action(action, 1000, 700)

    def test_without_live_flag_run_is_blocked_nonzero_with_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "evidence"
            result = subprocess.run([sys.executable, str(Path(runner.__file__)), "--mode", "smoke",
                                     "--output", str(output)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            report = json.loads((output / "report.json").read_text())
            self.assertEqual(report["status"], "blocked")
            self.assertEqual(report["trials"], [])

    def test_mcp_reads_fragmented_frames_and_ignores_notifications(self):
        program = """
import sys, json
for line in sys.stdin:
    request = json.loads(line)
    print(json.dumps({'jsonrpc':'2.0','method':'notifications/test'}), flush=True)
    response = json.dumps({'id':request['id'],'result':{'actual_stdio':True}}) + '\\n'
    sys.stdout.write(response[:9]); sys.stdout.flush()
    sys.stdout.write(response[9:]); sys.stdout.flush()
"""
        with tempfile.TemporaryDirectory() as temporary:
            client = runner.MCP([sys.executable, "-c", program], Path(temporary) / "stderr")
            try:
                self.assertEqual(client.request("tools/list", {}, time.monotonic() + 5), {"actual_stdio": True})
            finally:
                client.close()
            self.assertIsNotNone(client.process.poll())

    def test_provider_error_body_is_not_copied_into_evidence(self):
        from urllib.error import HTTPError
        with patch.object(runner.urllib.request, "urlopen", side_effect=HTTPError(
                "https://example.invalid", 403, "secret body must not appear", {}, None)):
            with self.assertRaisesRegex(runner.Blocked, "^Gemini API returned HTTP 403$"):
                runner.gemini_turn("test", "dummy", [], {}, time.monotonic() + 5)

    def test_expired_mcp_deadline_dispatches_no_request(self):
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "dispatched"
            program = "import sys,pathlib; data=sys.stdin.read(); pathlib.Path(sys.argv[1]).write_text(data)"
            client = runner.MCP([sys.executable, "-c", program, str(marker)], Path(temporary) / "stderr")
            try:
                with self.assertRaises(TimeoutError):
                    client.request("tools/call", {"name": "computer"}, time.monotonic() - 1)
            finally:
                client.close()
            self.assertEqual(marker.read_text(), "")


if __name__ == "__main__":
    unittest.main()
