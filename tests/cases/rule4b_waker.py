#!/usr/bin/env python3
"""The python half of the rule 4b parity test, run offline.

Imports waker/github.py unmodified (PYTHONPATH=<repo>/waker) and replaces its
only two GitHub reads -- `_contents` and `_backlog_files` -- with readers over
tests/fixtures/rule4b/<case>/, the same tree the bash half is fed. Everything
that decides the outcome (the epic line parse, the state.json parse, the stage
check, the approval lookup, the file-set comparison, `_safe_field`) is the real
code.

Usage:
  rule4b_waker.py reason_many     <fixtures-root> <out-dir> <repo> <prefix> <slug>
  rule4b_waker.py safe_field_many <limit> <value> [<limit> <value> ...]

reason_many writes, for every fixture directory, `<out-dir>/<case>.reason` (the
decline reason, empty when the backlog is approved, never a trailing newline)
and `<out-dir>/<case>.log` (one `GET ref=<ref> path=<path>` line per read, so
the caller can check that both halves asked GitHub for the same things).
safe_field_many prints one scrubbed value per line; a scrubbed value can never
contain a newline.

Batched on purpose: one interpreter start per case file instead of one per case.
"""

import json
import os
import sys

import github

_FIXTURE = ""
_LOG = None


def _log(ref, path):
    if _LOG is not None:
        _LOG.write(f"GET ref={ref} path={path}\n")


def _fixture_contents(_token, _repo, ref, path):
    """Stands in for github._contents: a file body, or None for a 404."""
    _log(ref, path)
    disk = os.path.join(_FIXTURE, "contents", path)
    if not os.path.isfile(disk):
        return None
    with open(disk, "rb") as handle:
        return handle.read().decode("utf-8", errors="replace")


def _fixture_backlog_files(_token, _repo, ref, path):
    """Stands in for github._backlog_files: {name: blob sha}, or None for a 404.

    Applies the same entry filter as the real function so the fixture listing is
    interpreted identically on both sides.
    """
    _log(ref, path)
    disk = os.path.join(_FIXTURE, "listings", path + ".json")
    if not os.path.isfile(disk):
        return None
    with open(disk, "rb") as handle:
        body = json.loads(handle.read())
    if not isinstance(body, list):
        return None
    return {
        entry["name"]: entry["sha"]
        for entry in body
        if isinstance(entry, dict)
        and entry.get("type") == "file"
        and entry.get("name")
        and entry.get("sha")
    }


def reason_many(fixtures_root, out_dir, repo, prefix, slug):
    global _FIXTURE, _LOG
    github._contents = _fixture_contents
    github._backlog_files = _fixture_backlog_files
    cases = sorted(
        name
        for name in os.listdir(fixtures_root)
        if os.path.isdir(os.path.join(fixtures_root, name))
    )
    if not cases:
        sys.stderr.write(f"no fixture directories under {fixtures_root}\n")
        return 3
    for case in cases:
        _FIXTURE = os.path.join(fixtures_root, case)
        with open(os.path.join(out_dir, f"{case}.log"), "w", encoding="utf-8") as log:
            _LOG = log
            reason = github.backlog_decline_reason("fixture-token", repo, prefix, slug)
        _LOG = None
        with open(
            os.path.join(out_dir, f"{case}.reason"), "w", encoding="utf-8"
        ) as handle:
            handle.write("" if reason is None else reason)
    return 0


def main(argv):
    if len(argv) == 7 and argv[1] == "reason_many":
        if not os.path.isdir(argv[2]) or not os.path.isdir(argv[3]):
            sys.stderr.write(f"no such directory: {argv[2]} or {argv[3]}\n")
            return 3
        return reason_many(argv[2], argv[3], argv[4], argv[5], argv[6])
    if len(argv) >= 4 and argv[1] == "safe_field_many" and len(argv) % 2 == 0:
        for index in range(2, len(argv), 2):
            sys.stdout.write(
                github._safe_field(argv[index + 1], int(argv[index])) + "\n"
            )
        return 0
    sys.stderr.write(
        f"usage: {argv[0]} reason_many <fixtures-root> <out-dir> <repo> <prefix> <slug>\n"
        f"       {argv[0]} safe_field_many <limit> <value> [<limit> <value> ...]\n"
    )
    return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))
