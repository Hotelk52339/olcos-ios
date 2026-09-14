"""#486: Linux-runnable source contracts, NOT an iOS build or runtime test.

Run: python3 -m unittest discover -s Tests -p test_signal_native_486.py -v
The Swift XCTest file tests policy behavior on the native test target.
"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def code(relative):
    text = (ROOT / relative).read_text()
    return "\n".join(line.split("//", 1)[0] for line in text.splitlines())


class SignalNativeSourceContracts(unittest.TestCase):
    def test_signal_is_central_linework_not_an_icon_or_original_hero_card(self):
        hero = code("App/Views/ConnectHero.swift")
        body = hero.split("var body: some View", 1)[1].split("private var subjectPlate", 1)[0]
        self.assertIn("SignalWaveform(", body)
        self.assertNotIn("Image(", body)
        self.assertNotIn("OlcCard", body)
        self.assertNotIn("auroraVerdictRing", hero)
        self.assertLess(body.index("stateWord"), body.index("SignalWaveform("))
        self.assertLess(body.index("SignalWaveform("), body.index("subjectPlate"))
        self.assertLess(body.index("subjectPlate"), body.index("primaryControl"))

    def test_wave_clock_is_conditionally_mounted_and_cadence_is_bounded(self):
        wave = code("App/Views/SignalWaveform.swift")
        self.assertRegex(wave, r"if moves\s*\{\s*TimelineView")
        self.assertIn("minimumInterval: 1 / SignalMotionPolicy.framesPerSecond", wave)
        self.assertIn("framesPerSecond = 30.0", wave)
        self.assertIn("lineCount = 7", wave)
        self.assertIn("sampleCount = 96", wave)
        self.assertIn("canvas(phase: 0, size: geometry.size, touch: nil)", wave)
        self.assertIn("isConnected && sceneIsActive && !reduceMotion && isVisible", wave)
        for token in ["scenePhase == .active", "reduceMotion: reduceMotion",
                      "isVisible && isPresented", ".onDisappear { isVisible = false }"]:
            self.assertIn(token, wave)
        self.assertNotIn("repeatForever", wave)

    def test_touch_never_drives_haptics_or_collects_audio_or_network_metrics(self):
        wave = code("App/Views/SignalWaveform.swift")
        for token in ["simultaneousGesture", "DragGesture", "guard moves else",
                      "touchX: touchX, touchY: touchY", ".accessibilityHidden(true)"]:
            self.assertIn(token, wave)
        for forbidden in ["Haptics.", "AVAudio", "AVCapture", "URLSession", "Mobile",
                          "packetCount", "bytesReceived", "Timer.", "Task {"]:
            self.assertNotIn(forbidden, wave)

    def test_scope_uses_effective_idle_mode_and_runtime_setup_mode_without_picker(self):
        connections = code("App/Views/ConnectionsView.swift")
        for token in ["tunnel.effectiveModeForNextConnection", "return tunnel.activeMode",
                      "mode: heroMode", "tunnel.automaticModeFallbackReason"]:
            self.assertIn(token, connections)
        for forbidden in ["settings.tunnelMode", "OlcSegmented", "Picker("]:
            self.assertNotIn(forbidden, connections)
        hero = code("App/Views/ConnectHero.swift")
        self.assertIn("DisclosureGroup", hero)
        self.assertIn("L10n.vpnAutomaticFallbackSummary.localized()", hero)

    def test_exit_age_is_measurement_time_not_appearance_time(self):
        hero = code("App/Views/ConnectHero.swift")
        connections = code("App/Views/ConnectionsView.swift")
        self.assertIn("exitMeasuredAt: ipCheck.exitGeoAt", connections)
        self.assertIn("let measuredAt = exitMeasuredAt", hero)
        self.assertIn("since: measuredAt", hero)
        self.assertNotIn("exitSince", hero)
        self.assertIn("state.isConnected && health.isVerified && mode == .proxy", hero)
        self.assertIn("health.subtitle", hero)

    def test_audited_route_and_diagnostics_guards_survive(self):
        connections = code("App/Views/ConnectionsView.swift")
        for token in [
            "RouteMode.current(isConnected: tunnel.state.isConnected, activeMode: tunnel.activeMode)",
            ".onChange(of: tunnel.connectedRecord?.id) { _, _ in invalidateDiagnostics() }",
            ".onChange(of: tunnel.activeMode) { _, _ in invalidateDiagnostics() }",
            "ipCheck.invalidateRoute()", "speed.invalidateRoute()",
            ".disabled(tunnel.state.isConnecting || tunnel.state == .waitingForNetwork)",
            "if currentMode.isTunnelled",
        ]:
            self.assertIn(token, connections)

    def test_import_share_diagnostics_and_locked_secrets_are_retained(self):
        connections = code("App/Views/ConnectionsView.swift")
        for token in ["onPasteImport", "DiagnosticsCard(", "rowMenuItems(",
                      "shareConnectionTitle", "copyURIAction", "actionQR",
                      "carrierEndpointsItem", ".sheet(item: $activeSheet)",
                      "store.secretsLocked", "tunnel.connect(record: record)"]:
            self.assertIn(token, connections)
        hero = code("App/Views/ConnectHero.swift")
        for token in [".disabled(!canConnect)", "errorSecretsLocked",
                      "OlcOverflowMenu(items: menuItems)", "ConnectActionSite.elsewhereNote"]:
            self.assertIn(token, hero)

    def test_outcome_haptics_have_one_user_owned_call_site(self):
        connections = code("App/Views/ConnectionsView.swift")
        self.assertEqual(connections.count("Haptics.success()"), 1)
        self.assertEqual(connections.count("Haptics.error()"), 1)
        for token in ["hapticPolicy.beginConnection(id: record.id)", "hapticPolicy.cancel()",
                      "hapticPolicy.outcome(", "isVisible: isVisible && activeSheet == nil",
                      "sceneIsActive: scenePhase == .active",
                      "isAutomaticRecovery: tunnel.hasPendingRecovery"]:
            self.assertIn(token, connections)
        self.assertNotIn(".onChange(of: settings.autoFailover)", connections)
        self.assertIn("SignalHapticPolicy.selectionChanged", connections)

    def test_generators_are_reused_prepared_soft_and_foreground_guarded(self):
        helper = code("App/UI/DesignSystem.swift").split("enum Haptics", 1)[1].split("struct OlcButton", 1)[0]
        for token in ["static let selection = UISelectionFeedbackGenerator()",
                      "static let action = UIImpactFeedbackGenerator(style: .soft)",
                      "static let notification = UINotificationFeedbackGenerator()",
                      "selection.prepare()", "action.prepare()", "notification.prepare()",
                      "UIApplication.shared.applicationState == .active",
                      "guard Thread.isMainThread else", "MainActor.assumeIsolated"]:
            self.assertIn(token, helper)
        self.assertNotIn("style: .medium", helper)
        self.assertNotIn("style: .light", helper)
        self.assertEqual(helper.count("UISelectionFeedbackGenerator()"), 1)
        self.assertEqual(helper.count("UINotificationFeedbackGenerator()"), 1)

    def test_no_new_unlocalized_display_literals_or_raw_type_steps(self):
        for relative in ["App/Views/SignalWaveform.swift", "App/Views/ConnectHero.swift"]:
            source = code(relative)
            self.assertNotRegex(source, r'Text\("[A-Za-z]')
            self.assertNotRegex(source, r"\.font\(\.(headline|subheadline|footnote|caption2)")
            self.assertNotIn(".system(size:", source)
        # New source is auto-discovered by the generated target, not pbxproj edits.
        project = (ROOT / "project.yml").read_text()
        self.assertIn("- path: App", project)
        self.assertIn("- path: Tests", project)


if __name__ == "__main__":
    unittest.main()
