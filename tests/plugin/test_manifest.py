#!/usr/bin/env python3
"""Checks for hermes-plugin/plugin.yaml: required keys, the three tools, no required environment.

Run with:  python3 tests/plugin/test_manifest.py

The manifest is read as text, with no PyYAML dependency. It uses a small, flat
subset of YAML, so these checks look up exact top-level keys and their items
rather than parsing the whole document.
"""

import os
import re
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
MANIFEST = os.path.join(REPO_ROOT, "hermes-plugin", "plugin.yaml")

with open(MANIFEST, encoding="utf-8") as _handle:
    TEXT = _handle.read()


def top_level_keys(text):
    return [m.group(1) for m in re.finditer(r"^([A-Za-z_][A-Za-z0-9_]*):", text, re.MULTILINE)]


def scalar(text, key):
    """The unquoted value of a top-level scalar key, or None when the key is absent or has a block value."""
    match = re.search(r"^{}:[ \t]*(.*)$".format(re.escape(key)), text, re.MULTILINE)
    if not match:
        return None
    value = match.group(1).strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value


def block(text, key):
    """Indented, non-comment lines that belong to a top-level key, up to the next top-level key."""
    lines = []
    inside = False
    for line in text.splitlines():
        if re.match(r"^[A-Za-z_]", line):
            inside = line.startswith(key + ":")
            continue
        if inside and line.strip() and not line.lstrip().startswith("#"):
            lines.append(line)
    return lines


def list_items(text, key):
    """Items of a top-level list key written as '  - item' lines."""
    return [line.strip()[2:].strip() for line in block(text, key) if line.strip().startswith("- ")]


def optional_env_entries(text):
    """Each optional_env entry as a dict with name and description."""
    entries = []
    for line in block(text, "optional_env"):
        stripped = line.strip()
        name = re.match(r"^- name:\s*(\S+)", stripped)
        if name:
            entries.append({"name": name.group(1)})
            continue
        description = re.match(r"^description:\s*\"?(.*?)\"?$", stripped)
        if description and entries:
            entries[-1]["description"] = description.group(1)
    return entries


class ManifestTests(unittest.TestCase):
    def test_required_top_level_keys_are_present(self):
        required = {
            "name", "label", "kind", "version", "manifest_version", "requires_hermes", "author",
            "description", "provides_tools", "requires_env", "optional_env",
        }
        keys = set(top_level_keys(TEXT))
        self.assertEqual(required - keys, set(), "every required key must be present")

    def test_identity_fields_match_the_plugin(self):
        self.assertEqual(scalar(TEXT, "name"), "tmux-share")
        self.assertEqual(scalar(TEXT, "label"), "tmux-share transcript")
        self.assertEqual(scalar(TEXT, "kind"), "tool")
        self.assertEqual(scalar(TEXT, "version"), "0.1.0")
        self.assertEqual(scalar(TEXT, "manifest_version"), "2")
        self.assertEqual(scalar(TEXT, "author"), "Patrick")

    def test_requires_hermes_is_present_and_pinned(self):
        self.assertEqual(scalar(TEXT, "requires_hermes"), ">=0.21.3")

    def test_description_says_it_is_read_only_and_uncontrollable(self):
        description = " ".join(line.strip() for line in block(TEXT, "description"))
        self.assertIn("Reads a root-owned tmux transcript that the agent has no way to control.", description,
                      "the description must say plainly what the plugin is")

    def test_provides_tools_lists_exactly_the_three_tools(self):
        self.assertEqual(
            sorted(list_items(TEXT, "provides_tools")),
            sorted(["tmux_share_status", "tmux_share_tail", "tmux_share_read"]),
            "provides_tools must list exactly the three tools and nothing else")

    def test_requires_env_is_empty(self):
        self.assertEqual(scalar(TEXT, "requires_env"), "[]", "requires_env must be an empty list")
        self.assertEqual(list_items(TEXT, "requires_env"), [], "requires_env must have no items")

    def test_optional_env_names_the_two_overrides_with_descriptions(self):
        entries = optional_env_entries(TEXT)
        self.assertEqual(sorted(entry["name"] for entry in entries), ["TMUX_SHARE_LOG", "TMUX_SHARE_SOCK"],
                         "optional_env must name exactly the two overrides")
        for entry in entries:
            with self.subTest(name=entry["name"]):
                self.assertTrue(entry.get("description"), "every optional variable needs a description")


if __name__ == "__main__":
    unittest.main(verbosity=2)
