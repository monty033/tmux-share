#!/usr/bin/env python3
"""Tests for core/tmux-share-stamp. Run: python3 tests/stamp/test_stamp.py"""

import importlib.machinery
import importlib.util
import os
import random
import re
import subprocess
import sys
import unittest

# Do not leave __pycache__ directories in the repository.
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "..", "core", "tmux-share-stamp")


def load_module():
    loader = importlib.machinery.SourceFileLoader("tmux_share_stamp", SCRIPT)
    spec = importlib.util.spec_from_loader("tmux_share_stamp", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


stamp = load_module()
GAP = stamp.GAP
STAMP_RE = re.compile(rb"\r\n\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\] ")
STAMP_LEN = 2 + 1 + 19 + 1 + 1  # CRLF, "[", datetime, "]", space


class FakeClock:
    """One fake timeline. wall() is the same timeline offset to a fixed date."""

    def __init__(self):
        self.t = 0.0

    def clock(self):
        return self.t

    def wall(self):
        return 1700000000.0 + self.t


def run_filter(chunks, gaps, write_cost=None, gap=1.0):
    """Drive stamp_stream with a fake clock.

    gaps[i] is the idle time before chunk i is read. write_cost[i] is how long
    the write of chunk i takes (it advances the fake clock, modelling a write
    that blocks on a stalled reader). Returns (status, writes), where writes is
    a list of (output_offset, bytes) per write call.
    """
    fc = FakeClock()
    write_cost = write_cost or [0.0] * len(chunks)
    queue = list(zip(chunks, gaps))
    writes = []
    state = {"pos": 0, "i": -1}

    def read():
        if not queue:
            return b""
        chunk, idle = queue.pop(0)
        fc.t += idle
        state["i"] += 1
        return chunk

    def write(data):
        writes.append((state["pos"], data))
        state["pos"] += len(data)
        fc.t += write_cost[state["i"]]  # time passes while the write blocks

    status = stamp.stamp_stream(read, write, clock=fc.clock, wall=fc.wall, gap=gap)
    return status, writes


def count_stamps(writes, chunks):
    return sum(1 for (_, data), chunk in zip(writes, chunks) if len(data) != len(chunk))


class StampTests(unittest.TestCase):
    def test_import_does_not_run_read_loop(self):
        # load_module() already ran at import time without touching stdin.
        self.assertTrue(callable(stamp.stamp_stream), "stamp_stream is exposed")
        self.assertEqual(GAP, 1.0, "default GAP is 1.0 when env is unset")

    def test_byte_fidelity(self):
        rng = random.Random(1234)
        chunks = [
            b"hello\r\n",
            b"\x00\x00\xff\xfe\x80\xc3",           # NUL, 0xFF, truncated UTF-8
            b"\xa9 rest of the split e-acute",       # continuation of the above
            b"\x1b]0;window ti",                     # OSC split ...
            b"tle\x07\x1b[3",                        # ... then CSI split ...
            b"1mred\x1b[0m\r",                       # ... and finished
            b"\r\n[2000-01-01 00:00:00] ",           # input that looks like a stamp
            bytes(rng.randrange(256) for _ in range(65536)),
        ]
        chunks += [bytes(rng.randrange(256) for _ in range(rng.randrange(1, 300)))
                   for _ in range(40)]
        gaps = [0.0] + [rng.choice([0.0, 0.1, 2.0, 5.0]) for _ in chunks[1:]]
        status, writes = run_filter(chunks, gaps)
        self.assertEqual(status, 0, "byte fidelity run exits 0")

        output = b"".join(data for _, data in writes)
        # Recorded offsets of the inserted stamps in the output stream.
        offsets = [off for (off, data), chunk in zip(writes, chunks)
                   if len(data) != len(chunk)]
        self.assertTrue(offsets, "byte fidelity run inserted at least one stamp")
        self.assertEqual(offsets[0], 0, "stream starts with a stamp")
        rebuilt = bytearray()
        cursor = 0
        for off in offsets:
            self.assertRegex(output[off:off + STAMP_LEN], STAMP_RE,
                             "inserted bytes at offset %d form a stamp" % off)
            rebuilt += output[cursor:off]
            cursor = off + STAMP_LEN
        rebuilt += output[cursor:]
        self.assertEqual(bytes(rebuilt), b"".join(chunks),
                         "removing only the inserted stamps restores the input exactly")

    def test_stamp_format_is_local_time_without_zone(self):
        _, writes = run_filter([b"x"], [0.0])
        data = writes[0][1]
        self.assertTrue(data.endswith(b"x"), "chunk follows the stamp unchanged")
        self.assertRegex(data[:-1], rb"^" + STAMP_RE.pattern + rb"$",
                         "stamp is exactly CRLF [YYYY-MM-DD HH:MM:SS] space")

    def test_gap_counting(self):
        chunks = [b"a", b"b", b"c", b"d", b"e"]
        gaps = [0, 0.5, 1.5, 0.2, 3]  # idle before each chunk; first is the start
        status, writes = run_filter(chunks, gaps)
        self.assertEqual(status, 0, "gap run exits 0")
        self.assertTrue(len(writes[0][1]) > len(chunks[0]), "first chunk is stamped")
        self.assertEqual(count_stamps(writes, chunks), 3,
                         "gaps [0, 0.5, 1.5, 0.2, 3] give exactly 3 stamps")
        stamped = [len(d) != len(c) for (_, d), c in zip(writes, chunks)]
        self.assertEqual(stamped, [True, False, True, False, True],
                         "stamps land on chunks 1, 3 and 5 only")

    def test_gap_is_strictly_greater_than(self):
        chunks = [b"a", b"b"]
        _, writes = run_filter(chunks, [0, 1.0], gap=1.0)
        self.assertEqual(count_stamps(writes, chunks), 1,
                         "a pause of exactly GAP is not stamped")

    def test_continuous_burst(self):
        chunks = [b"one\n", b"two\n", b"three\n", b"four\n"]
        # Each write takes 0.4s and chunks arrive immediately after, so the
        # stream runs for longer than GAP overall without ever idling past it.
        status, writes = run_filter(chunks, [0, 0, 0, 0], write_cost=[0.4] * 4)
        self.assertEqual(status, 0, "burst run exits 0")
        self.assertEqual(count_stamps(writes, chunks), 1,
                         "four back-to-back chunks give exactly 1 stamp")

    def test_blocked_write_does_not_look_idle(self):
        chunks = [b"first", b"second"]
        # The first write blocks for 5s (> GAP); the next chunk is already
        # waiting and is read immediately afterwards.
        status, writes = run_filter(chunks, [0, 0], write_cost=[5.0, 0.0])
        self.assertEqual(status, 0, "blocked write run exits 0")
        self.assertEqual(count_stamps(writes, chunks), 1,
                         "chunk after a long blocked write gets no extra stamp "
                         "(clock advances after the write completes)")
        self.assertEqual(writes[1][1], b"second", "second chunk is written untouched")

    def test_idle_after_blocked_write_is_still_stamped(self):
        chunks = [b"first", b"second"]
        _, writes = run_filter(chunks, [0, 2.0], write_cost=[5.0, 0.0])
        self.assertEqual(count_stamps(writes, chunks), 2,
                         "a real pause after a blocked write is stamped")

    def test_eof_exits_zero(self):
        status, writes = run_filter([], [])
        self.assertEqual(status, 0, "immediate EOF exits 0")
        self.assertEqual(writes, [], "immediate EOF writes nothing")

    def test_read_error_exits_one(self):
        def read():
            raise OSError(5, "simulated read failure")

        saved = sys.stderr
        sys.stderr = open(os.devnull, "w")
        try:
            status = stamp.stamp_stream(read, lambda data: None)
        finally:
            sys.stderr.close()
            sys.stderr = saved
        self.assertEqual(status, 1, "simulated read error exits 1")


class ProcessTests(unittest.TestCase):
    """Run the real executable end to end."""

    def run_script(self, data, gap="3600"):
        env = dict(os.environ, TMUX_SHARE_STAMP_GAP=gap)
        return subprocess.run([sys.executable, SCRIPT], input=data,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)

    def test_process_passes_bytes_and_exits_zero_at_eof(self):
        data = b"\x00\xff\xfe\x1b]0;t\x07\xc3" + bytes(range(256)) * 600
        proc = self.run_script(data)
        self.assertEqual(proc.returncode, 0, "process exits 0 at EOF")
        self.assertRegex(proc.stdout[:STAMP_LEN], STAMP_RE, "process stamps the first chunk")
        self.assertEqual(proc.stdout[STAMP_LEN:], data,
                         "process output minus its one stamp equals the input")

    def test_process_empty_input(self):
        proc = self.run_script(b"")
        self.assertEqual((proc.returncode, proc.stdout), (0, b""),
                         "empty input exits 0 with no output")

    def test_process_read_error_exits_one_with_message(self):
        # Close fd 0 before running the script so its first read fails (EBADF).
        launcher = ("import os, runpy, sys; os.close(0); "
                    "runpy.run_path(sys.argv[1], run_name='__main__')")
        proc = subprocess.run([sys.executable, "-c", launcher, SCRIPT],
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE)
        self.assertEqual(proc.returncode, 1, "real read error exits 1")
        self.assertIn(b"read error", proc.stderr, "read error message goes to stderr")


class Result(unittest.TextTestResult):
    pass


def main():
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    result = unittest.TextTestRunner(verbosity=2, resultclass=Result).run(suite)
    ok = result.wasSuccessful()
    print("%s: %d run, %d failures, %d errors"
          % ("PASS" if ok else "FAIL", result.testsRun, len(result.failures),
             len(result.errors)))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
