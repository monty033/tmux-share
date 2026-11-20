#!/usr/bin/env python3
"""Tests for hermes-plugin/tools.py: the tmux_share status, tail and read tools.

Run with:  python3 tests/plugin/test_tools.py

Every fixture lives in a temporary directory that is removed afterwards. The
modules are loaded by path, so nothing needs installing. Standard library only;
no pytest.
"""

import contextlib
import importlib.util
import json
import os
import re
import shutil
import socket
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
PLUGIN_DIR = os.path.join(REPO_ROOT, "hermes-plugin")

# Start from a clean environment: a leaked TMUX_SHARE_* from an earlier shell must not point the tools elsewhere.
for _name in [n for n in os.environ if n.startswith("TMUX_SHARE_")]:
    del os.environ[_name]


def _load_tools():
    spec = importlib.util.spec_from_file_location(
        "tmux_share_tools_under_test", os.path.join(PLUGIN_DIR, "tools.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _load_plugin_package():
    """Load hermes-plugin/__init__.py as a package, the way the Hermes loader does, so its relative import works."""
    spec = importlib.util.spec_from_file_location(
        "tmux_share_plugin", os.path.join(PLUGIN_DIR, "__init__.py"),
        submodule_search_locations=[PLUGIN_DIR])
    module = importlib.util.module_from_spec(spec)
    sys.modules["tmux_share_plugin"] = module
    spec.loader.exec_module(module)
    return module


tools = _load_tools()
IS_ROOT = os.geteuid() == 0


def call(handler, args=None):
    """Run a handler the way Hermes does and decode its JSON reply."""
    return json.loads(handler(args or {}))


def numbered_lines(count):
    return "".join("line {:05d}\n".format(i) for i in range(count)).encode("ascii")


class CountingHandle:
    """Wraps a transcript handle and counts the bytes read through it."""

    def __init__(self, handle):
        self._handle = handle
        self.bytes_read = 0

    def read(self, size=-1):
        data = self._handle.read(size)
        self.bytes_read += len(data)
        return data

    def __getattr__(self, name):
        return getattr(self._handle, name)

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        self._handle.close()
        return False


@contextlib.contextmanager
def counting_reads(record):
    """Record a CountingHandle for each transcript the tools open, so a test can see exactly how much was read."""
    real_open = tools._open_transcript

    def opened(path):
        handle, failure = real_open(path)
        if handle is None:
            return None, failure
        wrapper = CountingHandle(handle)
        record.append(wrapper)
        return wrapper, None

    with mock.patch.object(tools, "_open_transcript", side_effect=opened):
        yield


class TmpCase(unittest.TestCase):
    """Each test gets its own temporary directory and TMUX_SHARE_LOG / TMUX_SHARE_SOCK pointing inside it."""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="tmux-share-test-")
        self.log = os.path.join(self.dir, "transcript.log")
        self.sock = os.path.join(self.dir, "tmux.sock")
        env = mock.patch.dict(os.environ, {"TMUX_SHARE_LOG": self.log, "TMUX_SHARE_SOCK": self.sock})
        env.start()
        self.addCleanup(env.stop)
        self.addCleanup(shutil.rmtree, self.dir, True)

    def write(self, data):
        with open(self.log, "wb") as handle:
            handle.write(data)


class StatusTests(TmpCase):
    def test_status_reports_size_mtime_and_absent_socket(self):
        self.write(b"x" * 123)
        result = call(tools._handle_status)
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["transcript"]["size_bytes"], 123, "status must report the transcript size")
        self.assertTrue(result["transcript"]["mtime"], "status must report a modification time")
        self.assertEqual(result["socket"]["status"], "absent", "no socket file means socket status absent")
        self.assertTrue(result["readable"], "a file this process owns must be readable")

    def test_status_reports_socket_mode_000_as_ok(self):
        if IS_ROOT:
            self.skipTest("root connects to a mode-000 socket, so the ok status cannot be produced as root")
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            server.bind(self.sock)
        except OSError as exc:
            self.skipTest("cannot create a unix socket in this temp directory: {}".format(exc))
        server.close()
        os.chmod(self.sock, 0)
        self.write(b"x\n")
        result = call(tools._handle_status)
        self.assertEqual(result["socket"]["status"], "ok", "a mode-000 socket refuses this reader with EACCES")

    def test_status_missing_transcript_reports_not_deployed(self):
        result = call(tools._handle_status)
        self.assertEqual(result["status"], "not_deployed", "no transcript and no socket is not_deployed")
        self.assertIs(result["transcript"]["exists"], False)
        self.assertIn("not deployed", result["message"])
        self.assertIn(self.log, result["message"], "the message must name the transcript path")

    def test_status_reports_unreadable_transcript_as_not_readable(self):
        if IS_ROOT:
            self.skipTest("root reads a chmod-000 file, so the unreadable case cannot be produced as root")
        self.write(b"x\n")
        os.chmod(self.log, 0)
        with mock.patch.object(tools, "_reader_group_state", return_value=("inactive", 4242)):
            result = call(tools._handle_status)
        self.assertFalse(result["readable"], "a chmod-000 transcript is not readable by this process")
        self.assertIn("tmux-share", result["readable_detail"])
        self.assertEqual(result["reader_group"]["state"], "inactive")

    def test_status_reports_reader_group_state(self):
        state, gid = tools._reader_group_state()
        self.assertIn(state, ("missing", "inactive", "active"), "the real host state must be one of the three")
        if state == "missing":
            self.assertIsNone(gid)
        else:
            self.assertIsInstance(gid, int)


class TailTests(TmpCase):
    def test_tail_default_returns_last_40_lines(self):
        self.write(numbered_lines(500))
        result = call(tools._handle_tail)
        lines = result["text"].split("\n")
        self.assertEqual(len(lines), 40, "the default is 40 lines")
        self.assertEqual(lines[0], "line 00460", "the first returned line is 40 from the end")
        self.assertEqual(lines[-1], "line 00499", "the last returned line is the final line of the file")

    def test_tail_lines_argument_returns_last_n_lines(self):
        self.write(numbered_lines(500))
        result = call(tools._handle_tail, {"lines": 5})
        self.assertEqual(result["text"].split("\n"),
                         ["line 00495", "line 00496", "line 00497", "line 00498", "line 00499"])

    def test_tail_clamps_request_to_200_lines(self):
        self.write(numbered_lines(500))
        result = call(tools._handle_tail, {"lines": 10000})
        self.assertEqual(result["lines_returned"], 200, "a request above the maximum is clamped to 200")
        self.assertEqual(result["max_lines"], 200)
        self.assertEqual(result["text"].split("\n")[-1], "line 00499")

    def test_tail_rejects_zero_lines(self):
        self.write(numbered_lines(5))
        result = call(tools._handle_tail, {"lines": 0})
        self.assertEqual(result["status"], "error", "lines below 1 is an error, not a silent default")

    def test_tail_strips_ansi_by_default(self):
        self.write(b"\x1b[31mred\x1b[0m alert\n\x1b]0;window title\x07done\n")
        result = call(tools._handle_tail)
        self.assertEqual(result["text"], "red alert\ndone", "ANSI colour and OSC sequences are removed by default")
        self.assertTrue(result["ansi_stripped"])

    def test_tail_raw_keeps_ansi(self):
        self.write(b"\x1b[31mred\x1b[0m alert\n")
        result = call(tools._handle_tail, {"raw": True})
        self.assertIn("\x1b[31mred", result["text"], "raw=true must keep the escape sequences")
        self.assertFalse(result["ansi_stripped"])

    def test_tail_collapses_carriage_return_redraws(self):
        self.write(b"progress 10%\rprogress 100%\r\nnext\n")
        result = call(tools._handle_tail)
        self.assertEqual(result["text"], "progress 100%\nnext",
                         "a progress redraw must show only its final state")

    def test_tail_never_returns_more_than_cap_on_10mb_file(self):
        row = (b"x" * 4095) + b"\n"  # 4 KiB per line, so 200 lines is 800 KiB and the cap must engage
        with open(self.log, "wb") as handle:
            for _ in range(2560):  # 2560 * 4096 bytes = exactly 10 MiB
                handle.write(row)
        for request in ({"lines": 200}, {"lines": 10000}, {}):
            with self.subTest(request=request):
                result = call(tools._handle_tail, request)
                self.assertEqual(result["size_bytes"], 10 * 1024 * 1024)
                self.assertLessEqual(len(result["text"].encode("utf-8")), tools.OUTPUT_CAP_BYTES,
                                     "the returned text must never exceed the 64 KiB cap")
                self.assertLessEqual(result["lines_returned"], 200)
                self.assertTrue(result["truncated"], "a capped response must say it was truncated")

    def test_tail_reads_only_a_bounded_window_of_10mb_file(self):
        row = (b"x" * 51) + b"\n"  # 52 bytes per line, so 200000 lines is about 10 MB
        with open(self.log, "wb") as handle:
            for _ in range(200000):
                handle.write(row)
        records = []
        with counting_reads(records):
            result = call(tools._handle_tail, {"lines": 200})
        self.assertEqual(len(records), 1, "the tail must open the transcript exactly once")
        self.assertLessEqual(records[0].bytes_read, tools.TAIL_WINDOW_BYTES,
                             "the tail must read at most its window from the end, not the whole file")
        self.assertGreater(result["size_bytes"], 2 * tools.TAIL_WINDOW_BYTES, "the fixture must be much larger")


class ReadTests(TmpCase):
    def test_read_slices_are_disjoint_and_concatenate_to_head(self):
        content = "".join("{:04d}\n".format(i) for i in range(300)).encode("ascii")  # 1500 bytes
        self.write(content)
        first = call(tools._handle_read, {"offset": 0, "max_bytes": 100})
        second = call(tools._handle_read, {"offset": first["next_offset"], "max_bytes": 100})
        self.assertEqual(first["next_offset"], 100, "next_offset must be offset plus bytes returned")
        self.assertEqual(second["offset"], 100)
        self.assertEqual(second["next_offset"], 200)
        self.assertNotEqual(first["text"], second["text"], "consecutive slices must be disjoint")
        self.assertEqual(first["text"] + second["text"], content[:200].decode("ascii"),
                         "the two slices must concatenate to the head of the file")

    def test_read_default_offset_is_zero(self):
        self.write(b"0000\n0001\n")
        result = call(tools._handle_read)
        self.assertEqual(result["offset"], 0)
        self.assertTrue(result["text"].startswith("0000\n"))

    def test_read_follows_next_offset_to_the_end(self):
        content = numbered_lines(3000)  # 33 KB
        self.write(content)
        pieces, offset = [], 0
        for _ in range(10000):
            result = call(tools._handle_read, {"offset": offset, "max_bytes": 1000})
            self.assertGreater(result["next_offset"], offset, "each read must make progress")
            pieces.append(result["text"])
            offset = result["next_offset"]
            if result["at_end"]:
                break
        self.assertEqual("".join(pieces), content.decode("ascii"), "following next_offset must reproduce the file")

    def test_read_offset_beyond_eof_reports_new_size_without_raising(self):
        content = b"abcdef\n"
        self.write(content)
        result = call(tools._handle_read, {"offset": len(content) + 500})
        self.assertEqual(result["status"], "offset_beyond_eof", "an offset past EOF must be reported, not raised")
        self.assertEqual(result["size_bytes"], len(content), "the reply must carry the current size")
        self.assertEqual(result["next_offset"], len(content), "the reader resumes from the current size")
        self.assertIn("trimmed", result["message"])

    def test_read_holds_back_utf8_split_across_slices(self):
        content = ("aé€\U0001F600 " * 40).encode("utf-8")
        self.write(content)
        pieces, offset = [], 0
        for _ in range(10000):
            result = call(tools._handle_read, {"offset": offset, "max_bytes": 5})  # 5 bytes cuts characters apart
            self.assertGreater(result["next_offset"], offset, "a split character must not stall the reader")
            pieces.append(result["text"])
            offset = result["next_offset"]
            if result["at_end"]:
                break
        self.assertEqual("".join(pieces), content.decode("utf-8"),
                         "characters split across slices must come back whole, with no replacement characters")

    def test_read_default_is_64k_and_max_is_256k(self):
        self.write(b"x" * (300 * 1024))
        default = call(tools._handle_read)
        self.assertEqual(default["bytes_returned"], 65536, "the default read is 65536 bytes")
        capped = call(tools._handle_read, {"max_bytes": 10 ** 9})
        self.assertEqual(capped["bytes_returned"], 262144, "a request above the maximum is clamped to 256 KiB")

    def test_read_reads_only_the_bytes_it_returns(self):
        self.write(b"y" * (10 * 1024 * 1024))
        records = []
        with counting_reads(records):
            result = call(tools._handle_read, {"offset": 4096, "max_bytes": 1000})
        self.assertEqual(result["bytes_returned"], 1000)
        self.assertEqual(records[0].bytes_read, 1000, "a bounded read must not pull in extra bytes")

    def test_read_rejects_negative_offset(self):
        self.write(b"abc\n")
        result = call(tools._handle_read, {"offset": -1})
        self.assertEqual(result["status"], "error", "a negative offset is an error, not a silent start-of-file read")


class MissingAndUnreadableTests(TmpCase):
    def test_missing_transcript_is_not_deployed_for_every_tool(self):
        for handler in (tools._handle_status, tools._handle_tail, tools._handle_read):
            with self.subTest(handler=handler.__name__):
                result = call(handler)  # must not raise
                self.assertEqual(result["status"], "not_deployed", "a missing transcript is not_deployed")
                self.assertIn("not deployed", json.dumps(result))
                self.assertIn(self.log, json.dumps(result), "the reply must name the transcript path")

    def test_unreadable_transcript_names_reader_group_and_restart(self):
        if IS_ROOT:
            self.skipTest("root reads a chmod-000 file, so EACCES cannot be produced as root")
        self.write(b"content\n")
        os.chmod(self.log, 0)
        with mock.patch.object(tools, "_reader_group_state", return_value=("inactive", 4242)):
            for handler in (tools._handle_tail, tools._handle_read):
                with self.subTest(handler=handler.__name__):
                    result = call(handler)  # must not raise a traceback
                    self.assertEqual(result["status"], "denied", "EACCES is reported as denied")
                    self.assertIn("tmux-share", result["message"], "the message must name the reader group")
                    self.assertIn("not active in this process", result["message"])
                    self.assertIn("restart", result["message"], "a stale group needs the agent service restarted")
                    self.assertIn(self.log, result["message"])
                    self.assertNotIn("Traceback", json.dumps(result))

    def test_unreadable_transcript_when_group_is_missing_says_so(self):
        if IS_ROOT:
            self.skipTest("root reads a chmod-000 file, so EACCES cannot be produced as root")
        self.write(b"content\n")
        os.chmod(self.log, 0)
        with mock.patch.object(tools, "_reader_group_state", return_value=("missing", None)):
            result = call(tools._handle_tail)
        self.assertEqual(result["status"], "denied")
        self.assertIn("does not exist on this host", result["message"])

    def test_unreadable_transcript_with_group_held_points_at_file_mode(self):
        if IS_ROOT:
            self.skipTest("root reads a chmod-000 file, so EACCES cannot be produced as root")
        self.write(b"content\n")
        os.chmod(self.log, 0)
        with mock.patch.object(tools, "_reader_group_state", return_value=("active", 4242)):
            result = call(tools._handle_tail)
        self.assertEqual(result["status"], "denied")
        self.assertIn("mode or ownership", result["message"], "a held group with EACCES is a file-mode problem")
        self.assertNotIn("restart", result["message"], "a restart would not help when the group is already held")

    def test_denied_messages_never_suggest_privilege_escalation(self):
        if IS_ROOT:
            self.skipTest("root reads a chmod-000 file, so EACCES cannot be produced as root")
        self.write(b"content\n")
        os.chmod(self.log, 0)
        for state in ("missing", "inactive", "active"):
            with self.subTest(state=state):
                with mock.patch.object(tools, "_reader_group_state", return_value=(state, 4242)):
                    message = call(tools._handle_tail)["message"]
                for banned in ("sudo", "pkexec", "sg ", "root"):
                    self.assertNotIn(banned, message, "the message must not suggest {!r}".format(banned))


class CheckFnTests(TmpCase):
    def test_tools_are_hidden_without_deployment(self):
        self.assertFalse(tools._deployed(), "no transcript and no socket means the tools are hidden")
        self.write(b"x\n")
        self.assertTrue(tools._deployed(), "a transcript alone makes the tools available")

    def test_tools_are_available_when_only_the_socket_exists(self):
        with open(self.sock, "wb"):
            pass
        self.assertTrue(tools._deployed(), "a socket path alone makes the tools available")

    def test_tools_stay_visible_when_the_directory_is_closed_to_this_process(self):
        # A non-member cannot search /run/tmux-share, so stat fails with EACCES. The deployment is present, so the
        # tools must stay visible and explain the group problem instead of disappearing.
        if IS_ROOT:
            self.skipTest("root can search any directory, so EACCES cannot be produced as root")
        locked = os.path.join(self.dir, "locked")
        os.mkdir(locked)
        os.chmod(locked, 0)
        self.addCleanup(os.chmod, locked, 0o755)
        with mock.patch.dict(os.environ, {"TMUX_SHARE_LOG": os.path.join(locked, "transcript.log")}):
            self.assertTrue(tools._deployed(), "EACCES on stat means present-but-hidden, so the tools stay visible")


class RegistrationTests(TmpCase):
    def test_register_exposes_three_tools_in_tmux_share_toolset(self):
        plugin = _load_plugin_package()
        # The package loads its own copy of tools.py, so compare against that copy, not the one this file loaded.
        package_tools = sys.modules["tmux_share_plugin.tools"]

        class FakeContext:
            def __init__(self):
                self.calls = []

            def register_tool(self, **kwargs):
                self.calls.append(kwargs)

        ctx = FakeContext()
        plugin.register(ctx)
        names = sorted(call_["name"] for call_ in ctx.calls)
        self.assertEqual(names, ["tmux_share_read", "tmux_share_status", "tmux_share_tail"])
        for registration in ctx.calls:
            with self.subTest(tool=registration["name"]):
                self.assertEqual(registration["toolset"], "tmux_share")
                self.assertEqual(registration["schema"]["name"], registration["name"])
                self.assertTrue(callable(registration["handler"]))
                self.assertIs(registration["check_fn"], package_tools._deployed)


class PrivilegeLintTests(unittest.TestCase):
    """Grep the plugin's own source. Its job is to read the transcript; these patterns must not appear."""

    PROCESS_AND_PRIVILEGE = [
        r"\bsubprocess\b",
        r"\bos\.system\b",
        r"\bsudo\b",
        r"\bsg\s",
        r"\bpkexec\b",
        r"\bos\.popen\b",
        r"\bos\.exec\w*",
        r"\bos\.spawn\w*",
    ]
    WRITE_AND_LOCK = [
        r"O_WRONLY",
        r"O_RDWR",
        r"O_APPEND",
        r"O_CREAT",
        r"O_TRUNC",
        r"\.truncate\(",
        r"\bflock\b",
        r"tmux-share\.lock",
        r"\.write\(",
        r"open\([^)]*['\"][wax]\+?b?['\"]",
        r"\bos\.(remove|unlink|rename|replace|mkdir|makedirs)\b",
    ]

    @staticmethod
    def _plugin_sources():
        found = []
        for root, _dirs, files in os.walk(PLUGIN_DIR):
            for name in files:
                if name.endswith((".py", ".yaml")):
                    found.append(os.path.join(root, name))
        return found

    def _hits(self, patterns):
        sources = self._plugin_sources()
        self.assertTrue(sources, "the lint found no plugin sources to scan")
        hits = []
        for path in sources:
            with open(path, encoding="utf-8") as handle:
                for lineno, line in enumerate(handle, 1):
                    for pattern in patterns:
                        if re.search(pattern, line):
                            hits.append("{}:{}: {}".format(os.path.relpath(path, REPO_ROOT), lineno, line.strip()))
        return hits

    def test_lint_patterns_catch_what_they_are_meant_to_catch(self):
        for sample in ("import subprocess", "os.system('x')", "sudo tmux", "sg tmux-share", "pkexec sh",
                       "os.popen('id')"):
            with self.subTest(sample=sample):
                self.assertTrue(any(re.search(p, sample) for p in self.PROCESS_AND_PRIVILEGE),
                                "the pattern set must match {!r}, or the lint is vacuous".format(sample))

    def test_plugin_source_contains_no_process_or_privilege_escalation(self):
        hits = self._hits(self.PROCESS_AND_PRIVILEGE)
        self.assertEqual(hits, [], "forbidden process or privilege use in plugin source:\n" + "\n".join(hits))

    def test_plugin_source_never_writes_truncates_or_locks(self):
        hits = self._hits(self.WRITE_AND_LOCK)
        self.assertEqual(hits, [], "write, truncate, append, or lock use in plugin source:\n" + "\n".join(hits))


if __name__ == "__main__":
    unittest.main(verbosity=2)
