#!/usr/bin/env python3
"""Concurrency-safe helper for L10n keys (App/Localization/*.swift).

Several people (or agents) edit UI in parallel; every UI change needs a new
L10n case plus EN/RU/FR entries in three files. Hand-editing those files
concurrently loses writes. This script takes a lock, does read-modify-write
and releases the lock, so concurrent invocations serialize.

Usage:
  l10n.py add KEY --en "English" --ru "Русский" --fr "Français"
  l10n.py set KEY [--en ...] [--ru ...] [--fr ...]      # update existing values
  l10n.py remove KEY [KEY ...]
  l10n.py get KEY
  l10n.py check                                         # every case has EN/RU/FR

Values are inserted verbatim inside Swift double quotes; pass already-escaped
text if you need a literal quote or backslash (\\" and \\\\).
"""
from __future__ import annotations

import argparse
import fcntl
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOC = ROOT / "App" / "Localization"
ENUM_FILE = LOC / "L10n.swift"
TABLE_FILE = LOC / "L10nTable.swift"
FRENCH_FILE = LOC / "L10nFrench.swift"
LOCK_FILE = LOC / ".l10n.lock"

STRING = r'"(?:\\.|[^"\\])*"'
IDENT = r"[A-Za-z_][A-Za-z0-9_]*"


class Locked:
    def __enter__(self):
        self.fh = open(LOCK_FILE, "w")
        fcntl.flock(self.fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.fh, fcntl.LOCK_UN)
        self.fh.close()


def read(p: Path) -> list[str]:
    return p.read_text(encoding="utf-8").splitlines(keepends=True)


def write(p: Path, lines: list[str]) -> None:
    p.write_text("".join(lines), encoding="utf-8")


def enum_cases(lines: list[str]) -> set[str]:
    out: set[str] = set()
    inside = False
    for ln in lines:
        if ln.startswith("enum L10n"):
            inside = True
            continue
        if inside and ln.rstrip("\n") == "}":
            break
        if inside:
            m = re.match(r"\s*case\s+(.*)", ln)
            if m:
                body = re.sub(r"//.*", "", m.group(1))
                for tok in body.split(","):
                    tok = tok.strip()
                    if re.fullmatch(IDENT, tok):
                        out.add(tok)
    return out


def dict_span(lines: list[str], name: str) -> tuple[int, int]:
    start = next(i for i, ln in enumerate(lines) if re.match(rf"\s*static let {name}: \[L10n: String\] = \[", ln))
    end = next(i for i in range(start + 1, len(lines)) if lines[i].rstrip("\n") == "    ]")
    return start, end


def dict_keys(lines: list[str], name: str) -> dict[str, int]:
    s, e = dict_span(lines, name)
    keys: dict[str, int] = {}
    for i in range(s + 1, e):
        m = re.match(rf"\s*\.({IDENT})\s*:\s*{STRING}", lines[i])
        if m:
            keys[m.group(1)] = i
    return keys


def enum_end(lines: list[str]) -> int:
    start = next(i for i, ln in enumerate(lines) if ln.startswith("enum L10n"))
    return next(i for i in range(start + 1, len(lines)) if lines[i].rstrip("\n") == "}")


def cmd_add(a) -> int:
    if not re.fullmatch(IDENT, a.key):
        sys.exit(f"bad key {a.key!r}")
    if not (a.en and a.ru and a.fr):
        sys.exit("add requires --en, --ru and --fr")
    with Locked():
        enum = read(ENUM_FILE)
        if a.key in enum_cases(enum):
            sys.exit(f"{a.key} already exists (use set)")
        enum.insert(enum_end(enum), f"    case {a.key}\n")
        write(ENUM_FILE, enum)
        table = read(TABLE_FILE)
        for name, val in (("english", a.en), ("russian", a.ru)):
            _, e = dict_span(table, name)
            table.insert(e, f'        .{a.key}: "{val}",\n')
        write(TABLE_FILE, table)
        fr = read(FRENCH_FILE)
        _, e = dict_span(fr, "french")
        fr.insert(e, f'        .{a.key}: "{a.fr}",\n')
        write(FRENCH_FILE, fr)
    print(f"added {a.key}")
    return 0


def _set_in(lines: list[str], name: str, key: str, val: str) -> bool:
    keys = dict_keys(lines, name)
    if key not in keys:
        return False
    i = keys[key]
    lines[i] = re.sub(rf"(\.{key}\s*:\s*){STRING}", lambda m: f'{m.group(1)}"{val}"', lines[i], count=1)
    return True


def cmd_set(a) -> int:
    with Locked():
        enum = read(ENUM_FILE)
        if a.key not in enum_cases(enum):
            sys.exit(f"{a.key} does not exist (use add)")
        table = read(TABLE_FILE)
        fr = read(FRENCH_FILE)
        for name, val, lines in (("english", a.en, table), ("russian", a.ru, table), ("french", a.fr, fr)):
            if val is None:
                continue
            if not _set_in(lines, name, a.key, val):
                s, e = dict_span(lines, name)
                lines.insert(e, f'        .{a.key}: "{val}",\n')
        write(TABLE_FILE, table)
        write(FRENCH_FILE, fr)
    print(f"set {a.key}")
    return 0


def _remove_case(lines: list[str], key: str) -> None:
    end = enum_end(lines)
    for i in range(end):
        m = re.match(r"(\s*case\s+)(.*?)(\s*//.*)?\n?$", lines[i])
        if not m:
            continue
        toks = [t.strip() for t in m.group(2).split(",")]
        if key not in toks:
            continue
        toks = [t for t in toks if t != key]
        if toks:
            lines[i] = f"{m.group(1)}{', '.join(toks)}{m.group(3) or ''}\n"
        else:
            del lines[i]
        return


def cmd_remove(a) -> int:
    with Locked():
        enum = read(ENUM_FILE)
        table = read(TABLE_FILE)
        fr = read(FRENCH_FILE)
        for key in a.keys:
            _remove_case(enum, key)
            for name, lines in (("english", table), ("russian", table), ("french", fr)):
                keys = dict_keys(lines, name)
                if key in keys:
                    del lines[keys[key]]
        write(ENUM_FILE, enum)
        write(TABLE_FILE, table)
        write(FRENCH_FILE, fr)
    print(f"removed {' '.join(a.keys)}")
    return 0


def cmd_get(a) -> int:
    table = read(TABLE_FILE)
    fr = read(FRENCH_FILE)
    for name, lines in (("english", table), ("russian", table), ("french", fr)):
        keys = dict_keys(lines, name)
        print(f"{name}: {lines[keys[a.key]].strip() if a.key in keys else '<missing>'}")
    return 0


def cmd_check(a) -> int:
    enum = read(ENUM_FILE)
    table = read(TABLE_FILE)
    fr = read(FRENCH_FILE)
    cases = enum_cases(enum)
    bad = 0
    for name, lines in (("english", table), ("russian", table), ("french", fr)):
        keys = set(dict_keys(lines, name))
        for k in sorted(cases - keys):
            print(f"{name}: missing .{k}")
            bad += 1
        for k in sorted(keys - cases):
            print(f"{name}: orphan .{k} (no enum case)")
            bad += 1
    # duplicate enum cases
    seen: dict[str, int] = {}
    for ln in enum:
        for tok in re.findall(rf"\bcase\s+([^/\n]+)", ln):
            for t in tok.split(","):
                t = t.strip()
                if re.fullmatch(IDENT, t):
                    seen[t] = seen.get(t, 0) + 1
    for k, n in seen.items():
        if n > 1:
            print(f"enum: duplicate case {k} x{n}")
            bad += 1
    print("OK" if not bad else f"{bad} problem(s)")
    return 1 if bad else 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("add"); s.add_argument("key"); s.add_argument("--en"); s.add_argument("--ru"); s.add_argument("--fr"); s.set_defaults(fn=cmd_add)
    s = sub.add_parser("set"); s.add_argument("key"); s.add_argument("--en"); s.add_argument("--ru"); s.add_argument("--fr"); s.set_defaults(fn=cmd_set)
    s = sub.add_parser("remove"); s.add_argument("keys", nargs="+"); s.set_defaults(fn=cmd_remove)
    s = sub.add_parser("get"); s.add_argument("key"); s.set_defaults(fn=cmd_get)
    s = sub.add_parser("check"); s.set_defaults(fn=cmd_check)
    a = p.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
