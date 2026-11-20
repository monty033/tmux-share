#!/usr/bin/env python3
"""Acceptance test for hermes-plugin/tmux_share_reader/boundary.py.

Run with:  python3 tests/plugin/test_boundary.py

All fixtures live in a temporary directory that is removed on exit.  The
probe module is imported directly from its directory, so no package
``__init__.py`` is needed and no host-specific paths are hard-coded.
"""

import errno
import os
import socket
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
MODULE_DIR = os.path.join(REPO_ROOT, "hermes-plugin", "tmux_share_reader")
if MODULE_DIR not in sys.path:
    sys.path.insert(0, MODULE_DIR)

import boundary  # noqa: E402  (path prepared above)


def _stream_socket():
    return socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)


def run():
    failures = []

    def check(label, condition, detail=""):
        if condition:
            print("PASS: {}".format(label))
        else:
            message = "FAIL: {}".format(label)
            if detail:
                message += " -- {}".format(detail)
            print(message)
            failures.append(message)

    with tempfile.TemporaryDirectory(prefix="boundary-test-") as tmp:
        # 1. Absent path.
        absent_path = os.path.join(tmp, "absent.sock")
        result = boundary.check_socket(absent_path)
        check("absent path reports absent", result.get("status") == "absent", repr(result))
        check("absent path has a detail string", bool(result.get("detail")), repr(result))

        # 2. EACCES / EPERM path, modelled by patching only connect().
        # The owner of a 000-mode socket can still connect on Linux, so a
        # genuine EACCES needs a different effective identity (root here).
        # Instead we create a real socket file and patch just socket.connect
        # to raise the permission error, leaving the rest of check_socket real.
        denied_path = os.path.join(tmp, "denied.sock")
        stub = _stream_socket()
        stub.bind(denied_path)  # creates the socket file
        stub.close()  # leaves a stale socket node; stat still sees a socket

        real_connect = socket.socket.connect
        for code, name in ((errno.EACCES, "EACCES"), (errno.EPERM, "EPERM")):

            def deny_connect(self, address, _code=code):
                raise PermissionError(_code, "Permission denied")

            socket.socket.connect = deny_connect
            try:
                result = boundary.check_socket(denied_path)
            finally:
                socket.socket.connect = real_connect
            check("{} maps to ok".format(name), result.get("status") == "ok", repr(result))
            check(
                "{} detail mentions expected safe state".format(name),
                "safe" in (result.get("detail") or "").lower(),
                repr(result),
            )

        # 3. Listening socket that accepts: UNSAFE, zero bytes, client closes.
        live_path = os.path.join(tmp, "live.sock")
        server = _stream_socket()
        server.bind(live_path)
        server.listen(1)
        server.settimeout(3.0)
        received = []

        def accept_once():
            try:
                conn, _ = server.accept()
            except OSError as exc:
                received.append(exc)
                return
            with conn:
                conn.settimeout(2.0)
                try:
                    data = conn.recv(4096)
                except socket.timeout:
                    data = b"<timeout>"
                received.append(data)

        server_thread = threading.Thread(target=accept_once)
        server_thread.start()
        try:
            result = boundary.check_socket(live_path)
        finally:
            server_thread.join(3.0)
            server.close()
        check(
            "listening socket reports UNSAFE",
            result.get("status") == "UNSAFE",
            repr(result),
        )
        check(
            "accepting end receives no bytes and sees client close",
            received == [b""],
            repr(received),
        )
        check("accept thread finished", not server_thread.is_alive(), "thread still alive")

        # 4. Plain file at the path: error, never absent/ok/UNSAFE.
        plain_path = os.path.join(tmp, "plain.txt")
        with open(plain_path, "w") as handle:
            handle.write("not a socket\n")
        result = boundary.check_socket(plain_path)
        check("plain file reports error", result.get("status") == "error", repr(result))
        check(
            "plain file is not absent/ok/UNSAFE",
            result.get("status") not in ("absent", "ok", "UNSAFE"),
            repr(result),
        )

        # 5. Stale socket with no listener: error with stale/refused message.
        stale_path = os.path.join(tmp, "stale.sock")
        stale = _stream_socket()
        stale.bind(stale_path)
        stale.close()  # socket file remains, but nothing is listening
        result = boundary.check_socket(stale_path)
        check("stale socket reports error", result.get("status") == "error", repr(result))
        detail_lower = (result.get("detail") or "").lower()
        check(
            "stale socket detail mentions stale or refused",
            ("stale" in detail_lower or "refused" in detail_lower),
            repr(result),
        )

        # 6. Prompt return against a listener that accepts but never responds.
        slow_path = os.path.join(tmp, "slow.sock")
        slow_server = _stream_socket()
        slow_server.bind(slow_path)
        slow_server.listen(1)
        slow_server.settimeout(3.0)
        stop = threading.Event()

        def hold_open():
            try:
                conn, _ = slow_server.accept()
            except OSError:
                return
            with conn:
                stop.wait(3.0)  # unresponsive: never read or reply

        slow_thread = threading.Thread(target=hold_open)
        slow_thread.start()
        started = time.monotonic()
        try:
            result = boundary.check_socket(slow_path)
        finally:
            elapsed = time.monotonic() - started
            stop.set()
            slow_thread.join(3.0)
            slow_server.close()
        check("unresponsive listener still reported UNSAFE", result.get("status") == "UNSAFE", repr(result))
        check("probe returns promptly (< 2 s)", elapsed < 2.0, "elapsed={:.3f}s".format(elapsed))
        check("hold thread finished", not slow_thread.is_alive(), "thread still alive")

        # 7. Programmer error: a non-string path raises TypeError.
        try:
            boundary.check_socket(123)
            raised = False
        except TypeError:
            raised = True
        check("non-string path raises TypeError", raised, "no TypeError raised")

    if failures:
        print("FAIL: {} of the boundary checks failed".format(len(failures)))
        return 1
    print("PASS: all boundary checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(run())
