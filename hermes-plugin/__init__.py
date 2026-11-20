"""tmux-share transcript plugin for Hermes.

Registers the three read-only ``tmux_share`` tools. Everything it does is
implemented in ``tools.py``; this module only wires the plugin entry point.
"""

from .tools import register_tools


def register(ctx) -> None:
    """Plugin entry point, called by the Hermes plugin loader."""
    register_tools(ctx)


__all__ = ["register", "register_tools"]
