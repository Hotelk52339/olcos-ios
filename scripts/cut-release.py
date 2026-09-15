#!/usr/bin/env python3
"""Plan an olcOS public release or validate its tag/built bundles (stdlib only).

This helper never edits files, creates tags, pushes, or reads a private ledger.
Version/build are authoritative in project.yml; optional explicit values must
match. The maintainer owns tagging/publishing after reviewing macOS CI.

  python3 scripts/cut-release.py --version 2.0 --build 2 --dry-run
  python3 scripts/cut-release.py --check-tag v2.0.2
  python3 scripts/cut-release.py --check-bundle build/device/Build/Products/Release-iphoneos/olcrtc-ios.app
"""

import argparse
import plistlib
import re
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PROJECT = REPO / "project.yml"
VERSION_RE = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*))?"
BUILD_RE = r"[1-9][0-9]*"
TAG_RE = rf"v{VERSION_RE}\.{BUILD_RE}"


def project_version(project: Path = PROJECT) -> tuple[str, str]:
    """Read the two simple scalar settings without introducing a YAML dependency."""
    text = project.read_text(encoding="utf-8")
    values = []
    for key, pattern in (
        ("MARKETING_VERSION", VERSION_RE),
        ("CURRENT_PROJECT_VERSION", BUILD_RE),
    ):
        matches = re.findall(
            rf"^\s*{key}:\s*[\"']?({pattern})[\"']?\s*(?:#.*)?$",
            text, re.MULTILINE,
        )
        if len(matches) != 1:
            raise ValueError(f"expected exactly one valid {key} in {project}")
        values.append(matches[0])
    return values[0], values[1]


def release_tag(version: str, build: str) -> str:
    if not re.fullmatch(VERSION_RE, version) or not re.fullmatch(BUILD_RE, build):
        raise ValueError("version must be numeric X.Y[.Z] and build a positive integer")
    return f"v{version}.{build}"


def validate_tag(tag: str, version: str, build: str) -> None:
    expected = release_tag(version, build)
    if not re.fullmatch(TAG_RE, tag) or tag != expected:
        raise ValueError(f"tag must match project.yml exactly: {expected}")


def validate_bundle(app: Path, version: str, build: str) -> None:
    for bundle, identifier in (
        (app, "io.github.hotelk52339.olcrtc-ios"),
        (app / "PlugIns/olcrtc-tunnel.appex", "io.github.hotelk52339.olcrtc-ios.tunnel"),
    ):
        with (bundle / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        for key, expected in (
            ("CFBundleIdentifier", identifier),
            ("CFBundleShortVersionString", version),
            ("CFBundleVersion", build),
        ):
            if info.get(key) != expected:
                raise ValueError(f"{bundle}: {key} must be {expected!r}, got {info.get(key)!r}")
        executable = info.get("CFBundleExecutable", "")
        if not executable or Path(executable).name != executable or not (bundle / executable).is_file():
            raise ValueError(f"{bundle}: missing bundle executable")
        if (bundle / "_CodeSignature").exists() or (bundle / "embedded.mobileprovision").exists():
            raise ValueError(f"{bundle}: expected an unsigned bundle without provisioning")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", help="expected public marketing version (e.g. 1.0)")
    parser.add_argument("--build", help="expected public build number (e.g. 1)")
    parser.add_argument("--check-tag", help="fail unless this tag matches project.yml")
    parser.add_argument("--check-bundle", type=Path, help="validate built device app and tunnel")
    parser.add_argument("--dry-run", action="store_true", help="explicit read-only preview (also the default)")
    parser.add_argument("-m", "--message", default="", help="public release notes; never a private task ledger")
    args = parser.parse_args(argv)
    try:
        version, build = project_version()
        if args.version is not None and args.version != version:
            raise ValueError(f"--version must match project.yml ({version})")
        if args.build is not None and args.build != build:
            raise ValueError(f"--build must match project.yml ({build})")
        tag = release_tag(version, build)
        if args.check_tag:
            validate_tag(args.check_tag, version, build)
        if args.check_bundle:
            validate_bundle(args.check_bundle, version, build)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"error: {error}\n")
    print(f"tag: {tag}")
    print(f"title: olcOS {version} ({build})")
    if args.message.strip():
        print(args.message.strip())
    print("Read-only plan/validation. No tag, push, release, or test-success claim was made.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
