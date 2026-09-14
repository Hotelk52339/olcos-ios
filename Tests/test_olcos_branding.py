"""Offline olcOS display/identity contracts, not Swift execution or an iOS build.

Run: python3 -m unittest discover -s Tests -p test_olcos_branding.py -v
Behavioral version/URL/log/URI tests also live in the native XCTest target.
"""
import json
from pathlib import Path
import re
import unittest

from test_signal_settings_491 import declarations, digest, normalized_branding_source

ROOT = Path(__file__).resolve().parents[1]
VERSION_ROW_BASELINE = 'e4842021fcf7a094a38f6eee6eb92d210f9f5424ea9162bfa3e8ba70cc301909'


def source(relative):
    return (ROOT / relative).read_text()


class OlcosBrandingContracts(unittest.TestCase):
    def test_release_resets_to_one_point_zero_build_one_without_identity_changes(self):
        project = source('project.yml')
        self.assertEqual(re.findall(r'^\s*MARKETING_VERSION: "([^"]+)"', project, re.M), ['1.0'])
        self.assertEqual(re.findall(r'^\s*CURRENT_PROJECT_VERSION: "([^"]+)"', project, re.M), ['1'])
        self.assertEqual(re.findall(r'^\s*CFBundleDisplayName: (.+)', project, re.M),
                         ['olcOS', 'olcOS Tunnel'])
        self.assertEqual(re.findall(r'^\s*PRODUCT_BUNDLE_IDENTIFIER: (.+)', project, re.M), [
            'io.github.hotelk52339.olcrtc-ios',
            'io.github.hotelk52339.olcrtc-ios-tests',
            'io.github.hotelk52339.olcrtc-ios.tunnel'])
        self.assertTrue(project.startswith('name: olcrtc-ios\n'))
        for name in ['olcrtc-ios', 'olcrtc-ios-tests', 'olcrtc-tunnel']:
            self.assertIn(f'\n  {name}:\n', project)
        self.assertIn('CFBundleURLName: olcrtc', project)
        self.assertIn('              - olcrtc\n', project)
        self.assertIn('              - olcrtc-sub\n', project)
        self.assertEqual(project.count('CFBundleShortVersionString: "$(MARKETING_VERSION)"'), 2)
        self.assertEqual(project.count('CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"'), 2)

    def test_release_urls_use_new_repository_and_asset_not_old_slug(self):
        constants = source('App/Utilities/AppConstants.swift').split('    enum Update {', 1)[1]
        self.assertIn('static let repoSlug = "Hotelk52339/olcos-ios"', constants)
        self.assertIn('static let ipaAssetName = "olcos-ios-unsigned.ipa"', constants)
        self.assertNotIn('olcrtc-ios', constants)
        for token in ['https://api.github.com/repos/\\(repoSlug)/releases/latest',
                      'https://github.com/\\(repoSlug)/releases/tag/\\(tag)',
                      'https://github.com/\\(repoSlug)/releases/download/\\(tag)/\\(ipaAssetName)',
                      'sidestore://install?url=\\(ipaDownloadURL(tag: tag))',
                      'livecontainer://install?url=\\(ipaDownloadURL(tag: tag))']:
            self.assertIn(token, constants)

    def test_localized_brand_values_keep_protocol_identifiers(self):
        files = ['App/Localization/L10nTable.swift', 'App/Localization/L10nFrench.swift']
        branded = {
            'vpnSettingsEntryName', 'actionUpdate', 'logPortBusyOlcrtc_fmt',
            'installTitle', 'connectingOlcrtc_fmt', 'provisioningUpdating',
            'installPhaseBuild', 'installPhaseStart', 'installResultSuccess_fmt',
            'updateResultSuccess', 'scanningContainers', 'actionScanVPS',
            'scanNoContainers', 'actionDeepUninstall', 'deepUninstallResultSuccess',
            'portInUseByOlcrtc', 'carrierEndpointsLead', 'logsScanAmbiguous_fmt'
        }
        counts = dict.fromkeys(branded, 0)
        allowed_old = {
            'uriErrorInvalidScheme': 'olcrtc://',
            'subInvalidLink': 'olcrtc-sub://host/path',
            'botNamePlaceholder': 'olcrtc_server_bot'
        }
        for path in files:
            entries = re.findall(r'^\s*\.(\w+):\s*("(?:\\.|[^"\\])*")', source(path), re.M)
            for key, literal in entries:
                value = json.loads(literal)
                if key in branded:
                    counts[key] += 1
                    self.assertIn('olcOS', value, (path, key))
                if 'olcrtc' in value.lower():
                    self.assertIn(key, allowed_old, (path, key, value))
                    self.assertIn(allowed_old[key], value)
        self.assertEqual(set(counts.values()), {3})

    def test_version_row_is_byte_identical_except_exact_brand(self):
        text = source('App/Views/SettingsView.swift')
        row = declarations(text)['var versionRow']
        self.assertEqual(row.count('Text("olcOS")'), 1)
        canonical = declarations(normalized_branding_source('SettingsView', text))['var versionRow']
        self.assertEqual(digest(canonical), VERSION_ROW_BASELINE)

    def test_contract_normalization_cannot_hide_other_changes(self):
        text = source('App/Views/SettingsView.swift')
        row = declarations(text)['var versionRow']
        mutation = row.replace('Text(appVersion)', 'Text("olcOS")')
        changed = text.replace(row, mutation, 1)
        canonical = declarations(normalized_branding_source('SettingsView', changed))['var versionRow']
        self.assertNotEqual(digest(canonical), VERSION_ROW_BASELINE)
        self.assertIn('Text("olcOS")', canonical)  # Only the brand's first occurrence is allowed.
        outside = text + '\nprivate var unrelated: some View { Text("olcOS") }\n'
        self.assertIn('var unrelated: some View { Text("olcOS") }',
                      normalized_branding_source('SettingsView', outside))
        self.assertEqual(normalized_branding_source('OtherView', text), text)

    def test_normal_version_policy_is_unchanged_no_forced_legacy_downgrade(self):
        methods = declarations(source('App/Services/UpdateChecker.swift'))
        expected = {
            'func isNewer': 'fac9c6f02083e000b7c33f2a188705817526e150b8ca060b6c9249312c1163ab',
            'func normalize': 'f1ac7d65da0733747dd7b89c6163418924a8c15c384933583113a71c3a0c747c',
            'func segments': '70e8029dacad1bfae5a4dbc88ebf850b71b4d00c9dfcd9d7e51b211cabb0f1d3'
        }
        for name, baseline in expected.items():
            self.assertEqual(digest(methods[name]), baseline, name)

    def test_logs_change_display_only_and_keep_storage_and_secret_redaction(self):
        store = source('App/Services/LogStore.swift')
        self.assertIn('return "olcOS \\(v) build \\(b)"', store)
        self.assertIn('"/tmp/olcrtc-ios-logs"', store)
        self.assertIn('DispatchQueue(label: "olcrtc.log-file-writer"', store)
        self.assertIn(r'(olcrtc://[^\s#]+#)[^\s%$]+', store)
        self.assertIn('(OLCRTC_WB_TOKEN=)', store)
        export = source('App/Services/LogExport.swift')
        for text in ['olcOS-\\(safeToken(label))', 'olcOS-all-logs-v',
                     'olcOS · diagnostic log export', 'olcOS · FULL diagnostic log export',
                     'olcOS \\(version) (build \\(build))']:
            self.assertIn(text, export)
        self.assertIn('.appendingPathComponent("log-exports", isDirectory: true)', export)

    def test_existing_persistence_and_ssh_command_identity_remains(self):
        for path, tokens in {
            'App/Core/ConnectionStore.swift': ['"olcrtc_records_v2"', '"olcrtc_primary_id"', '"olcrtc_sub_meta_v1"'],
            'App/Core/ServerHostStore.swift': ['"olcrtc_server_hosts"', '"olcrtc.serverhost.password"',
                                             '"olcrtc.serverhost.privatekey"', '"olcrtc.serverhost.keypassphrase"'],
            'App/Services/SettingsStore.swift': ['"olcrtc.local.socks"'],
            'App/Core/VPNController.swift': ['"io.github.hotelk52339.olcrtc-ios"']
        }.items():
            text = source(path)
            for token in tokens:
                self.assertIn(token, text, path)
        command = r'for key in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf \"$key\" -E sha256; done'
        self.assertEqual(source('App/Localization/L10nTable.swift').count(command), 2)
        self.assertEqual(source('App/Localization/L10nFrench.swift').count(command), 1)


if __name__ == '__main__':
    unittest.main()
