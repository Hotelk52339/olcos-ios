#!/usr/bin/env python3
"""#481: offline B1/B2/B4 regressions. No SSH, server, real podman/git or build.

Run: python3 scripts/test_ssh_audit_481.py
Fixtures are retained under the system temporary directory for inspection.
"""
# boc #481
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
OLD_KEY = "a" * 64
NEW_KEY = "b" * 64
BASE = "olcrtc-server-audit"
MOCK = r"""#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
state = json.loads(pathlib.Path(os.environ["MOCK_STATE"]).read_text())
with open(os.environ["MOCK_LOG"], "a") as out:
    out.write(json.dumps(args) + "\n")
if args[0] == "ps":
    print("\n".join(state["all"] if "-a" in args else state["running"]))
elif args[0] == "inspect":
    print(os.environ["MOCK_DEPLOY"])
elif args[0] == "restart":
    if args[1] in state.get("fail_restart", []):
        sys.exit(42)
elif args[0] == "run":
    if "--name" in args:
        name = args[args.index("--name") + 1]
        state["all"].append(name)
        state["running"].append(name)
        pathlib.Path(os.environ["MOCK_STATE"]).write_text(json.dumps(state))
elif args[0] not in ("rm", "logs"):
    raise SystemExit("unexpected mock command: " + repr(args))
"""


def yaml(provider, key=OLD_KEY):
    return (f'mode: srv\nauth:\n  provider: "{provider}"\nroom:\n  id: "audit-room"\n'
            f'crypto:\n  key: "{key}"\nnet:\n  transport: "datachannel"\n'
            '  dns: "77.88.8.8:53"\n')


class SSHScriptAudit481Tests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="olcrtc-ssh-481-"))
        self.deploy = self.directory / "deploy"
        self.deploy.mkdir()
        (self.deploy / ".git").mkdir()
        (self.deploy / "server.yaml").write_text(yaml("wbstream"))
        (self.deploy / "olcrtc").write_text("#!/bin/sh\nexit 0\n")
        (self.deploy / "olcrtc").chmod(0o700)
        self.home = self.directory / "home"
        self.home.mkdir()
        (self.home / ".olcrtc_key").write_text(OLD_KEY)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        for name, script in {
            "podman": MOCK, "git": "#!/bin/sh\nexit 0\n",
            "sleep": "#!/bin/sh\nexit 0\n",
            "openssl": f"#!/bin/sh\nprintf '%s\\n' '{NEW_KEY}'\n",
        }.items():
            executable = self.bin / name
            executable.write_text(script)
            executable.chmod(0o700)
        self.state = self.directory / "state.json"
        self.log = self.directory / "commands.jsonl"
        self.set_state([BASE], [BASE])
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        HOME=str(self.home), MOCK_STATE=str(self.state),
                        MOCK_LOG=str(self.log), MOCK_DEPLOY=str(self.deploy),
                        OLCRTC_BASE_CONTAINER=BASE, OLCRTC_CONTAINER=BASE,
                        OLCRTC_CARRIER="jitsi", OLCRTC_TRANSPORT="datachannel",
                        OLCRTC_ROOM_ID="https://meet.example/audit")

    def set_state(self, all_names, running, fail_restart=None):
        self.state.write_text(json.dumps({"all": all_names, "running": running,
                                         "fail_restart": fail_restart or []}))

    def run_script(self, script):
        return subprocess.run(["bash", str(script)], env=self.env, text=True,
                              capture_output=True, timeout=10)

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_update_restarts_running_sibling_but_not_stopped_or_unrelated(self):
        source = (ROOT / "App/Core/SSHRunner.swift").read_text()
        body = source.split("static func updateScript(", 1)[1].split('return #"""', 1)[1]
        body = body.split('"""#', 1)[0]
        for name, value in {"target": BASE, "containerNamePrefix": "olcrtc-server-",
                            "AppConstants.upstreamCorePin": "offline-pin",
                            "AppConstants.serverGoImage": "offline-image"}.items():
            body = body.replace("\\#(" + name + ")", value)
        self.assertNotIn("\\#(", body)
        script = self.directory / "update.sh"
        script.write_text(body)
        live, stopped, other = BASE + "-telemost", BASE + "-jitsi", "other-server"
        self.set_state([BASE, live, stopped, other], [BASE, live, other])
        result = self.run_script(script)
        self.assertEqual(result.returncode, 0, result.stderr)
        restarts = [cmd[1] for cmd in self.commands() if cmd[0] == "restart"]
        self.assertEqual(restarts, [BASE, live])
        self.assertIn("OLCRTC_UPDATED=ok", result.stdout)

    def assert_collision_preserved(self, existing_file, existing_container):
        sibling = self.deploy / "server-jitsi.yaml"
        original = yaml("telemost")
        if existing_file:
            sibling.write_text(original)
        if existing_container:
            self.set_state([BASE, BASE + "-jitsi"], [BASE, BASE + "-jitsi"])
        primary = (self.deploy / "server.yaml").read_bytes()
        result = self.run_script(ROOT / "scripts/add-carrier.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists; no changes made", result.stderr)
        self.assertFalse(any(cmd[0] in ("rm", "run", "restart") for cmd in self.commands()))
        self.assertEqual((self.deploy / "server.yaml").read_bytes(), primary)
        self.assertEqual((self.home / ".olcrtc_key").read_text(), OLD_KEY)
        if existing_file:
            self.assertEqual(sibling.read_text(), original)
        else:
            self.assertFalse(sibling.exists())

    def test_add_preserves_reconfigured_sibling(self):
        self.assert_collision_preserved(True, True)

    def test_add_preserves_orphan_yaml(self):
        self.assert_collision_preserved(True, False)

    def test_add_preserves_container_with_missing_yaml(self):
        self.assert_collision_preserved(False, True)

    def test_add_preserves_dangling_symlink(self):
        sibling = self.deploy / "server-jitsi.yaml"
        sibling.symlink_to(self.deploy / "missing")
        result = self.run_script(ROOT / "scripts/add-carrier.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(sibling.is_symlink())
        self.assertFalse((self.deploy / "missing").exists())
        self.assertFalse(any(cmd[0] in ("rm", "run") for cmd in self.commands()))

    def test_add_empty_slot_still_succeeds(self):
        result = self.run_script(ROOT / "scripts/add-carrier.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("OLCRTC_CARRIER_ADDED=ok", result.stdout)
        self.assertIn(f"OLCRTC_CONTAINER={BASE}-jitsi", result.stdout)
        self.assertIn(OLD_KEY, (self.deploy / "server-jitsi.yaml").read_text())

    def test_rotate_failed_primary_restart_reports_new_key_and_continues_siblings(self):
        live, stopped = BASE + "-telemost", BASE + "-jitsi"
        (self.deploy / "server-telemost.yaml").write_text(yaml("telemost"))
        (self.deploy / "server-jitsi.yaml").write_text(yaml("jitsi"))
        self.set_state([BASE, live, stopped], [BASE, live], [BASE, live])
        result = self.run_script(ROOT / "scripts/rotate-key.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"[!] {BASE} restart failed", result.stdout)
        self.assertIn(f"OLCRTC_URI=olcrtc://wbstream?datachannel@audit-room#{NEW_KEY}",
                      result.stdout)
        self.assertIn(f"OLCRTC_SIBLING_URI={live}|", result.stdout)
        self.assertIn(f"OLCRTC_SIBLING_URI={stopped}|", result.stdout)
        for config in self.deploy.glob("server*.yaml"):
            self.assertIn(NEW_KEY, config.read_text())
            self.assertNotIn(OLD_KEY, config.read_text())
        self.assertEqual((self.home / ".olcrtc_key").read_text().strip(), NEW_KEY)
        self.assertEqual([cmd[1] for cmd in self.commands() if cmd[0] == "restart"],
                         [BASE, live])

    def test_copied_srv_blocks_remain_verbatim(self):
        lines = {line.strip() for line in (ROOT / "scripts/srv.sh").read_text().splitlines()}
        for name in ("add-carrier", "rotate-key"):
            in_block, count = False, 0
            for raw in (ROOT / f"scripts/{name}.sh").read_text().splitlines():
                line = raw.strip()
                if line.startswith("# boc srv.sh"):
                    self.assertFalse(in_block)
                    in_block = True
                elif line.startswith("# eoc srv.sh"):
                    self.assertTrue(in_block)
                    in_block = False
                elif in_block and line and not line.startswith("#"):
                    self.assertIn(line, lines, f"{name}: {line}")
                    count += 1
            self.assertFalse(in_block)
            self.assertGreater(count, 80)

    def test_host_identity_gate_precedes_authentication_and_uses_original_endpoint(self):
        source = (ROOT / "App/Core/SSHRunner.swift").read_text()
        connect = source.split("private static func connect(host:", 1)[1]
        connect = connect.split('preconditionFailure("unreachable:', 1)[0]
        active = "\n".join(line for line in connect.splitlines()
                           if not line.lstrip().startswith("//"))
        self.assertNotIn(".acceptAnything()", active)
        self.assertLess(active.index("trustStore.prepare("),
                        active.index("authenticationMethod(username:"))
        self.assertIn("host: host.host, port: host.port, legacyPin: host.sshHostKeyPin", active)
        self.assertIn("let hostKeyValidator = SSHAutomaticHostKeyValidator(", active)
        self.assertIn("hostKeyValidator: .custom(hostKeyValidator)", active)
        self.assertIn("context: trustContext, store: trustStore", active)
        self.assertLess(active.index("trustStore.prepare("), active.index("let dialHost"))
        self.assertNotIn("prepare(host: dialHost", active)
        self.assertIn("reconnect: .never", active)
        self.assertLess(active.index("hostKeyValidator.rejection ?? (error as? SSHHostKeyError)"),
                        active.index("if attempt < 2"))

    def test_first_use_has_no_manual_fingerprint_or_acknowledgment(self):
        source = (ROOT / "App/Views/AddServerHostView.swift").read_text()
        self.assertNotIn("TextEditor(text: $hostKeyFingerprint)", source)
        self.assertNotIn("acknowledgedHostKeyPin", source)
        self.assertNotIn("verifiedHostKeyPin", source)
        self.assertNotIn("independentlyVerified:", source)
        validator = (ROOT / "App/Core/SSHHostKeyVerification.swift").read_text()
        self.assertIn("try store.validate(presented: presented, for: context)", validator)
        self.assertNotIn("@MainActor", validator)
        store = (ROOT / "App/Core/SSHHostKeyTrustStore.swift").read_text()
        self.assertIn("if entry.fingerprints.isEmpty", store)
        self.assertIn("entry.fingerprints = [presented]", store)
        self.assertIn("!entry.fingerprints.contains(presented)", store)
        self.assertIn("throw SSHHostKeyError.mismatch", store)
        self.assertIn("entry.generation == context.generation", store)
        self.assertIn("fresh.ignoresLegacy = true", store)
        self.assertIn("Self.lock.lock()", store)
        self.assertIn("flock(descriptor, LOCK_EX | LOCK_NB)", store)
        self.assertIn("data.write(to: fileURL, options: .atomic)", store)
        self.assertIn("throw SSHHostKeyError.trustStoreUnavailable", store)
        self.assertNotIn("@MainActor", store)
        self.assertIn("static let statusDidChange = Notification.Name(", store)
        self.assertIn("func hasMismatch(host: String, port: Int) -> Bool", store)
        self.assertIn("setMismatchLocked(endpoint: context.endpoint, present: true)", store)
        self.assertIn("setMismatchLocked(endpoint: pin.endpoint, present: true)", store)
        self.assertIn("transaction(onCommit:", store)
        self.assertLess(store.index("try data.write(to: fileURL, options: .atomic)"),
                        store.index("onCommit?()"))
        self.assertIn("DispatchQueue.main.async", store)
        renewal = (ROOT / "App/Services/TelemostRenewalCoordinator.swift").read_text()
        self.assertNotIn("SSHHostKeyVerification.requirePin", renewal)
        self.assertIn("SSHHostKeyTrustStore.shared.prepare(host: host.host, port: host.port,", renewal)


if __name__ == "__main__":
    unittest.main(verbosity=2)
# eoc #481
