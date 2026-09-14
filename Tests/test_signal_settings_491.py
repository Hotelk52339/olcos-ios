"""#491: offline source contracts; these are NOT an Xcode build or runtime UI tests.

Run: python3 -m unittest discover -s Tests -p test_signal_settings_491.py -v
The adjacent manifest pins the pre-#491 uncommitted audit/Signal baseline.
No app process, Keychain, preferences, network, SSH, or live backend is touched.
"""
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = Path(__file__).with_name('SignalSettings491.contract.json')
FILES = ['SettingsView', 'ConfigView', 'BotSettingsView', 'LogsView', 'CarrierEndpointsView']


def masked(text):
    # Preserve positions while hiding strings/comments from brace/declaration scans.
    pattern = r'//[^\n]*|/\*[\s\S]*?\*/|"""[\s\S]*?"""|"(?:\\.|[^"\\])*"'
    return re.sub(pattern, lambda m: re.sub(r'[^\n]', ' ', m.group()), text)


def declarations(text):
    clean = masked(text)
    result = {}
    pattern = r'(?m)^\s*(?:(?:private|fileprivate|public|internal|nonisolated|static|mutating)\s+)*(func|var)\s+(\w+)[^\n{]*'
    for m in re.finditer(pattern, clean):
        kind, name = m.group(1, 2)
        start = m.start()
        while start < m.end() and clean[start].isspace():
            start += 1
        brace = clean.find('{', m.end())
        # Stored vars are not computed declarations; methods can have multiline signatures.
        if brace < 0 or (kind == 'var' and '\n' in clean[m.end():brace]):
            continue
        depth = 1
        end = brace + 1
        while depth and end < len(clean):
            depth += (clean[end] == '{') - (clean[end] == '}')
            end += 1
        if depth:
            raise AssertionError(f'Unbalanced declaration {name}')
        result[f'{kind} {name}'] = text[start:end]
    return result


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def normalized_branding_source(filename, text):
    # The olcOS rebrand permits ONE display literal in ONE declaration only.
    # Keep the audited baseline hashes/allowlists; never normalize whole files
    # or arbitrary strings, bindings, actions, or other version-row changes.
    if filename == 'SettingsView':
        row = declarations(text).get('var versionRow')
        if row is not None:
            canonical = row.replace('Text("olcOS")', 'Text("olcrtc-ios")', 1)
            return text.replace(row, canonical, 1)
    return text


def code(text):
    # Drop comments only, retaining display strings and closure actions for assertions.
    return re.sub(r'(?m)^\s*//[^\n]*|(?<=\s)//[^\n]*', '', text)


class SignalSettings491Contracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads(MANIFEST.read_text())
        cls.sources = {n: (ROOT / f'App/Views/{n}.swift').read_text() for n in FILES}

    def test_audited_nonpresentation_declarations_are_byte_identical(self):
        for filename, expected in self.manifest['preserved_declarations'].items():
            actual = declarations(normalized_branding_source(filename, self.sources[filename]))
            for name, expected_hash in expected.items():
                with self.subTest(file=filename, declaration=name):
                    self.assertIn(name, actual)
                    self.assertEqual(digest(actual[name]), expected_hash)

    def test_all_original_store_and_editor_binding_targets_are_reachable(self):
        for filename, expected in self.manifest['binding_targets'].items():
            source = code(self.sources[filename])
            targets = set(re.findall(r'\$[A-Za-z_]\w*(?:\.\w+)*', source))
            self.assertTrue(set(expected) <= targets, (filename, set(expected) - targets))

    def test_each_original_labeled_setting_keeps_its_exact_binding(self):
        for filename, pairs in self.manifest['control_bindings'].items():
            source = code(self.sources[filename])
            for pair in pairs:
                self.assertIn(pair, source, filename)
        for filename, expected in self.manifest['editor_control_counts'].items():
            source = code(self.sources[filename])
            actual = {name: len(re.findall(r'\b' + name + r'\(', source)) for name in expected}
            self.assertEqual(actual, expected, filename)

    def test_all_original_localized_control_and_notice_keys_remain(self):
        for filename, expected in self.manifest['localized_keys'].items():
            actual = set(re.findall(r'L10n\.(\w+)', code(self.sources[filename])))
            self.assertTrue(set(expected) <= actual, (filename, set(expected) - actual))

    def test_original_actions_and_destination_calls_remain(self):
        for filename, expected in self.manifest['action_contracts'].items():
            source = code(self.sources[filename])
            for action in expected:
                with self.subTest(file=filename, action=action):
                    self.assertIn(action, source)

    def test_advanced_directory_reaches_every_editor(self):
        source = self.sources['SettingsView']
        declared = declarations(source)
        directory = declared['var directorySections']
        editor = declared['var editorSection']
        for page, section in [('connection', 'connectionSection'), ('proxy', 'proxySection'),
                              ('transport', 'transportSection'), ('diagnostics', 'diagnosticsSection'),
                              ('logs', 'logsSection')]:
            self.assertIn(f'SettingsAdvancedView(tunnel: tunnel, botStore: botStore, page: .{page})', directory)
            self.assertIn(f'case .{page}: {section}', editor)
        for route in ['dnsLink', 'serversSection']:
            self.assertIn(route, directory)
        for destination in ['DNSSettingsView()', 'IPSourcesSettingsView()',
                            'BotsSettingsView(botStore: botStore)',
                            'BotEditorView(botStore: botStore, existing: bot)',
                            'BotEditorView(botStore: botStore, existing: nil)']:
            self.assertIn(destination, source)
        self.assertIn('Form {', declared['var advancedForm'])

    def test_pushed_editors_observe_and_own_their_live_state(self):
        source = code(self.sources['SettingsView'])
        advanced = source.split('struct SettingsAdvancedView: View {', 1)[1].split('struct IPSourcesSettingsView:', 1)[0]
        # A prebuilt some-View argument can contain stale conditional rows while
        # its bindings continue writing. The pushed view must evaluate the section
        # in its OWN observed body and own the verdict/password/focus state.
        self.assertNotIn('func advancedPage(', advanced)
        self.assertIn('@ObservedObject private var settings = SettingsStore.shared', advanced)
        self.assertIn('@ObservedObject var tunnel: TunnelManager', advanced)
        self.assertIn('@State private var portCheck: PortAvailability.PortState?', advanced)
        self.assertIn('@State private var socksPassInput: String', advanced)
        self.assertIn('@FocusState private var anyFieldFocused: Bool', advanced)
        self.assertIn('self.tunnel = tunnel', advanced)
        self.assertIn('self.botStore = botStore', advanced)
        self.assertIn('page: Page = .directory', advanced)
        form = declarations(self.sources['SettingsView'])['var advancedForm']
        self.assertIn('if page == .directory', form)
        self.assertIn('editorSection', form)

    def test_native_chrome_covers_forms_without_replacing_controls(self):
        for filename in ['SettingsView', 'ConfigView', 'BotSettingsView', 'CarrierEndpointsView']:
            source = code(self.sources[filename])
            self.assertIn('.signalFormRows()', source)
            self.assertIn('.signalFormChrome()', source)
            self.assertIn('SignalSectionHeader(', source)
        self.assertIn('SignalSettingsLabel(', self.sources['SettingsView'])
        self.assertNotIn('ScrollView {', code(self.sources['CarrierEndpointsView']))
        self.assertNotIn('OlcChipPicker(', code(self.sources['LogsView']))
        self.assertNotIn('OlcSegmented(', code(self.sources['LogsView']))
        self.assertIn('LogBodyView(', self.sources['LogsView'])
        self.assertIn('.textSelection(.enabled)', self.sources['LogsView'])

    def test_haptics_remain_user_owned_and_existing_calls_retained(self):
        for filename, expected in self.manifest['haptic_calls'].items():
            actual = Counter(re.findall(r'Haptics\.(\w+)\(', code(self.sources[filename])))
            self.assertEqual(dict(actual), expected, filename)
        settings = declarations(self.sources['SettingsView'])['var languageBinding']
        mode = declarations(self.sources['ConfigView'])['var modePreferenceBinding']
        for binding in [settings, mode]:
            self.assertLess(binding.index('guard '), binding.index('Haptics.tap()'))
        self.assertNotRegex(code(self.sources['SettingsView']), r'onChange\(of: settings\.(language|appearanceMode|backgroundAudio|autoFailover)')

    def test_no_new_startup_probe_or_service_owners(self):
        for filename, expected in self.manifest['lifecycle_counts'].items():
            source = code(self.sources[filename])
            actual = {token: source.count(token) for token in expected}
            self.assertEqual(actual, expected, filename)
        config = code(self.sources['ConfigView'])
        self.assertIn('tunnel.automaticModeFallbackReason', config)
        self.assertIn('L10n.vpnAutomaticFallbackSummary.localized()', config)
        self.assertIn('.disabled(sessionLive)', config)
        self.assertIn('tunnel.effectiveModeForNextConnection == .vpn', config)

    def test_preserved_secrets_validation_and_probe_boundaries(self):
        settings = code(self.sources['SettingsView'])
        for token in ['if settings.localSocksAuthEnabled', 'if !socksPassLoaded',
                      'settings.localSocksPass = v', 'SecureField(L10n.socksPassLabel',
                      'SecureField(L10n.botTokenPlaceholder', 'settings.socksPort) { _, _ in portCheck = nil }',
                      'SettingsStore.shared.reset()', 'LogStore.shared.clearAll()',
                      'role: .destructive', 'L10n.resetSettingsConfirmBody.localized()']:
            self.assertIn(token, settings)
        bot = code(self.sources['BotSettingsView'])
        for token in ['guard !didInitialCheck else', 'guard secret != nil, !botStore.bots.isEmpty',
                      'L10n.botRemoveConfirmBody.localized()', '.disabled(!canOperate)']:
            self.assertIn(token, bot)
        logs = code(self.sources['LogsView'])
        self.assertIn('set: { selectedHostID = $0; selectedContainerName = nil }', logs)
        self.assertIn('items.first(where: { $0.name == selectedContainerName })?.name ?? items[0].name', logs)

    def test_no_new_display_literals_or_global_data_owners(self):
        for filename, allowed in self.manifest['display_literals'].items():
            source = code(normalized_branding_source(filename, self.sources[filename]))
            literals = re.findall(r'(?:Text|Button|Label|TextField|SecureField)\("([^"\n]*)"', source)
            self.assertTrue(set(literals) <= set(allowed), (filename, set(literals) - set(allowed)))
            for forbidden in ['UserDefaults.', 'URLSession', 'Task.detached', 'NEVPNManager']:
                self.assertNotIn(forbidden, source)


if __name__ == '__main__':
    unittest.main()
