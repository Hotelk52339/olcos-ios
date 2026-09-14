"""#490 offline source contracts against the frozen, uncommitted prior Signal tree.

Run: python3 -m unittest discover -s Tests -p test_signal_servers_490.py -v
Only Python stdlib is required. This is NOT Swift type checking or a UI test.
The adjacent manifest pins every original declaration signature, all unchanged
method/property implementations, editor binding destinations, and modal paths.
Presentation rewrites are explicit exceptions, not omitted button counts.
The TOFU update removes only the four manual-pin declarations, two manual-pin
controls and associated bindings/keys. Only isValid/body/save/prefill hashes
change for that removal; all other editor guards remain frozen.
"""
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = Path(__file__).with_name('SignalServers490.contract.json')
LEX = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"""[\s\S]*?"""|"(?:\\.|[^"\\])*"|[A-Za-z_][A-Za-z_0-9]*|[^\s]')


def tokens(source):
    # Keep strings (including URLs) verbatim; only comments/whitespace disappear.
    return [m.group() for m in LEX.finditer(source) if not m.group().startswith(('//', '/*'))]


def digest(seq):
    return hashlib.sha256(json.dumps(seq, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()


def occurrence(seq, part):
    for index in range(len(seq) - len(part) + 1):
        if seq[index:index + len(part)] == part:
            return index
    raise AssertionError('Missing source contract: ' + ' '.join(part))


def block(seq, start):
    brace = seq.index('{', start)
    depth = 1
    end = brace + 1
    while depth and end < len(seq):
        depth += (seq[end] == '{') - (seq[end] == '}')
        end += 1
    if depth:
        raise AssertionError('Unbalanced source block')
    return seq[start:end]


def declaration(seq, owner, signature):
    for kind in ['struct', 'enum', 'class']:
        try:
            start = occurrence(seq, [kind, owner])
            break
        except AssertionError:
            continue
    else:
        raise AssertionError('Missing original type: ' + owner)
    scope = block(seq, start)
    return block(scope, occurrence(scope, signature))


def replace_sequence(seq, old, new):
    result = []
    pos = 0
    while pos < len(seq):
        if seq[pos:pos + len(old)] == old:
            result.extend(new)
            pos += len(old)
        else:
            result.append(seq[pos])
            pos += 1
    return result


class SignalServers490Contracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads(MANIFEST.read_text())
        cls.sources = {name: (ROOT / f'App/Views/{name}.swift').read_text()
                       for name in cls.manifest['files']}
        cls.code = {name: tokens(source) for name, source in cls.sources.items()}
        cls.presentation = (ROOT / 'App/Views/ServerSignalPresentation.swift').read_text()
        cls.scan = (ROOT / 'App/Views/ServerContainerScanView.swift').read_text()

    def assertContract(self, source, text):
        occurrence(tokens(source), tokens(text))

    def method(self, filename, name):
        for item in self.manifest['declarations'][filename]:
            sig = item['signature']
            if ('func' in sig and sig[sig.index('func') + 1] == name) or ('var' in sig and sig[sig.index('var') + 1] == name):
                return declaration(self.code[filename], item['owner'], sig)
        self.fail('Not a baseline method: ' + name)

    def test_every_original_method_and_computed_property_signature_survives(self):
        for filename, items in self.manifest['declarations'].items():
            for item in items:
                with self.subTest(file=filename, owner=item['owner'], signature=item['signature']):
                    declaration(self.code[filename], item['owner'], item['signature'])

    def test_all_nonpresentation_implementations_match_the_frozen_audit_tree(self):
        for filename, items in self.manifest['declarations'].items():
            for item in items:
                if item['mode'] != 'unchanged':
                    continue
                with self.subTest(file=filename, signature=item['signature']):
                    actual = declaration(self.code[filename], item['owner'], item['signature'])
                    if filename == 'ServersView' and item['signature'] == tokens('var body: some View'):
                        # Only a read-only mismatch observer wraps the original
                        # modal/root tree. The original hash still protects it.
                        actual = replace_sequence(actual, tokens(
                            'observeHostKeyStatus(carrierModals(hostConfirmations(hostSheets(coreStack))))'),
                            tokens('carrierModals(hostConfirmations(hostSheets(coreStack)))'))
                    self.assertEqual(digest(actual), item['sha256'])

    def test_operation_driver_changes_only_its_animation_argument(self):
        actual = self.method('ServersView', 'run')
        actual = replace_sequence(actual, tokens('withAnimation(serverTransition)'),
                                  tokens('withAnimation(.easeInOut(duration: 0.35))'))
        expected = next(i for i in self.manifest['declarations']['ServersView'] if i['mode'] == 'motion-only')
        self.assertEqual(digest(actual), expected['sha256'])

    def test_editor_implementations_change_only_presentation_not_bindings_or_guards(self):
        for filename in ['InstallOptionsView', 'ReconfigureOptionsView', 'AddServerHostView']:
            for item in self.manifest['declarations'][filename]:
                actual = declaration(self.code[filename], item['owner'], item['signature'])
                if filename == 'AddServerHostView' and item['signature'] == tokens('var body: some View'):
                    # Follow the two extracted sections back into the original body.
                    for name in ['descriptionSection', 'testSection']:
                        helper = declaration(self.code[filename], item['owner'],
                                             tokens(f'private var {name}: some View'))
                        content = helper[helper.index('{') + 1:-1]
                        if name == 'descriptionSection':
                            content = replace_sequence(content, tokens(
                                '} header: { SignalSectionHeader(L10n.sectionDescription.localized()) }'),
                                tokens('}'))
                            content = replace_sequence(content, tokens('Section {'),
                                                       tokens('Section(L10n.sectionDescription.localized()) {'))
                        actual = replace_sequence(actual, [name], content)
                for old, new in [
                    ('ServerSignalOptions', 'OlcChipPicker'),
                    ('SignalSectionHeader', 'Text'),
                    ('.signalFormRows()', ''),
                    ('.signalFormChrome()', ''),
                    ('Theme.Signal.stroke', 'Theme.Palette.accent'),
                ]:
                    actual = replace_sequence(actual, tokens(old), tokens(new))
                with self.subTest(file=filename, signature=item['signature']):
                    self.assertEqual(digest(actual), item['sha256'])

    def test_root_chrome_retains_all_lifecycle_modifiers_after_touch_target_styling(self):
        actual = self.method('ServersView', 'listChrome')
        actual = replace_sequence(actual, tokens(
            '.frame(minWidth: Theme.Metrics.controlHeight, minHeight: Theme.Metrics.controlHeight)'), [])
        expected = next(i for i in self.manifest['declarations']['ServersView']
                        if 'func' in i['signature']
                        and i['signature'][i['signature'].index('func') + 1] == 'listChrome')
        self.assertEqual(digest(actual), expected['sha256'])

    def test_all_original_bindings_and_callback_inputs_remain(self):
        for filename, expected in self.manifest['binding_targets'].items():
            actual = set(re.findall(r'\$[A-Za-z_]\w*(?:\.\w+)*', ' '.join(self.code[filename]).replace(' . ', '.').replace('$ ', '$')))
            self.assertTrue(set(expected) <= actual, (filename, set(expected) - actual))
        for filename, callbacks in self.manifest['callback_inputs'].items():
            for callback in callbacks:
                self.assertContract(self.sources[filename], callback)
        for filename, closures in self.manifest['action_closures'].items():
            for closure in closures:
                occurrence(self.code[filename], closure)
        for filename, controls in self.manifest['control_bindings'].items():
            for control in controls:
                actual = replace_sequence(self.code[filename], ['ServerSignalOptions'], ['OlcChipPicker'])
                occurrence(actual, control)

    def test_modal_lifecycle_and_confirmation_paths_are_preserved_not_recreated(self):
        for name in ['hostSheets', 'hostConfirmations', 'carrierModals', 'hostDestinations',
                     'refreshAllHosts', 'refreshOnEntry', 'autoPingOnce', 'checkNeverProbedHosts',
                     'hostCard', 'addCarrier', 'removeCarrier', 'startCarrier', 'stopCarrier', 'refreshCarriers', 'connectVia', 'verifyRow',
                     'scanContainers', 'restoreContainer']:
            item = next(i for i in self.manifest['declarations']['ServersView']
                        if 'func' in i['signature'] and i['signature'][i['signature'].index('func') + 1] == name)
            self.assertEqual(item['mode'], 'unchanged', name)
            self.assertEqual(digest(self.method('ServersView', name)), item['sha256'])
        for path in self.manifest['lifecycle_paths']:
            occurrence(self.code['ServersView'], path)
        self.assertContract(self.sources['ServersView'], 'onRestore: { restoreContainer($0, on: host) }')
        self.assertContract(self.sources['ServersView'], 'onDone: { scanFor = nil }')
        self.assertContract(self.sources['ServersView'], '.onDisappear { foundContainers = [] }')
        self.assertContract(self.sources['ServersView'], '.presentationDetents([.medium, .large])')
        self.assertContract(self.scan, 'Button(L10n.scanRestoreAction.localized()) { onRestore(container) }')

    def test_original_menu_builders_and_roles_are_exact_and_management_reuses_them(self):
        for name in ['menuItems', 'carrierMenuItems', 'recoverItem', 'reconfigureItem']:
            item = next(i for i in self.manifest['declarations']['ServersView']
                        if 'func' in i['signature'] and i['signature'][i['signature'].index('func') + 1] == name)
            self.assertEqual(item['mode'], 'unchanged')
            self.assertEqual(digest(self.method('ServersView', name)), item['sha256'])
        self.assertContract(self.sources['ServersView'], 'var items = menuItems(host)')
        self.assertContract(self.sources['ServerAdvancedView'], 'ServerManagementMenuRows(items: menuItems)')
        self.assertContract(self.presentation, 'Button(role: role, action: action)')
        self.assertContract(self.presentation, 'ForEach(Array(items.enumerated()), id: \\.offset)')
        self.assertContract(self.presentation, 'Image(asset).renderingMode(.template)')
        # Management uses only original action/divider items, never silently drops a share variant.
        menu = self.method('ServersView', 'menuItems')
        for variant in ['share', 'shareLazy', 'shareFileLazy']:
            self.assertNotIn(['.', variant, '('], [menu[i:i + 3] for i in range(len(menu))])

    def test_all_existing_secret_trust_and_edit_controls_keep_their_guards(self):
        source = self.sources['AddServerHostView']
        for contract in self.manifest['trust_contracts']:
            self.assertContract(source, contract)
        for filename in ['AddServerHostView', 'InstallOptionsView', 'ReconfigureOptionsView']:
            self.assertContract(self.sources[filename], 'Form {')
            self.assertContract(self.sources[filename], '.signalFormChrome()')
            self.assertContract(self.sources[filename], '.signalFormRows()')
            self.assertContract(self.sources[filename], 'SignalSectionHeader(')
        # First-key trust is automatic, never an additional setup step.
        for obsolete in ['hostKeyFingerprint', 'acknowledgedHostKeyPin',
                         'candidateHostKeyPin', 'verifiedHostKeyPin',
                         'hostKeyInputOK', 'hostKeySection']:
            self.assertNotIn(obsolete, self.code['AddServerHostView'])
        self.assertContract(source, 'var h = existing ?? ServerHost(label: "", host: "")')
        self.assertNotIn('sshHostKeyPin', self.code['AddServerHostView'])
        self.assertNotIn('resetTrust', self.code['AddServerHostView'])
        self.assertContract(source, '!trimmedLabel.isEmpty && !trimmedHost.isEmpty && Self.validPort(port) != nil && !trimmedUsername.isEmpty && credentialOK && !isDuplicateLabel')

    def test_option_rows_keep_disabled_imports_and_haptic_only_changed_taps(self):
        source = self.presentation
        self.assertContract(source, 'guard ServerPresentationPolicy.allowsSelectionChange(current: selection, proposed: option.value, isDisabled: option.disabled) else { return } Haptics.tap() selection = option.value')
        self.assertContract(source, '.disabled(option.disabled)')
        self.assertContract(source, '.accessibilityLabel(option.a11yLabel ?? option.label)')
        self.assertContract(source, 'if option.disabled, let reason = option.disabledReason')
        self.assertContract(source, 'self._selection = selection')
        self.assertContract(source, 'self.options = options')
        for filename in ['InstallOptionsView', 'ReconfigureOptionsView']:
            self.assertIn('ServerSignalOptions', self.code[filename])
            self.assertNotIn('OlcChipPicker', self.code[filename])

    def test_changed_server_key_recovery_requires_an_explicit_confirmation(self):
        source = self.sources['ServerAdvancedView']
        recovery = declaration(self.code['ServerAdvancedView'], 'ServerAdvancedView',
                               tokens('private var hostKeyRecoverySection: some View'))
        occurrence(recovery, tokens('if hasHostKeyMismatch {'))
        occurrence(recovery, tokens('Button(L10n.sshHostKeyResetAction.localized(), role: .destructive) { confirmHostKeyReset = true }'))
        self.assertNotIn('onResetHostKeyTrust', recovery)
        self.assertContract(source, '.confirmationDialog(L10n.sshHostKeyChangedTitle.localized(), isPresented: $confirmHostKeyReset, titleVisibility: .visible)')
        self.assertContract(source, 'guard hasHostKeyMismatch, !actionsDisabled else { return } onResetHostKeyTrust()')
        self.assertContract(source, 'Button(L10n.cancel.localized(), role: .cancel) { }')
        self.assertContract(source, 'Text(L10n.sshHostKeyResetWarning.localized())')
        # Normal management never exposes raw key material or a trust setup gate.
        for filename in ['AddServerHostView', 'ServerAdvancedView']:
            for forbidden in ['hasTrust', 'fingerprints', 'hostKeyFingerprint',
                              'sshHostKeyVerificationHelp', 'sshHostKeyVerificationAcknowledgement']:
                self.assertNotIn(forbidden, self.code[filename])

    def test_confirmed_reset_preserves_credentials_and_all_endpoint_alias_metadata(self):
        seq = self.code['ServersView']
        reset = declaration(seq, 'ServersView',
                            tokens('private func resetHostKeyTrust(_ snapshot: ServerHost)'))
        occurrence(reset, tokens('guard !actionsDisabled, carrierBusyHostID == nil'))
        occurrence(reset, tokens('let current = serverStore.hosts.first(where: { $0.id == snapshot.id })'))
        occurrence(reset, tokens('endpoint == SSHHostKeyVerification.endpoint(host: snapshot.host, port: snapshot.port)'))
        occurrence(reset, tokens('hostKeyMismatchEndpoints.contains(endpoint)'))
        occurrence(reset, tokens('SSHHostKeyTrustStore.shared.hasMismatch(host: current.host, port: current.port)'))
        durable = occurrence(reset, tokens('try SSHHostKeyTrustStore.shared.resetTrust(host: current.host, port: current.port)'))
        clear = occurrence(reset, tokens('updated.sshHostKeyPin = nil'))
        self.assertLess(durable, clear, 'failed persistence must not clear legacy pins')
        occurrence(reset, tokens('for host in serverStore.hosts where SSHHostKeyVerification.endpoint(host: host.host, port: host.port) == endpoint'))
        occurrence(reset, tokens('var updated = host updated.sshHostKeyPin = nil serverStore.update(updated, secret: nil)'))
        occurrence(reset, tokens('catch { alertText = error.localizedDescription }'))
        for forbidden in ['Task', 'provisioner', 'Haptics', 'writeSecret',
                          'scanContainers', 'checkServer', 'lastProbeOK', 'connections', 'tunnel']:
            self.assertNotIn(forbidden, reset)
        self.assertEqual(Counter(seq)['resetTrust'], 1, 'only the confirmed helper may reset trust')
        self.assertContract(self.sources['ServersView'], 'hasHostKeyMismatch: hasHostKeyMismatch(host), onResetHostKeyTrust: { resetHostKeyTrust(host) }')

    def test_backend_mismatch_status_reaches_recovery_without_a_network_or_string_gate(self):
        seq = self.code['ServersView']
        self.assertContract(self.sources['ServersView'],
                            'observeHostKeyStatus(carrierModals(hostConfirmations(hostSheets(coreStack))))')
        observer = declaration(seq, 'ServersView',
                               tokens('private func observeHostKeyStatus(_ content: some View) -> some View'))
        occurrence(observer, tokens('.onAppear { refreshHostKeyMismatchStatus() }'))
        occurrence(observer, tokens('.onReceive(NotificationCenter.default.publisher(for: SSHHostKeyTrustStore.statusDidChange).receive(on: RunLoop.main)) { _ in refreshHostKeyMismatchStatus() }'))
        occurrence(observer, tokens('.onChange(of: serverStore.hosts) { _, _ in refreshHostKeyMismatchStatus() }'))
        refresh = declaration(seq, 'ServersView',
                              tokens('private func refreshHostKeyMismatchStatus()'))
        occurrence(refresh, tokens('hostKeyMismatchEndpoints = Set(serverStore.hosts.compactMap { host -> String? in'))
        occurrence(refresh, tokens('guard SSHHostKeyTrustStore.shared.hasMismatch(host: host.host, port: host.port) else { return nil }'))
        occurrence(refresh, tokens('return SSHHostKeyVerification.endpoint(host: host.host, port: host.port)'))
        for forbidden in ['localizedDescription', 'L10n', 'userInfo', 'Task',
                          'provisioner', 'Haptics', 'resetTrust', 'hasTrust',
                          'Timer', 'lastProbeOK', 'tunnel']:
            self.assertNotIn(forbidden, observer + refresh)

    def test_new_connection_tap_has_one_guarded_haptic_and_reuses_connect_via(self):
        row = self.sources['ProtocolRowView']
        self.assertContract(row, 'guard !menuDisabled, !isLive else { return } Haptics.impact() onConnect()')
        self.assertContract(row, '.disabled(menuDisabled || isLive)')
        self.assertContract(row, 'isLive ? L10n.protocolLiveBadge.localized() : L10n.protocolConnectAction.localized()')
        self.assertEqual(Counter(tokens(row))['Haptics'], 1)
        self.assertContract(self.sources['ServersView'], 'onConnect: { connectVia(host, row: row) }')
        self.assertContract(row, 'OlcHealthChip(display: health, onTap: onVerify)')
        self.assertContract(row, 'OlcOverflowMenu(items: menuItems).disabled(menuDisabled)')

    def test_health_comes_from_existing_dated_resolvers_and_actual_loading(self):
        source = self.sources['ServersView']
        for contract in ['headline: headline(host, state: state)', 'health: rowHealth(host, row: row)',
                         'isLoading: carrierListInFlight.contains(host.id)', 'hasRead: carrierRows[host.id] != nil',
                         'let host = ServerPresentationPolicy.currentHost(snapshot: host, hosts: serverStore.hosts)']:
            self.assertContract(source, contract)
        for new in [self.presentation, self.scan]:
            seq = tokens(new)
            for forbidden in ['Date', 'Timer', 'TimelineView', 'URLSession', 'Provisioner', 'Task', 'StateObject', 'ObservedObject']:
                self.assertNotIn(forbidden, seq)
        self.assertContract(self.presentation, 'Text(subtitle)')
        self.assertContract(self.presentation, '.fixedSize(horizontal: false, vertical: true)')
        self.assertContract(self.sources['ServerCardView'], 'if listing == .loading')
        self.assertContract(self.sources['ServerCardView'], 'else if listing == .unread')

    def test_motion_is_short_reduce_motion_aware_and_never_an_idle_loop(self):
        for filename in ['ServersView', 'ServerCardView', 'TelemostRoomButton']:
            seq = self.code[filename]
            self.assertIn('accessibilityReduceMotion', seq)
            self.assertNotIn('repeatForever', seq)
            self.assertNotIn('TimelineView', seq)
        self.assertContract(self.presentation, 'reduceMotion ? 0 : 0.18')
        self.assertContract(self.sources['ServersView'], 'reduceMotion ? nil : .easeOut')

    def test_no_new_display_keys_or_nonpreview_literals(self):
        # Tokens are checked only before DEBUG previews, which are sample values.
        for filename, expected in self.manifest['localized_keys'].items():
            seq = self.code[filename] + (tokens(self.scan) if filename == 'ServersView' else [])
            actual = {seq[i + 2] for i in range(len(seq) - 2) if seq[i:i + 2] == ['L10n', '.']}
            self.assertTrue(set(expected) <= actual, (filename, set(expected) - actual))
        baseline_keys = set().union(*(set(keys) for keys in self.manifest['localized_keys'].values()))
        for source in list(self.sources.values()) + [self.presentation, self.scan]:
            seq = tokens(source)
            actual_keys = {seq[i + 2] for i in range(len(seq) - 2) if seq[i:i + 2] == ['L10n', '.']}
            self.assertTrue(actual_keys <= baseline_keys, actual_keys - baseline_keys)
            allowed_literals = set().union(*(set(v) for v in self.manifest['display_literals'].values()))
            actual_literals = {seq[i + 2] for i in range(len(seq) - 2)
                               if seq[i] in ['Text', 'Label', 'Button', 'TextField', 'SecureField']
                               and seq[i + 1] == '(' and seq[i + 2].startswith(chr(34))}
            self.assertTrue(actual_literals <= allowed_literals, actual_literals - allowed_literals)


if __name__ == '__main__':
    unittest.main()
# eoc #490
