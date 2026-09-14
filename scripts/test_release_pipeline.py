#!/usr/bin/env python3
"""Offline release regressions. Fixture directories are retained for inspection.

These tests exercise release tooling with fake build/download commands; they do
not replace the macOS compiler, XCTest, Go tests, or on-device verification.
"""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("cut_release", ROOT / "scripts/cut-release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


def fixture():
    return Path(tempfile.mkdtemp(prefix="olcos-release-test-"))


def executable(path, content):
    path.write_text(content)
    path.chmod(0o755)


def bundle(app, version="1.0", build="1", extension=True):
    entries = [(app, "olcrtc-ios", "io.github.hotelk52339.olcrtc-ios")]
    if extension:
        entries.append((app / "PlugIns/olcrtc-tunnel.appex", "olcrtc-tunnel",
                        "io.github.hotelk52339.olcrtc-ios.tunnel"))
    for folder, binary, identifier in entries:
        folder.mkdir(parents=True, exist_ok=True)
        (folder / binary).write_bytes(b"mock executable, not an iOS binary")
        with (folder / "Info.plist").open("wb") as stream:
            plistlib.dump({
                "CFBundleIdentifier": identifier, "CFBundleExecutable": binary,
                "CFBundleShortVersionString": version, "CFBundleVersion": build,
            }, stream)


class PublicVersionTests(unittest.TestCase):
    def test_first_public_release(self):
        self.assertEqual(release.release_tag("1.0", "1"), "v1.0.1")
        release.validate_tag("v1.0.1", "1.0", "1")

    def test_optional_patch_version(self):
        release.validate_tag("v1.2.3.4", "1.2.3", "4")

    def test_reject_malformed_versions_and_builds(self):
        for version, build in [("01.0", "1"), ("1", "1"), ("1.0-beta", "1"),
                               ("1.0", "0"), ("1.0", "-1"), ("1.0", "01"),
                               ("1.0\n", "1"), ("1.0", "$(false)")]:
            with self.subTest(version=version, build=build), self.assertRaises(ValueError):
                release.release_tag(version, build)

    def test_reject_mismatched_and_injected_tags(self):
        for tag in ("v1.0.282", "v1.0.2", "refs/heads/main", "--help",
                    "v1.0.1\n", "v1.0.1;exit 0", "v01.0.1"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.validate_tag(tag, "1.0", "1")

    def test_project_scalars(self):
        project = fixture() / "project.yml"
        project.write_text('settings:\n  MARKETING_VERSION: "1.0"\n  CURRENT_PROJECT_VERSION: "1" # shared\n')
        self.assertEqual(release.project_version(project), ("1.0", "1"))

    def test_missing_and_ambiguous_settings_fail(self):
        project = fixture() / "project.yml"
        for text in ('MARKETING_VERSION: "1.0"\n',
                     'MARKETING_VERSION: "1.0"\nMARKETING_VERSION: "1.1"\nCURRENT_PROJECT_VERSION: "1"\n'):
            project.write_text(text)
            with self.assertRaises(ValueError):
                release.project_version(project)

    def test_planner_is_read_only_without_private_state(self):
        with patch.object(release, "project_version", return_value=("1.0", "1")):
            with patch("builtins.print"):
                self.assertEqual(release.main(["--version", "1.0", "--build", "1", "--dry-run"]), 0)
        text = (ROOT / "scripts/cut-release.py").read_text()
        self.assertNotIn("subprocess", text)
        self.assertNotIn("released-task-ids", text)
        self.assertNotIn("BACKLOG", text)

    def test_explicit_version_cannot_override_project(self):
        with patch.object(release, "project_version", return_value=("1.0", "1")):
            for args in (["--version", "1.1"], ["--build", "282"]):
                with self.subTest(args=args), self.assertRaises(SystemExit) as error:
                    release.main(args)
                self.assertEqual(error.exception.code, 1)


class BundleValidationTests(unittest.TestCase):
    def setUp(self):
        self.app = fixture() / "olcrtc-ios.app"
        bundle(self.app)

    def change(self, folder, key, value):
        path = folder / "Info.plist"
        info = plistlib.loads(path.read_bytes())
        info[key] = value
        path.write_bytes(plistlib.dumps(info))

    def test_app_and_extension_match(self):
        release.validate_bundle(self.app, "1.0", "1")

    def test_extension_version_drift_fails(self):
        self.change(self.app / "PlugIns/olcrtc-tunnel.appex", "CFBundleVersion", "2")
        with self.assertRaises(ValueError):
            release.validate_bundle(self.app, "1.0", "1")

    def test_app_version_drift_fails(self):
        self.change(self.app, "CFBundleShortVersionString", "1.3")
        with self.assertRaises(ValueError):
            release.validate_bundle(self.app, "1.0", "1")

    def test_native_bundle_id_cannot_change(self):
        self.change(self.app, "CFBundleIdentifier", "io.github.hotelk52339.olcos-ios")
        with self.assertRaises(ValueError):
            release.validate_bundle(self.app, "1.0", "1")

    def test_missing_binary_fails(self):
        self.change(self.app, "CFBundleExecutable", "missing")
        with self.assertRaises(ValueError):
            release.validate_bundle(self.app, "1.0", "1")

    def test_provisioned_bundle_fails(self):
        (self.app / "embedded.mobileprovision").write_text("not unsigned")
        with self.assertRaises(ValueError):
            release.validate_bundle(self.app, "1.0", "1")


class ShellFixture(unittest.TestCase):
    def setUp(self):
        self.root = fixture()
        (self.root / "scripts/mobile-shim").mkdir(parents=True)
        (self.root / "gomobile").mkdir()
        (self.root / "olcrtc-upstream").mkdir()
        (self.root / "App/Mobile.xcframework").mkdir(parents=True)
        (self.root / "App/Mobile.xcframework/keep").write_text("existing framework")
        for name in ("fetch-framework.sh", "build-framework.sh", "package-ipa.sh", "cut-release.py"):
            shutil.copy2(ROOT / "scripts" / name, self.root / "scripts" / name)
        (self.root / "project.yml").write_text('MARKETING_VERSION: "1.0"\nCURRENT_PROJECT_VERSION: "1"\n')
        (self.root / "gomobile/go.mod").write_text("module test\ngo 1.26.3\n")
        (self.root / "gomobile/local.go").write_text("package test\n")
        (self.root / "scripts/mobile-shim/shim.go").write_text("package shim\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", MOCK_UPSTREAM="a" * 40)
        executable(self.bin / "git", """#!/usr/bin/env python3
import os, sys
if "rev-parse" in sys.argv:
    print(os.environ["MOCK_UPSTREAM"])
elif "ls-files" in sys.argv:
    print(os.environ.get("MOCK_TRACKED_SUM", ""), end="")
else:
    raise SystemExit("unexpected git invocation")
""")

    def run_script(self, name, *args):
        return subprocess.run(["bash", str(self.root / "scripts" / name), *args],
                              cwd=self.root, env=self.env, text=True, capture_output=True)

    def key(self):
        result = self.run_script("fetch-framework.sh", "--cache-key")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout.strip(), r"^[a-f0-9]{64}$")
        return result.stdout.strip()


class FrameworkFingerprintTests(ShellFixture):
    def test_key_is_stable(self):
        self.assertEqual(self.key(), self.key())

    def test_upstream_pin_invalidates(self):
        before = self.key()
        self.env["MOCK_UPSTREAM"] = "b" * 40
        self.assertNotEqual(before, self.key())

    def test_local_inputs_invalidate(self):
        for relative in ("gomobile/go.mod", "gomobile/local.go",
                         "scripts/mobile-shim/shim.go", "scripts/build-framework.sh"):
            with self.subTest(relative=relative):
                before = self.key()
                with (self.root / relative).open("a") as stream:
                    stream.write("\n// changed\n")
                self.assertNotEqual(before, self.key())

    def test_generated_sum_does_not_thrash_cache(self):
        before = self.key()
        (self.root / "gomobile/go.sum").write_text("generated\n")
        self.assertEqual(before, self.key())

    def test_committed_sum_is_counted(self):
        before = self.key()
        (self.root / "gomobile/go.sum").write_text("locked\n")
        self.env["MOCK_TRACKED_SUM"] = "gomobile/go.sum\n"
        self.assertNotEqual(before, self.key())


class FrameworkFetchTests(ShellFixture):
    def assets(self, key=None, corrupt=False, unsafe=False):
        folder = self.root / "downloads"
        folder.mkdir()
        with zipfile.ZipFile(folder / "Mobile.xcframework.zip", "w") as archive:
            archive.writestr("Mobile.xcframework/Info.plist", plistlib.dumps({"AvailableLibraries": []}))
            archive.writestr("Mobile.xcframework/test-binary", b"fixture")
            if unsafe:
                archive.writestr("../escape", b"bad")
        (folder / "framework-provenance.json").write_text(json.dumps({"input_sha256": key or self.key()}))
        (folder / "SHA256SUMS").write_text("".join(
            f"{hashlib.sha256((folder / name).read_bytes()).hexdigest()}  {name}\n"
            for name in ("Mobile.xcframework.zip", "framework-provenance.json")))
        if corrupt:
            with (folder / "Mobile.xcframework.zip").open("ab") as stream:
                stream.write(b"corruption")
        self.env["MOCK_DOWNLOADS"] = str(folder)
        self.env["MOCK_GH_LOG"] = str(self.root / "gh.json")
        executable(self.bin / "gh", """#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
args = sys.argv[1:]
pathlib.Path(os.environ["MOCK_GH_LOG"]).write_text(json.dumps(args))
target = pathlib.Path(args[args.index("--dir") + 1])
for path in pathlib.Path(os.environ["MOCK_DOWNLOADS"]).iterdir():
    shutil.copy2(path, target / path.name)
""")

    def test_matching_verified_download_and_default_repository(self):
        self.assets()
        result = self.run_script("fetch-framework.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "App/Mobile.xcframework/test-binary").is_file())
        args = json.loads((self.root / "gh.json").read_text())
        self.assertIn("v1.0.1", args)
        self.assertIn("Hotelk52339/olcos-ios", args)

    def test_checksum_failure_keeps_existing_framework(self):
        self.assets(corrupt=True)
        result = self.run_script("fetch-framework.sh", "v1.0.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / "App/Mobile.xcframework/keep").is_file())

    def test_input_mismatch_keeps_existing_framework(self):
        self.assets(key="0" * 64)
        result = self.run_script("fetch-framework.sh", "v1.0.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / "App/Mobile.xcframework/keep").is_file())

    def test_unsafe_archive_keeps_existing_framework(self):
        self.assets(unsafe=True)
        result = self.run_script("fetch-framework.sh", "v1.0.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / "App/Mobile.xcframework/keep").is_file())


class PackagingTests(ShellFixture):
    def setUp(self):
        super().setUp()
        executable(self.bin / "xcodegen", "#!/usr/bin/env bash\nexit 0\n")
        executable(self.bin / "xcodebuild",
                   '#!/usr/bin/env bash\necho "mock device build"\nexit "${MOCK_XCODE_EXIT:-0}"\n')
        self.app = self.root / "build/device/Build/Products/Release-iphoneos/olcrtc-ios.app"

    def test_unsigned_asset_contains_native_app_and_extension(self):
        bundle(self.app)
        result = self.run_script("package-ipa.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        with zipfile.ZipFile(self.root / "olcos-ios-unsigned.ipa") as archive:
            self.assertIn("Payload/olcrtc-ios.app/Info.plist", archive.namelist())
            self.assertIn("Payload/olcrtc-ios.app/PlugIns/olcrtc-tunnel.appex/Info.plist", archive.namelist())

    def test_build_failure_is_not_hidden_by_tee(self):
        bundle(self.app)
        (self.root / "olcos-ios-unsigned.ipa").write_bytes(b"stale")
        self.env["MOCK_XCODE_EXIT"] = "65"
        result = self.run_script("package-ipa.sh")
        self.assertEqual(result.returncode, 65)
        self.assertFalse((self.root / "olcos-ios-unsigned.ipa").exists())
        self.assertIn("mock device build", (self.root / "build/logs/device-build.log").read_text())

    def test_missing_extension_never_packages(self):
        bundle(self.app, extension=False)
        result = self.run_script("package-ipa.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "olcos-ios-unsigned.ipa").exists())

    def test_missing_framework_removes_stale_asset(self):
        (self.root / "olcos-ios-unsigned.ipa").write_bytes(b"stale")
        (self.root / "App/Mobile.xcframework").rename(self.root / "saved-framework")
        result = self.run_script("package-ipa.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "olcos-ios-unsigned.ipa").exists())

    def test_existing_payload_directory_is_untouched(self):
        bundle(self.app)
        (self.root / "Payload").mkdir()
        (self.root / "Payload/keep").write_text("caller-owned")
        result = self.run_script("package-ipa.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "Payload/keep").read_text(), "caller-owned")


class WorkflowSafetyTests(unittest.TestCase):
    def setUp(self):
        self.ci = (ROOT / ".github/workflows/ci.yml").read_text()
        self.build = (ROOT / ".github/workflows/build.yml").read_text()
        self.publish = (ROOT / ".github/workflows/release.yml").read_text()

    def test_ci_and_release_use_identical_build_definition(self):
        for text in (self.ci, self.publish):
            self.assertIn("uses: ./.github/workflows/build.yml", text)
        self.assertEqual(self.build.count("uses: actions/cache/restore@"), 1)
        self.assertEqual(self.build.count("uses: actions/cache/save@"), 1)
        self.assertIn("bash scripts/fetch-framework.sh --cache-key", self.build)
        self.assertNotIn("restore-keys:", self.build)

    def test_validated_framework_saved_before_native_build(self):
        check = self.build.index("- name: Check device and simulator framework slices")
        save = self.build.index("- name: Save validated framework before native build")
        native = self.build.index("- name: Build and run XCTest")
        self.assertLess(check, save)
        self.assertLess(save, native)
        self.assertIn("key: ${{ steps.fwcache.outputs.cache-primary-key }}", self.build)

    def test_native_resource_limits_keep_failure_evidence(self):
        self.assertIn("-jobs 2", self.build)
        self.assertIn("-parallel-testing-enabled NO", self.build)
        self.assertIn("-maximum-concurrent-test-simulator-destinations 1", self.build)
        self.assertIn("-test-timeouts-enabled YES", self.build)
        self.assertIn("-default-test-execution-time-allowance 60", self.build)
        self.assertIn("-maximum-test-execution-time-allowance 120", self.build)
        self.assertIn("timeout-minutes: 30", self.build)
        self.assertIn("xctest-resources.log", self.build)
        self.assertIn("-resultBundlePath build/tests.xcresult", self.build)
        self.assertIn("2>&1 | tee build/logs/xctest.log", self.build)
        self.assertIn("-jobs 2", (ROOT / "scripts/package-ipa.sh").read_text())

    def test_temporary_branch_and_manual_triggers(self):
        self.assertIn("'release/olcos-*'", self.ci)
        self.assertIn("workflow_dispatch:", self.ci)
        self.assertIn("workflow_dispatch:", self.publish)

    def test_all_gates_precede_unsigned_upload(self):
        upload = self.build.index("- name: Upload tested unsigned IPA")
        for command in ("discover -s Tests -p 'test_*.py'", "discover -s scripts -p 'test_*.py'", "parity_check.py",
                        "go test -count=1", "xcodegen generate", "xcodebuild test",
                        "bash scripts/package-ipa.sh"):
            self.assertLess(self.build.index(command), upload)
        self.assertNotIn("continue-on-error", self.build)

    def test_release_publishing_requires_build_success_and_new_repository(self):
        self.assertIn("needs: [validate, build-test, lint]", self.publish)
        self.assertIn("github.repository == 'Hotelk52339/olcos-ios'", self.publish)
        self.assertNotIn("--clobber", self.publish)
        self.assertIn("--verify-tag --draft", self.publish)
        self.assertLess(self.publish.index("uploaded asset size mismatch"),
                        self.publish.index("--draft=false"))

    def test_release_lint_matches_ci_and_checks_immutable_commit(self):
        ci_lint = self.ci.split("\n  lint:\n", 1)[1]
        release_lint = self.publish.split("\n  lint:\n", 1)[1].split("\n  publish:\n", 1)[0]
        self.assertIn("needs: validate", release_lint)
        self.assertIn("ref: ${{ needs.validate.outputs.commit }}", release_lint)
        self.assertIn("persist-credentials: false", release_lint)
        self.assertIn("runs-on: macos-15", release_lint)
        self.assertIn("timeout-minutes: 15", release_lint)
        self.assertNotIn("continue-on-error", release_lint)
        self.assertNotIn("contents: write", release_lint)
        self.assertEqual(ci_lint.split("run: |\n", 1)[1].strip(),
                         release_lint.split("run: |\n", 1)[1].strip())

    def test_linux_source_gates_precede_macos_build(self):
        source, native = self.build.split("\n  build:\n", 1)
        self.assertIn("source-tests:", source)
        self.assertIn("runs-on: ubuntu-latest", source)
        self.assertIn("submodules: recursive", source)
        self.assertIn("scripts/parity_check.py", source)
        self.assertIn('scripts/cut-release.py --check-tag "$RELEASE_TAG"', source)
        self.assertIn("needs: source-tests", native)
        self.assertIn("runs-on: macos-15", native)
        self.assertNotIn("unittest discover", native)
        self.assertIn("go test -count=1", native)
        self.assertIn("xcodebuild test", native)

    def test_failure_evidence_and_generated_plists_preserved(self):
        self.assertIn("build/*.xcresult", self.build)
        self.assertIn("build/logs/", self.build)
        self.assertIn("steps.generate.outcome == 'success'", self.build)
        self.assertIn("App/Info.plist", self.build)
        self.assertIn("Tunnel/Info.plist", self.build)
        self.assertIn("if: always()", self.build)

    def test_no_signing_secrets_or_long_lived_checkout_credentials(self):
        for text in (self.ci, self.build, self.publish):
            self.assertNotIn("secrets.", text)
            self.assertIn("persist-credentials: false", text)
            self.assertIn("timeout-minutes:", text)
        # Simulator tests retain Xcode's normal ad-hoc signing for Keychain
        # access. Only the distributable device IPA disables code signing.
        self.assertNotIn("CODE_SIGNING_ALLOWED=NO", self.build)
        self.assertNotIn("CODE_SIGNING_REQUIRED=NO", self.build)
        self.assertNotIn('CODE_SIGN_IDENTITY=""', self.build)
        package = (ROOT / "scripts/package-ipa.sh").read_text()
        self.assertIn("CODE_SIGNING_ALLOWED=NO", package)
        self.assertIn("CODE_SIGNING_REQUIRED=NO", package)
        self.assertIn('CODE_SIGN_IDENTITY=""', package)
        self.assertIn("cancel-in-progress: false", self.publish)


if __name__ == "__main__":
    unittest.main()
