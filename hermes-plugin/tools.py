"""tmux-share transcript tools for Hermes: read the transcript, report status, refuse everything else.

Three read-only tools in the ``tmux_share`` toolset:

* ``tmux_share_status`` -- where the transcript is, whether this process can read it, and the socket self-check.
* ``tmux_share_tail`` -- the last N lines, with carriage-return redraws collapsed and ANSI escapes stripped by default.
* ``tmux_share_read`` -- a bounded slice from a byte offset, plus the offset to resume from.

The tools only stat the transcript and open it for reading. They never write, truncate, append, take the lock, or
send input. The one contact with the socket is the single connect attempt in ``boundary.check_socket``, which sends
and reads nothing. Standard library only; no process is ever started.
"""

import grp
import importlib.util
import json
import os
import re
import stat
from datetime import datetime, timezone

TOOLSET = "tmux_share"
READER_GROUP = "tmux-share"

DEFAULT_LOG = "/run/tmux-share/transcript.log"
DEFAULT_SOCK = "/run/tmux-share/tmux.sock"

TAIL_DEFAULT_LINES = 40
TAIL_MAX_LINES = 200
# The tail never reads more than this from the end of the file, however large the transcript is.
TAIL_WINDOW_BYTES = 256 * 1024
# No tool returns more text than this in one response.
OUTPUT_CAP_BYTES = 64 * 1024

READ_DEFAULT_BYTES = 64 * 1024
READ_MAX_BYTES = 256 * 1024
# Large enough that holding back a partial UTF-8 character always leaves at least one byte of progress.
READ_MIN_BYTES = 4

# Escape sequences: CSI (colours, cursor moves, erases), OSC (titles, hyperlinks), and two-byte or charset escapes.
_ANSI_RE = re.compile(
    r"\x1b\[[0-?]*[ -/]*[@-~]"
    r"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"
    r"|\x1b[ -/]*[0-~]"
)
# Control bytes a terminal acts on rather than displays. Tab and newline are kept.
_CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def _load_boundary():
    """Load the socket probe by file path, so this plugin needs no package __init__ in tmux_share_reader."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tmux_share_reader", "boundary.py")
    spec = importlib.util.spec_from_file_location("tmux_share_boundary", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


boundary = _load_boundary()


# ── configuration and reply helpers ──────────────────────────────────────────
def _log_path():
    return os.environ.get("TMUX_SHARE_LOG") or DEFAULT_LOG


def _sock_path():
    return os.environ.get("TMUX_SHARE_SOCK") or DEFAULT_SOCK


def _reply(status, **fields):
    return json.dumps(dict(status=status, **fields), ensure_ascii=False)


def _int_arg(args, name, default, low, high):
    """Integer argument. Missing takes the default, below *low* is an error, above *high* is clamped."""
    value = args.get(name)
    if value is None:
        return default
    if isinstance(value, str) and value.strip().isdigit():  # XML tool-calling mode delivers strings
        value = int(value)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError("{} must be an integer".format(name))
    if value < low:
        raise ValueError("{} must be at least {}".format(name, low))
    return min(value, high)


def _bool_arg(args, name, default):
    value = args.get(name)
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, str) and value.strip().lower() in ("true", "false"):
        return value.strip().lower() == "true"
    raise ValueError("{} must be true or false".format(name))


# ── reader group and messages ────────────────────────────────────────────────
def _process_group_ids():
    """Groups this process holds. They are fixed when the process starts, so a later usermod does not show here."""
    return set(os.getgroups()) | {os.getegid()}


def _reader_group_state():
    """Return (state, gid). State is "missing", "inactive" (exists but this process lacks it), or "active"."""
    try:
        gid = grp.getgrnam(READER_GROUP).gr_gid
    except KeyError:
        return "missing", None
    return ("active" if gid in _process_group_ids() else "inactive"), gid


def _not_deployed_message(path):
    return ("not deployed: there is no transcript at {}. The tmux-share transcript is not installed on this host, "
            "or TMUX_SHARE_LOG points somewhere else.").format(path)


def _denied_message(path):
    """Explain an EACCES on the transcript, using the reader group's state in this process."""
    state, _ = _reader_group_state()
    if state == "missing":
        return ("permission denied reading {0}: the '{1}' group does not exist on this host, so the tmux-share "
                "deployment is incomplete. The operator needs to finish installing it.").format(path, READER_GROUP)
    if state == "inactive":
        return ("permission denied reading {0}: the '{1}' reader group is not active in this process. Group membership "
                "is fixed when the agent process starts. If the operator has just added this account to '{1}', the "
                "agent service must be restarted before the transcript can be read.").format(path, READER_GROUP)
    return ("permission denied reading {0} even though this process holds the '{1}' group: the file's mode or "
            "ownership does not grant this reader access. This is for the operator to fix.").format(path, READER_GROUP)


def _open_transcript(path):
    """Open the transcript read-only. Return (file, None), or (None, (status, message)) when it cannot be read.

    Only O_RDONLY is requested. O_NONBLOCK keeps a FIFO at the path from blocking the open, and anything that is not
    a regular file is refused.
    """
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except FileNotFoundError:
        return None, ("not_deployed", _not_deployed_message(path))
    except PermissionError:
        return None, ("denied", _denied_message(path))
    except OSError as exc:
        return None, ("error", "could not open {} (errno {})".format(path, exc.errno))
    handle = os.fdopen(fd, "rb")
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        handle.close()
        return None, ("error", "{} is not a regular file".format(path))
    return handle, None


# ── tmux_share_tail ──────────────────────────────────────────────────────────
def _render_line(line):
    """What a terminal shows for one line: the text after the last carriage return that has any content.

    A progress redraw ("10%\\r20%\\r") therefore shows only its final state.
    """
    for part in reversed(line.split("\r")):
        if part:
            return part
    return ""


def _clean(line):
    return _CONTROL_RE.sub("", _ANSI_RE.sub("", line))


def _tail(handle, size, wanted, raw):
    """Return (text, lines_returned, truncated) for the last *wanted* lines, reading at most TAIL_WINDOW_BYTES."""
    start = max(0, size - TAIL_WINDOW_BYTES)
    handle.seek(start)
    pieces = handle.read(size - start).split(b"\n")
    if start > 0 and len(pieces) > 1:
        pieces = pieces[1:]  # the window may begin in the middle of a line
    if pieces and pieces[-1] == b"":
        pieces.pop()  # the file ends with a newline, so the last piece is empty
    selected = pieces[-wanted:]
    lines = [_render_line(piece.decode("utf-8", errors="replace")) for piece in selected]
    if not raw:
        lines = [_clean(line) for line in lines]
    truncated = start > 0 or len(pieces) > len(selected)
    text = "\n".join(lines)
    encoded = text.encode("utf-8")
    if len(encoded) > OUTPUT_CAP_BYTES:
        truncated = True
        # Keep the newest bytes, then drop the partial line the cut leaves at the top.
        encoded = encoded[-OUTPUT_CAP_BYTES:]
        newline = encoded.find(b"\n")
        if newline != -1:
            encoded = encoded[newline + 1:]
        text = encoded.decode("utf-8", errors="ignore")
    returned = len(text.split("\n")) if text else 0
    return text, returned, truncated


def _handle_tail(args, **kw):
    try:
        wanted = _int_arg(args, "lines", TAIL_DEFAULT_LINES, 1, TAIL_MAX_LINES)
        raw = _bool_arg(args, "raw", False)
    except ValueError as exc:
        return _reply("error", message=str(exc))
    path = _log_path()
    handle, failure = _open_transcript(path)
    if handle is None:
        status, message = failure
        return _reply(status, path=path, message=message)
    with handle:
        size = os.fstat(handle.fileno()).st_size
        text, returned, truncated = _tail(handle, size, wanted, raw)
    return _reply(
        "ok", path=path, size_bytes=size, lines_requested=wanted, lines_returned=returned,
        max_lines=TAIL_MAX_LINES, truncated=truncated, ansi_stripped=not raw, text=text)


# ── tmux_share_read ──────────────────────────────────────────────────────────
def _hold_back_partial_utf8(data):
    """Drop an incomplete UTF-8 sequence at the end of *data*, so the next read picks it up whole."""
    for back in range(1, 4):
        byte = data[-back]
        if (byte & 0xC0) == 0x80:  # continuation byte: keep looking for its lead byte
            continue
        if (byte & 0xE0) == 0xC0:
            needed = 2
        elif (byte & 0xF0) == 0xE0:
            needed = 3
        elif (byte & 0xF8) == 0xF0:
            needed = 4
        else:
            needed = 1
        return data[:-back] if needed > back else data
    return data


def _handle_read(args, **kw):
    try:
        offset = _int_arg(args, "offset", 0, 0, 2 ** 63 - 1)
        max_bytes = _int_arg(args, "max_bytes", READ_DEFAULT_BYTES, READ_MIN_BYTES, READ_MAX_BYTES)
    except ValueError as exc:
        return _reply("error", message=str(exc))
    path = _log_path()
    handle, failure = _open_transcript(path)
    if handle is None:
        status, message = failure
        return _reply(status, path=path, message=message)
    with handle:
        size = os.fstat(handle.fileno()).st_size
        if offset > size:
            return _reply(
                "offset_beyond_eof", path=path, offset=offset, size_bytes=size, next_offset=size, text="",
                message=("offset {0} is past the current end of the transcript ({1} bytes). The file was probably "
                         "trimmed, so the bytes between your offset and the trim are gone. Continue from "
                         "next_offset {1}.").format(offset, size))
        handle.seek(offset)
        data = handle.read(max_bytes)
        if len(data) == max_bytes:  # a full read may stop inside a character; the short read at EOF may not
            data = _hold_back_partial_utf8(data)
    next_offset = offset + len(data)
    return _reply(
        "ok", path=path, size_bytes=size, offset=offset, next_offset=next_offset, bytes_returned=len(data),
        at_end=next_offset >= size, text=data.decode("utf-8", errors="replace"))


# ── tmux_share_status ────────────────────────────────────────────────────────
def _entry_facts(path):
    """stat() the transcript without opening it."""
    try:
        info = os.stat(path)
    except FileNotFoundError:
        return {"exists": False}
    except PermissionError:
        # The entry sits in a directory this process cannot search, so it may well exist.
        return {"exists": None, "note": "inside a directory this process cannot search, so it cannot be inspected"}
    except OSError as exc:
        return {"exists": None, "note": "stat failed (errno {})".format(exc.errno)}
    return {
        "exists": True,
        "regular_file": stat.S_ISREG(info.st_mode),
        "size_bytes": info.st_size,
        "mtime": datetime.fromtimestamp(info.st_mtime, tz=timezone.utc).isoformat(),
    }


def _readable(path):
    """Whether this process can open the transcript. The file is opened and closed without reading."""
    handle, failure = _open_transcript(path)
    if handle is None:
        return False, failure[1]
    handle.close()
    return True, "this process can read the transcript"


def _handle_status(args, **kw):
    path = _log_path()
    sock = _sock_path()
    facts = _entry_facts(path)
    readable, readable_detail = _readable(path)
    group_state, _ = _reader_group_state()
    socket = boundary.check_socket(sock)
    fields = dict(
        path=path, transcript=facts, readable=readable, readable_detail=readable_detail,
        reader_group={"name": READER_GROUP, "state": group_state}, socket_path=sock, socket=socket)
    if facts["exists"] is False and socket["status"] == "absent":
        return _reply("not_deployed", message=_not_deployed_message(path), **fields)
    if socket["status"] == "UNSAFE":
        fields["alert"] = "UNSAFE: this reader can connect to the tmux socket. Report this to the operator now."
    return _reply("ok", **fields)


# ── schemas, check_fn, registration ──────────────────────────────────────────
TMUX_SHARE_STATUS_SCHEMA = {
    "name": "tmux_share_status",
    "description": (
        "Report on the tmux-share transcript: its path, whether it exists, its size and modification time, whether "
        "this process can read it, the reader-group state, and the read-only socket self-check. Takes no arguments. "
        "It cannot send input to tmux."
    ),
    "parameters": {"type": "object", "properties": {}, "required": []},
}

TMUX_SHARE_TAIL_SCHEMA = {
    "name": "tmux_share_tail",
    "description": (
        "Return the last lines of the tmux-share transcript, the record of the root shell's terminal output. "
        "Carriage-return redraws are collapsed to their final state, and ANSI escape sequences are removed unless "
        "raw is true. It reads at most about 256 KiB from the end of the file and returns at most 64 KiB."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "lines": {
                "type": "integer",
                "description": "How many lines to return from the end (default 40, maximum 200).",
                "minimum": 1,
                "maximum": TAIL_MAX_LINES,
            },
            "raw": {
                "type": "boolean",
                "description": "Keep ANSI escape sequences and control characters (default false).",
            },
        },
        "required": [],
    },
}

TMUX_SHARE_READ_SCHEMA = {
    "name": "tmux_share_read",
    "description": (
        "Read the tmux-share transcript from a byte offset, up to max_bytes, and return the text and next_offset, "
        "the offset to pass on the next call. Start at offset 0 and follow next_offset to read the file in order. "
        "The text is not cleaned: escape sequences and carriage returns are included. If offset is past the current "
        "end (the transcript was trimmed), the result has status offset_beyond_eof and reports the new size."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "offset": {
                "type": "integer",
                "description": "Byte offset to start from (default 0).",
                "minimum": 0,
            },
            "max_bytes": {
                "type": "integer",
                "description": "Most bytes to read (default 65536, maximum 262144).",
                "minimum": READ_MIN_BYTES,
                "maximum": READ_MAX_BYTES,
            },
        },
        "required": [],
    },
}

TOOLS = (
    (TMUX_SHARE_STATUS_SCHEMA, _handle_status),
    (TMUX_SHARE_TAIL_SCHEMA, _handle_tail),
    (TMUX_SHARE_READ_SCHEMA, _handle_read),
)


def _entry_present(path):
    try:
        os.stat(path)
    except PermissionError:
        # EACCES from stat means the directory exists and denies this process, so the deployment is present.
        return True
    except OSError:
        return False
    return True


def _deployed():
    """Offer the tools only where the transcript or the socket is present, or present but hidden from this process."""
    return _entry_present(_log_path()) or _entry_present(_sock_path())


def register_tools(ctx) -> None:
    """Register the three tmux_share tools via the plugin API."""
    for schema, handler in TOOLS:
        ctx.register_tool(
            name=schema["name"], toolset=TOOLSET, schema=schema, handler=handler, check_fn=_deployed,
            emoji="📜")
