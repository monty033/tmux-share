"""Read-only safety probe for the root-owned tmux control socket.

A Hermes reader may be allowed to read the transcript, but it must never be
able to talk to the tmux socket: anyone who can connect to that socket can
send keys or run shell commands on the root-owned server.  This module
performs exactly one connect attempt and reports what it found.  It never
sends bytes, never reads bytes, never keeps a connection open, and never
retries in a loop.

``check_socket(path)`` returns a dict with at least ``status`` and a
human-readable ``detail``.  The statuses are:

* ``absent`` -- there is no filesystem entry at *path*.  This is the normal
  state on a host where the feature is not deployed.
* ``ok`` -- the entry is a socket, but connecting was refused with EACCES or
  EPERM because the caller lacks permission.  This is the expected, safe
  state: the reader cannot reach the socket.
* ``UNSAFE`` -- connecting succeeded.  The reader can talk to the root-owned
  server, so this must be reported.  This is the only status that requires
  action.
* ``error`` -- anything else: a non-socket entry, a stat/connect failure, an
  ENOENT race, or ECONNREFUSED on a stale socket with no listener (which is
  not a boundary failure).  ``detail`` explains the specific case.

Only the Python standard library is used; there are no subprocesses, no
shell calls, and no writes to the socket.
"""

import errno
import os
import socket
import stat

# A short timeout keeps the probe prompt even if connect blocks on an
# unusually backed-up listener.  We never read or write, so no other timeout
# is needed.
_CONNECT_TIMEOUT_SECONDS = 0.5


def _connect_detail(status, message, path):
    """Build a consistent result dict for a connect outcome."""
    return {"status": status, "detail": "{}: {}".format(message, path)}


def _classify_connect_error(exc, path):
    """Map an OSError from connect() to a status and detail string."""
    code = exc.errno
    if code in (errno.EACCES, errno.EPERM):
        return _connect_detail(
            "ok",
            "connect refused with permission denied (EACCES/EPERM): "
            "the reader cannot reach the tmux socket, which is the "
            "expected safe state",
            path,
        )
    if code == errno.ENOENT:
        return _connect_detail(
            "error",
            "socket disappeared between check and connect (ENOENT race)",
            path,
        )
    if code == errno.ECONNREFUSED:
        return _connect_detail(
            "error",
            "connect refused (ECONNREFUSED): stale socket with no active "
            "listener; this is not a boundary failure",
            path,
        )
    return _connect_detail(
        "error",
        "connect failed ({})".format(code),
        path,
    )


def _probe_connect(path):
    """Attempt one connection, send/read nothing, and close immediately."""
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    except OSError as exc:
        return _connect_detail(
            "error", "could not create probe socket ({})".format(exc.errno), path
        )

    try:
        sock.settimeout(_CONNECT_TIMEOUT_SECONDS)
        try:
            sock.connect(path)
        except OSError as exc:
            return _classify_connect_error(exc, path)
        else:
            # A successful connect is itself the finding.  Do not send or
            # read anything; the finally block closes the connection at once.
            return _connect_detail(
                "UNSAFE",
                "connect succeeded: the reader can talk to the root-owned "
                "tmux server and can therefore control it",
                path,
            )
    finally:
        sock.close()


def check_socket(path):
    """Check whether *path* is a unix socket the reader can connect to.

    A non-string/non-path-like *path* is a programmer error and raises
    ``TypeError``.  Every filesystem or socket error is reported in the
    returned dict rather than raised.
    """
    if not isinstance(path, (str, bytes, os.PathLike)):
        raise TypeError("path must be a string, bytes, or os.PathLike")

    try:
        info = os.stat(path)
    except FileNotFoundError:
        return {"status": "absent", "detail": "no filesystem entry at {}".format(path)}
    except OSError as exc:
        return _connect_detail(
            "error", "could not inspect path ({})".format(exc.errno), path
        )

    if not stat.S_ISSOCK(info.st_mode):
        return _connect_detail("error", "path exists but is not a socket", path)

    return _probe_connect(path)
