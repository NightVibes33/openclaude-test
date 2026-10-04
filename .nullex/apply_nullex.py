#!/usr/bin/env python3
from pathlib import Path
import plistlib
import re
import sys

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()

BASE_BUNDLE = "com.nightvibes33.nullex"
BASE_GROUP = "group.com.nightvibes33.nullex"

def replace_text(path: Path, replacements):
    if not path.exists():
        return
    text = path.read_text(encoding="utf-8")
    original = text
    for old, new in replacements:
        text = text.replace(old, new)
    if text != original:
        path.write_text(text, encoding="utf-8")

# Rebrand bundle identities without renaming upstream source modules/targets.
pbx = ROOT / "wBlock.xcodeproj/project.pbxproj"
pbx_replacements = [
    ('skula.wBlock.wBlock-Scripts--iOS-', f'{BASE_BUNDLE}.scripts'),
    ('skula.wBlock.wBlock-Multipurpose-iOS', f'{BASE_BUNDLE}.multipurpose'),
    ('skula.wBlock.wBlock-Experimental-iOS', f'{BASE_BUNDLE}.experimental'),
    ('skula.wBlock.wBlock-Security-iOS', f'{BASE_BUNDLE}.security'),
    ('skula.wBlock.wBlock-Privacy-iOS', f'{BASE_BUNDLE}.privacy'),
    ('skula.wBlock.wBlock-Foreign-iOS', f'{BASE_BUNDLE}.regional'),
    ('skula.wBlock.wBlock-Custom-iOS', f'{BASE_BUNDLE}.custom'),
    ('skula.wBlock.wBlock-Ads-iOS', f'{BASE_BUNDLE}.ads'),
    ('skula.wBlock.wBlock-Scripts', f'{BASE_BUNDLE}.scripts.macos'),
    ('skula.wBlock.wBlock-Security', f'{BASE_BUNDLE}.security.macos'),
    ('skula.wBlock.wBlock-Privacy', f'{BASE_BUNDLE}.privacy.macos'),
    ('skula.wBlock.wBlock-Foreign', f'{BASE_BUNDLE}.regional.macos'),
    ('skula.wBlock.wBlock-Custom', f'{BASE_BUNDLE}.custom.macos'),
    ('skula.wBlock.wBlock-Ads', f'{BASE_BUNDLE}.ads.macos'),
    ('skula.wBlock.FilterUpdateAgent', f'{BASE_BUNDLE}.FilterUpdateAgent'),
    ('skula.wBlock.FilterUpdateService', f'{BASE_BUNDLE}.FilterUpdateService'),
    ('skula.wBlock.FilterUpdateLoginItem', f'{BASE_BUNDLE}.FilterUpdateLoginItem'),
    ('skula.wBlockCoreService', f'{BASE_BUNDLE}.core'),
    ('PRODUCT_BUNDLE_IDENTIFIER = skula.wBlock;', f'PRODUCT_BUNDLE_IDENTIFIER = {BASE_BUNDLE};'),
    ('INFOPLIST_KEY_CFBundleDisplayName = "wBlock Scripts";', 'INFOPLIST_KEY_CFBundleDisplayName = "Nullex Advanced";'),
    ('INFOPLIST_KEY_CFBundleDisplayName = "wBlock Multipurpose";', 'INFOPLIST_KEY_CFBundleDisplayName = "Nullex Multipurpose";'),
    ('INFOPLIST_KEY_CFBundleDisplayName = "wBlock Experimental";', 'INFOPLIST_KEY_CFBundleDisplayName = "Nullex Experimental";'),
    ('INFOPLIST_KEY_CFBundleDisplayName = "wBlock 1";', 'INFOPLIST_KEY_CFBundleDisplayName = "Nullex Ads";'),
    ('INFOPLIST_KEY_CFBundleDisplayName = "wBlock 2";', 'INFOPLIST_KEY_CFBundleDisplayName = "Nullex Privacy";'),
    ('INFOPLIST_KEY_CFBundleDisplayName = "wBlock 3";', 'INFOPLIST_KEY_CFBundleDisplayName = "Nullex Security";'),
    ('INFOPLIST_KEY_CFBundleDisplayName = "wBlock 4";', 'INFOPLIST_KEY_CFBundleDisplayName = "Nullex Regional";'),
    ('INFOPLIST_KEY_CFBundleDisplayName = "wBlock 5";', 'INFOPLIST_KEY_CFBundleDisplayName = "Nullex Custom";'),
    ('INFOPLIST_KEY_CFBundleDisplayName = wBlock;', 'INFOPLIST_KEY_CFBundleDisplayName = Nullex;'),
]
replace_text(pbx, pbx_replacements)

# Shared identifiers, URL scheme, task identifiers, and human-readable extension metadata.
for path in ROOT.rglob("*.entitlements"):
    replace_text(path, [
        ("group.skula.wBlock", BASE_GROUP),
        ("iCloud.skula.wBlock", "iCloud.com.nightvibes33.nullex"),
    ])

for path in ROOT.rglob("Info.plist"):
    replace_text(path, [
        ("group.skula.wBlock", BASE_GROUP),
        ("iCloud.skula.wBlock", "iCloud.com.nightvibes33.nullex"),
        ("com.alexanderskula.wblock", BASE_BUNDLE),
        ("wblockapp", "nullex"),
        ("wBlock", "Nullex"),
    ])

# Unsigned iOS sideload builds should carry only the entitlement the blocker
# architecture actually needs. Strip CloudKit and macOS sandbox-only keys; those
# can survive project generation and are unnecessary/risky when SideStore resigns.
main_entitlements = ROOT / "wBlock/wBlock.entitlements"
if main_entitlements.exists():
    with main_entitlements.open("rb") as f:
        ent = plistlib.load(f)
    ent = {
        "com.apple.security.application-groups": [
            BASE_GROUP
        ]
    }
    with main_entitlements.open("wb") as f:
        plistlib.dump(ent, f, fmt=plistlib.FMT_XML, sort_keys=False)

# This branch is specifically the unsigned/sideload distribution. Disable
# BGTaskScheduler registration entirely; foreground/manual filter updates remain
# intact and this avoids launch-time policy failures after identifier rewriting.
main_info = ROOT / "wBlock/Info.plist"
if main_info.exists():
    with main_info.open("rb") as f:
        info = plistlib.load(f)
    info.pop("BGTaskSchedulerPermittedIdentifiers", None)
    info.pop("UIBackgroundModes", None)
    info["UIFileSharingEnabled"] = True
    info["LSSupportsOpeningDocumentsInPlace"] = True
    with main_info.open("wb") as f:
        plistlib.dump(info, f, fmt=plistlib.FMT_XML, sort_keys=False)

# Product-name text in localization resources and the Safari Web Extension.
for path in (ROOT / "wBlock").glob("*.lproj/Localizable.strings"):
    replace_text(path, [("wBlock", "Nullex")])
for path in (ROOT / "wBlock Scripts (iOS)/Resources/_locales").glob("*/messages.json"):
    replace_text(path, [("wBlock", "Nullex")])

# User-facing Swift strings only. Keep internal symbol/module names unchanged.
swift_replacements = {
    "wBlock/AppTabView.swift": [
        ('Picker("wBlock"', 'Picker("Nullex"'),
    ],
    "wBlock/ContentView.swift": [
        ("part of wBlock’s essential protection", "part of Nullex’s essential protection"),
        ("in wBlock. Tap to apply", "in Nullex. Tap to apply"),
        ("wBlock will fetch and enable", "Nullex will fetch and enable"),
        ("already exists in wBlock.", "already exists in Nullex."),
        ("already in wBlock.", "already in Nullex."),
        ("wBlock automatically balances and compiles", "Nullex automatically balances and compiles"),
    ],
    "wBlock/SettingsView.swift": [
        ("An existing wBlock configuration", "An existing Nullex configuration"),
        ("when wBlock isn't running", "when Nullex isn't running"),
        ("while wBlock is open", "while Nullex is open"),
        ("Force-quitting wBlock", "Force-quitting Nullex"),
        ('return "wBlock-Backup-', 'return "Nullex-Backup-'),
    ],
    "wBlock/OnboardingView.swift": [
        ("An existing wBlock configuration", "An existing Nullex configuration"),
        ("Set up wBlock", "Set up Nullex"),
        ("Welcome to wBlock!", "Welcome to Nullex!"),
        ("wBlock will automatically recommend", "Nullex will automatically recommend"),
        ("so wBlock can block ads", "so Nullex can block ads"),
        ("Enable 'wBlock Scripts'", "Enable 'Nullex Advanced'"),
        ("wBlock Scripts must be enabled", "Nullex Advanced must be enabled"),
        ("for wBlock Scripts and the 5 content blockers", "for Nullex Advanced and the 5 content blockers"),
    ],
    "wBlock/FilterUpdateShortcuts.swift": [
        ("Update wBlock Filters", "Update Nullex Filters"),
        ("wBlock filter update", "Nullex filter update"),
    ],
    "wBlock/LogsView.swift": [
        ("wBlock_logs_", "Nullex_logs_"),
    ],
    "wBlock/SponsorBlockTransferView.swift": [
        ("wBlock-SponsorBlock-settings", "Nullex-SponsorBlock-settings"),
    ],
}
for rel, reps in swift_replacements.items():
    replace_text(ROOT / rel, reps)

# Keep legal/source links transparent for the GPL derivative.
settings = ROOT / "wBlock/SettingsView.swift"
replace_text(settings, [
    ('https://github.com/0xCUB3/wBlock/issues/new/choose',
     'https://github.com/NightVibes33/openclaude-test/issues'),
    ('https://github.com/0xCUB3/wBlock/blob/main/PRIVACY_POLICY.md',
     'https://github.com/0xCUB3/wBlock/blob/main/PRIVACY_POLICY.md'),
    ('https://github.com/0xCUB3/wBlock#faq',
     'https://github.com/0xCUB3/wBlock#faq'),
])

# SideStore-safe runtime identity and App Group resolution.
group_identifier = ROOT / "wBlockCoreService/GroupIdentifier.swift"
group_identifier.write_text(r'''import Foundation

/// Runtime identity shared by the host app and Safari extensions.
public enum RuntimeBundleIdentity {
    public static let baseBundleIdentifier = "com.nightvibes33.nullex"
    public static let baseGroupIdentifier = "group.com.nightvibes33.nullex"

    private static let knownExtensionSuffixes: Set<String> = [
        "ads", "privacy", "security", "regional", "custom",
        "scripts", "multipurpose", "experimental"
    ]

    public static func containingAppBundleIdentifier(
        from bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return baseBundleIdentifier
        }

        let components = bundleIdentifier.split(separator: ".").map(String.init)
        guard let last = components.last,
              knownExtensionSuffixes.contains(last),
              components.count > 1 else {
            return bundleIdentifier
        }

        return components.dropLast().joined(separator: ".")
    }

    public static func extensionBundleIdentifier(
        _ suffix: String,
        from bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        "\(containingAppBundleIdentifier(from: bundleIdentifier)).\(suffix)"
    }

    public static func isContainingApp(
        _ bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == containingAppBundleIdentifier(from: bundleIdentifier)
    }

    /// Reads the entitlements from the provisioning profile SideStore embeds.
    /// This yields the actual post-resign App Group without private Security APIs.
    public static func provisionedApplicationGroups(
        bundle: Bundle = .main
    ) -> [String] {
        guard let profileURL = bundle.url(
            forResource: "embedded",
            withExtension: "mobileprovision"
        ),
        let profileData = try? Data(contentsOf: profileURL)
        else {
            return []
        }

        let xmlStartMarker = Data("<?xml".utf8)
        let xmlEndMarker = Data("</plist>".utf8)

        guard let start = profileData.range(of: xmlStartMarker)?.lowerBound,
              let endRange = profileData.range(
                of: xmlEndMarker,
                options: .backwards
              ),
              start < endRange.upperBound else {
            return []
        }

        let plistData = profileData.subdata(in: start..<endRange.upperBound)

        guard let object = try? PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ),
        let profile = object as? [String: Any],
        let entitlements = profile["Entitlements"] as? [String: Any],
        let groups = entitlements[
            "com.apple.security.application-groups"
        ] as? [String]
        else {
            return []
        }

        return groups.filter { !$0.isEmpty }
    }

    static func groupCandidates(
        from bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> [String] {
        let family = containingAppBundleIdentifier(from: bundleIdentifier)

        var candidates = provisionedApplicationGroups()

        // SideStore normally rewrites the group alongside the host bundle.
        // Keep both rewritten and original forms for other signers.
        candidates.append("group.\(family)")
        candidates.append(baseGroupIdentifier)

        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Resolves the shared App Group once and exposes the same URL to every
/// download, conversion, logging and Safari-extension path.
public final class GroupIdentifier {
    public static let shared = GroupIdentifier()

    public let value: String
    public let containerURL: URL?

    private init() {
        let resolved = Self.resolve()
        value = resolved.identifier
        containerURL = resolved.url
    }

    private static func resolve(
        fileManager: FileManager = .default
    ) -> (identifier: String, url: URL?) {
        let candidates = RuntimeBundleIdentity.groupCandidates()

        for candidate in candidates {
            if let url = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: candidate
            ) {
                return (candidate, url)
            }
        }

        return (
            candidates.first ?? RuntimeBundleIdentity.baseGroupIdentifier,
            nil
        )
    }

    public static func resolvedContainerURL() -> URL? {
        shared.containerURL
    }

    public var isAvailable: Bool {
        containerURL != nil
    }
}
''', encoding="utf-8")


# All host-side file I/O must use the exact signed App Group resolved above.
replace_text(ROOT / "wBlock/FilterListLoader.swift", [
    ('''    func getSharedContainerURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: GroupIdentifier.shared.value)
    }''',
     '''    func getSharedContainerURL() -> URL? {
        GroupIdentifier.resolvedContainerURL()
    }'''),
])

# Core services use the same resolved URL so conversion and extension reloads
# see the exact same files after SideStore resigning.
for rel in [
    "wBlockCoreService/ProtobufDataManager.swift",
    "wBlockCoreService/UserScriptStorageManager.swift",
    "wBlockCoreService/HeadlessLaunch.swift",
    "wBlockCoreService/wBlockCoreService.swift",
    "wBlock/ConcurrentLogManager.swift",
    "wBlock/CloudSyncManager.swift",
]:
    p = ROOT / rel
    replace_text(p, [
        ('FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: GroupIdentifier.shared.value)',
         'GroupIdentifier.resolvedContainerURL()'),
        ('fileManager.containerURL(forSecurityApplicationGroupIdentifier: GroupIdentifier.shared.value)',
         'GroupIdentifier.resolvedContainerURL()'),
    ])

# Fail with the actual shared-container diagnosis instead of a generic
# "Couldn't download" / conversion failure.
replace_text(ROOT / "wBlock/FilterListUpdater.swift", [
    ('LocalizedStrings.text("Unable to access shared container")',
     'LocalizedStrings.text("Nullex could not access its signed App Group container. Re-sign with App Groups enabled.")'),
])


# The five Safari content blockers must track the sideload-rewritten host family.
targets = ROOT / "wBlockCoreService/ContentBlockerTargets.swift"
targets.write_text(r'''import Foundation

public enum Platform: Sendable {
    case macOS
    case iOS
}

public struct ContentBlockerTargetInfo: Hashable, Sendable {
    public let slot: Int
    public let platform: Platform
    public let bundleIdentifier: String
    public let rulesFilename: String
    public let displayName: String

    init(slot: Int, platform: Platform, bundleIdentifier: String, rulesFilename: String, displayName: String) {
        self.slot = slot
        self.platform = platform
        self.bundleIdentifier = bundleIdentifier
        self.rulesFilename = rulesFilename
        self.displayName = displayName
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bundleIdentifier)
    }

    public static func == (lhs: ContentBlockerTargetInfo, rhs: ContentBlockerTargetInfo) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier
    }
}

public final class ContentBlockerTargetManager {
    public static let shared = ContentBlockerTargetManager()
    public let targets: [ContentBlockerTargetInfo]

    private init() {
        let iosFamily = RuntimeBundleIdentity.containingAppBundleIdentifier()
        targets = [
            ContentBlockerTargetInfo(slot: 1, platform: .macOS, bundleIdentifier: "com.nightvibes33.nullex.ads.macos", rulesFilename: "rules_ads_macos.json", displayName: "Nullex Ads"),
            ContentBlockerTargetInfo(slot: 2, platform: .macOS, bundleIdentifier: "com.nightvibes33.nullex.privacy.macos", rulesFilename: "rules_privacy_macos.json", displayName: "Nullex Privacy"),
            ContentBlockerTargetInfo(slot: 3, platform: .macOS, bundleIdentifier: "com.nightvibes33.nullex.security.macos", rulesFilename: "rules_security_annoyances_macos.json", displayName: "Nullex Security"),
            ContentBlockerTargetInfo(slot: 4, platform: .macOS, bundleIdentifier: "com.nightvibes33.nullex.regional.macos", rulesFilename: "rules_foreign_experimental_macos.json", displayName: "Nullex Regional"),
            ContentBlockerTargetInfo(slot: 5, platform: .macOS, bundleIdentifier: "com.nightvibes33.nullex.custom.macos", rulesFilename: "rules_custom_macos.json", displayName: "Nullex Custom"),

            ContentBlockerTargetInfo(slot: 1, platform: .iOS, bundleIdentifier: "\(iosFamily).ads", rulesFilename: "rules_ads_ios.json", displayName: "Nullex Ads"),
            ContentBlockerTargetInfo(slot: 2, platform: .iOS, bundleIdentifier: "\(iosFamily).privacy", rulesFilename: "rules_privacy_ios.json", displayName: "Nullex Privacy"),
            ContentBlockerTargetInfo(slot: 3, platform: .iOS, bundleIdentifier: "\(iosFamily).security", rulesFilename: "rules_security_annoyances_ios.json", displayName: "Nullex Security"),
            ContentBlockerTargetInfo(slot: 4, platform: .iOS, bundleIdentifier: "\(iosFamily).regional", rulesFilename: "rules_foreign_experimental_ios.json", displayName: "Nullex Regional"),
            ContentBlockerTargetInfo(slot: 5, platform: .iOS, bundleIdentifier: "\(iosFamily).custom", rulesFilename: "rules_custom_ios.json", displayName: "Nullex Custom")
        ]
    }

    public func allTargets(forPlatform platform: Platform) -> [ContentBlockerTargetInfo] {
        targets.filter { $0.platform == platform }.sorted { $0.slot < $1.slot }
    }

    public func targetInfo(forBundleIdentifier bundleIdentifier: String, platform: Platform) -> ContentBlockerTargetInfo? {
        targets.first { $0.platform == platform && $0.bundleIdentifier == bundleIdentifier }
    }
}
''', encoding="utf-8")

# Dynamic Safari Web Extension identifier.
safari_setup = ROOT / "wBlock/SafariExtensionSetupSupport.swift"
replace_text(safari_setup, [
    ('static let scriptsExtensionIdentifier = "com.nightvibes33.nullex.scripts"',
     'static let scriptsExtensionIdentifier = RuntimeBundleIdentity.extensionBundleIdentifier("scripts")'),
    ('static let scriptsExtensionIdentifier = "com.nightvibes33.nullex.scripts.macos"',
     'static let scriptsExtensionIdentifier = "com.nightvibes33.nullex.scripts.macos"'),
])
# The PBX mapping happens after this file was read from upstream, so handle original IDs too.
replace_text(safari_setup, [
    ('static let scriptsExtensionIdentifier = "skula.wBlock.wBlock-Scripts--iOS-"',
     'static let scriptsExtensionIdentifier = RuntimeBundleIdentity.extensionBundleIdentifier("scripts")'),
    ('static let scriptsExtensionIdentifier = "skula.wBlock.wBlock-Scripts"',
     'static let scriptsExtensionIdentifier = "com.nightvibes33.nullex.scripts.macos"'),
])

# Shared per-feature preferences follow the resolved group.
for rel in [
    "wBlockCoreService/PlayerCleanerPreference.swift",
    "wBlockCoreService/DarkReaderAppearancePreference.swift",
    "wBlockCoreService/TubeCleanerDeArrowPreference.swift",
]:
    p = ROOT / rel
    replace_text(p, [
        ('public static let storageSuiteName = "group.skula.wBlock"',
         'public static var storageSuiteName: String { GroupIdentifier.shared.value }'),
        ('"group.skula.wBlock"', '"group.com.nightvibes33.nullex"'),
    ])

# Make reload identity detect the containing app even after SideStore rewrites it.
core = ROOT / "wBlockCoreService/wBlockCoreService.swift"
replace_text(core, [
    ('if Bundle.main.bundleIdentifier == "skula.wBlock" {',
     'if RuntimeBundleIdentity.isContainingApp() {'),
    ('! wBlock: exceptions replicated', '! Nullex: exceptions replicated'),
])

# Remaining exact identifiers that are not public-facing code symbols.
identifier_files = [
    "wBlockCoreService/FilterUpdatePopupStatus.swift",
    "wBlockCoreService/HeadlessLaunch.swift",
    "wBlockCoreService/BlockingPauseStore.swift",
    "wBlockCoreService/UserScriptStorageManager.swift",
    "wBlockCoreService/ProtobufDataManager.swift",
    "wBlock/AppFilterManager.swift",
    "wBlock/ZapperRuleManager.swift",
    "wBlock/CloudSyncManager.swift",
    "wBlock/AutoUpdateLaunchAgentManager.swift",
    "FilterUpdateAgent/main.swift",
    "FilterUpdateLoginItem/main.swift",
]
for rel in identifier_files:
    replace_text(ROOT / rel, [
        ("skula.wBlock", BASE_BUNDLE),
        ("com.skula.wBlock", BASE_BUNDLE),
        ('appendingPathComponent("wBlock")', 'appendingPathComponent("Nullex")'),
    ])

# The old single-blocker constants are retained upstream for compatibility;
# point them at Nullex without changing control flow.
replace_text(ROOT / "wBlock/AppFilterManager.swift", [
    ('"com.nightvibes33.nullex.wBlock-Filters-iOS"', f'"{BASE_BUNDLE}.ads"'),
    ('"com.nightvibes33.nullex.wBlock-Filters"', f'"{BASE_BUNDLE}.ads.macos"'),
    ('"skula.wBlock.wBlock-Filters-iOS"', f'"{BASE_BUNDLE}.ads"'),
    ('"skula.wBlock.wBlock-Filters"', f'"{BASE_BUNDLE}.ads.macos"'),
])

# Update the app URL scheme callsites.
for rel in [
    "wBlock/wBlockApp.swift",
    "wBlock/AppDelegate.swift",
    "wBlockCoreService/WebExtensionRequestHandler.swift",
    "wBlock Scripts (iOS)/Resources/pages/popup/popup.js",
]:
    replace_text(ROOT / rel, [("wblockapp", "nullex")])



# Use the already-resolved shared container URL everywhere the primary
# download/cache loader asks for it.
replace_text(ROOT / "wBlock/FilterListLoader.swift", [
    ('''    func getSharedContainerURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: GroupIdentifier.shared.value)
    }''',
     '''    func getSharedContainerURL() -> URL? {
        GroupIdentifier.shared.containerURL
    }'''),
])

# Keep upstream wBlock UI structure/feature exposure exactly intact.
# Only the product name changes.
app_tabs = ROOT / "wBlock/AppTabView.swift"
replace_text(app_tabs, [
    ('Label("Protection", systemImage:', 'Label("Filters", systemImage:'),
    ('Label("Scripts", systemImage:', 'Label("Userscripts", systemImage:'),
])

# Remove the temporary custom Nullex hero card so the main screen remains
# feature-for-feature upstream.
content = ROOT / "wBlock/ContentView.swift"
if content.exists():
    ct = content.read_text(encoding="utf-8")
    ct = ct.replace('''            Section {
                nullexHeroView
                    .unifiedTabCardSectionRow()
            }

''', '')
    hero_start = ct.find('''    #if os(iOS)
    private var nullexHeroView: some View {''')
    if hero_start >= 0:
        hero_end = ct.find('''    private var userscriptsView: some View {''', hero_start)
        if hero_end >= 0:
            ct = ct[:hero_start] + ct[hero_end:]
    content.write_text(ct, encoding="utf-8")

# Comprehensive user-visible branding scrub. Internal symbol names, protocol
# message keys, module/target names and upstream legal notices are intentionally
# left alone.
for path in (ROOT / "wBlock").rglob("Localizable.strings"):
    replace_text(path, [("wBlock", "Nullex")])
for path in (ROOT / "wBlock").rglob("*.xcstrings"):
    replace_text(path, [("wBlock", "Nullex")])
for path in (ROOT / "wBlock Scripts (iOS)/Resources").rglob("*.json"):
    replace_text(path, [("wBlock", "Nullex")])

ui_swift_files = [
    "wBlock/ContentView.swift",
    "wBlock/SettingsView.swift",
    "wBlock/OnboardingView.swift",
    "wBlock/ApplyChangesProgressView.swift",
    "wBlock/ApplyChangesViewModel.swift",
    "wBlock/UserScriptManagerView.swift",
    "wBlock/BackupManager.swift",
    "wBlock/LogsView.swift",
    "wBlock/SponsorBlockTransferView.swift",
    "wBlock/FilterUpdateShortcuts.swift",
    "wBlock/AppDelegate.swift",
]
ui_call_patterns = [
    r'(Text\(")([^"]*wBlock[^"]*)(")',
    r'(Label\(")([^"]*wBlock[^"]*)(")',
    r'(Button\(")([^"]*wBlock[^"]*)(")',
    r'(String\(localized:\s*")([^"]*wBlock[^"]*)(")',
    r'(LocalizedStrings\.text\(")([^"]*wBlock[^"]*)(")',
    r'(LocalizedStrings\.format\(")([^"]*wBlock[^"]*)(")',
    r'(\.navigationTitle\(")([^"]*wBlock[^"]*)(")',
    r'(\.alert\(")([^"]*wBlock[^"]*)(")',
    r'(\.confirmationDialog\(")([^"]*wBlock[^"]*)(")',
]
for rel in ui_swift_files:
    p = ROOT / rel
    if not p.exists():
        continue
    ui = p.read_text(encoding="utf-8")
    for pattern in ui_call_patterns:
        ui = re.sub(
            pattern,
            lambda m: m.group(1) + m.group(2).replace("wBlock", "Nullex") + m.group(3),
            ui
        )
    p.write_text(ui, encoding="utf-8")

# Replace only user-visible shortcut text; keep upstream Swift symbol/module names.
replace_text(ROOT / "wBlock/FilterUpdateShortcuts.swift", [
    ('"Update wBlock Filters"', '"Update Nullex Filters"'),
    ('"Checks for wBlock filter updates and applies them when available."', '"Checks for Nullex filter updates and applies them when available."'),
    ('"A wBlock filter update is already in progress."', '"A Nullex filter update is already in progress."'),
    ('"wBlock filter update completed."', '"Nullex filter update completed."'),
    ('"wBlock filter update completed with errors."', '"Nullex filter update completed with errors."'),
])


# Real-device sideload hardening.
#
# SideStore rewrites the containing bundle identifier. Background task identifiers
# are not rewritten with it, so avoid registering/scheduling BGTaskScheduler work
# in a rewritten sideload identity. Foreground/manual updates remain available.
app_delegate = ROOT / "wBlock/AppDelegate.swift"
replace_text(app_delegate, [
    ('private let backgroundTaskIdentifier = "com.alexanderskula.wblock.filter-update"',
     'private let backgroundTaskIdentifier = "com.nightvibes33.nullex.filter-update"'),
    ('private let backgroundProcessingIdentifier = "com.alexanderskula.wblock.filter-processing"',
     'private let backgroundProcessingIdentifier = "com.nightvibes33.nullex.filter-processing"'),
    ('        // Register background tasks for filter updates (refresh + processing)\\n        registerBackgroundTasks()',
     '''        // SideStore rewrites the containing bundle identifier but not the
        // permitted BGTask identifiers. Register background work only for the
        // canonical signed identity; sideload builds still update in foreground.
        if canUseBackgroundTaskScheduler {
            registerBackgroundTasks()
        }'''),
    ('        // Schedule only after the persisted interval and due date have loaded.\\n        Task { @MainActor in\\n            await rescheduleBackgroundTasks(reason: "Launch")\\n        }',
     '''        // Schedule only when the runtime identity matches the canonical app.
        if canUseBackgroundTaskScheduler {
            Task { @MainActor in
                await rescheduleBackgroundTasks(reason: "Launch")
            }
        }'''),
    ('    private func registerBackgroundTasks() {',
     '''    private var canUseBackgroundTaskScheduler: Bool {
        false
    }

    private func registerBackgroundTasks() {'''),
    ('    private func rescheduleBackgroundTasks(reason: String) async {\\n        await ProtobufDataManager.shared.waitUntilLoaded()',
     '''    private func rescheduleBackgroundTasks(reason: String) async {
        guard canUseBackgroundTaskScheduler else { return }
        await ProtobufDataManager.shared.waitUntilLoaded()'''),
])

# CloudKit is intentionally stripped from the unsigned sideload build. Upstream
# assumes CloudKit is always available on iOS, which is unsafe after resigning.
cloud = ROOT / "wBlock/CloudSyncManager.swift"
replace_text(cloud, [
    ('''        #else
        return true
        #endif''',
     '''        #else
        // Nullex unsigned/sideload builds do not ship the iCloud entitlement.
        // Never touch CKContainer on these builds.
        return false
        #endif'''),
    ('        isEnabled = defaults.bool(forKey: Keys.enabled)',
     '        isEnabled = Self.hasCloudKitEntitlement && defaults.bool(forKey: Keys.enabled)'),
])

# Files-visible launch diagnostics are enabled above.

# Write a tiny launch marker before any optional background/cloud work.
delegate_text = app_delegate.read_text(encoding="utf-8")
launch_needle = '''    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self'''
launch_replacement = '''    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        writeNullexLaunchMarker("didFinish:start")
        runNullexCISelfTestIfRequested()
        UNUserNotificationCenter.current().delegate = self'''
if launch_needle in delegate_text:
    delegate_text = delegate_text.replace(launch_needle, launch_replacement, 1)

return_needle = '''        PortraitOrientationLock.apply()
        return true'''
return_replacement = '''        PortraitOrientationLock.apply()
        writeNullexLaunchMarker("didFinish:complete")
        return true'''
if return_needle in delegate_text:
    delegate_text = delegate_text.replace(return_needle, return_replacement, 1)

extension_anchor = '''    private func registerBackgroundTasks() {'''
launch_helper = '''    private func runNullexCISelfTestIfRequested() {
        guard ProcessInfo.processInfo.environment["NULLEX_CI_SELFTEST"] == "1" else {
            return
        }

        Task { @MainActor in
            guard let groupURL = GroupIdentifier.shared.containerURL else {
                writeNullexLaunchMarker("selftest:failed reason=app-group-unavailable")
                return
            }

            do {
                let url = URL(string: "https://easylist.to/easylist/easylist.txt")!
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode),
                      data.count > 1024 else {
                    writeNullexLaunchMarker("selftest:failed reason=bad-filter-response")
                    return
                }

                let testURL = groupURL.appendingPathComponent("nullex-ci-filter.txt")
                try data.write(to: testURL, options: .atomic)
                let size = (try? testURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size == data.count else {
                    writeNullexLaunchMarker("selftest:failed reason=shared-write-mismatch")
                    return
                }

                writeNullexLaunchMarker("selftest:download-ok bytes=\\(data.count)")
            } catch {
                writeNullexLaunchMarker("selftest:failed reason=\(error.localizedDescription)")
            }
        }
    }

    private func writeNullexLaunchMarker(_ event: String) {
        let fm = FileManager.default
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let url = base.appendingPathComponent("Nullex-Launch.txt")
        let line = "\\(Date().timeIntervalSince1970) \\(event) bundle=\\(Bundle.main.bundleIdentifier ?? "nil") group=\\(GroupIdentifier.shared.value)\\n"
        if let data = line.data(using: .utf8) {
            if fm.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

'''
if extension_anchor in delegate_text and "writeNullexLaunchMarker(_ event:" not in delegate_text:
    delegate_text = delegate_text.replace(extension_anchor, launch_helper + extension_anchor, 1)
app_delegate.write_text(delegate_text, encoding="utf-8")



# Keep upstream wBlock UI/feature visibility exactly intact; only rebrand
# user-facing text. Internal symbols/modules stay untouched.
import re as _re

def _rebrand_swift_string_literals(path: Path):
    if not path.exists():
        return
    source = path.read_text(encoding="utf-8")
    pattern = _re.compile(r'"(?:\\.|[^"\\])*"')
    def repl(match):
        literal = match.group(0)
        if "wBlock" not in literal:
            return literal
        # Preserve upstream/legal URLs while removing product-name leakage.
        if "github.com/0xCUB3/wBlock" in literal or "raw.githubusercontent.com/0xCUB3/wBlock" in literal:
            return literal
        return literal.replace("wBlock", "Nullex")
    updated = pattern.sub(repl, source)
    if updated != source:
        path.write_text(updated, encoding="utf-8")

for _path in ROOT.rglob("*.swift"):
    _rebrand_swift_string_literals(_path)

# Localized UI and Safari extension locale resources.
for _path in ROOT.rglob("*.strings"):
    replace_text(_path, [("wBlock", "Nullex")])
for _path in ROOT.rglob("messages.json"):
    replace_text(_path, [("wBlock", "Nullex")])

# Safari extension scripts have a handful of visible labels/messages.
for _rel in [
    "wBlock Scripts (iOS)/Resources/no-autoplay.js",
    "wBlock Scripts (iOS)/Resources/zapper-content.js",
    "wBlock Scripts (iOS)/Resources/userscript-injector.js",
    "wBlock Scripts (iOS)/Resources/pages/popup/popup.js",
]:
    replace_text(ROOT / _rel, [("wBlock", "Nullex")])

# Keep the upstream screen/layout hierarchy; Nullex must not expose extra
# controls merely because it is a rebrand.


# Complete user-facing rebrand. Preserve internal Swift/module symbols and protocol
# message names; only resource/display text is changed.
for path in ROOT.rglob("*"):
    if not path.is_file():
        continue
    if path.suffix.lower() not in {".strings", ".xcstrings", ".json", ".html", ".css"}:
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except Exception:
        continue
    if "wBlock" in text:
        path.write_text(text.replace("wBlock", "Nullex"), encoding="utf-8")

# Target remaining obvious user-facing Swift literals while leaving identifiers alone.
for rel in [
    "wBlock/ContentView.swift",
    "wBlock/SettingsView.swift",
    "wBlock/OnboardingView.swift",
    "wBlock/ApplyChangesProgressView.swift",
    "wBlock/UserScriptManagerView.swift",
    "wBlock/LogsView.swift",
    "wBlock/BackupManager.swift",
    "wBlock/SponsorBlockTransferView.swift",
    "wBlock/AppTabView.swift",
    "wBlock/FilterFallbacksView.swift",
    "wBlock/FilterUpdateShortcuts.swift",
    "wBlock/FilterCategorySupport.swift",
    "wBlock/FilterInfoView.swift",
    "wBlock/SiteSettingsView.swift",
]:
    p = ROOT / rel
    if not p.exists():
        continue
    text = p.read_text(encoding="utf-8")
    # Replace only quoted string contents on a line; never Swift identifiers.
    lines = []
    for line in text.splitlines(keepends=True):
        if "wBlock" in line and '"' in line:
            line = line.replace("wBlock", "Nullex")
        lines.append(line)
    branded = "".join(lines).replace("Nullex Scripts", "Nullex Advanced")
    p.write_text(branded, encoding="utf-8")

# Keep localized extension instructions consistent with the actual extension name.
for path in ROOT.rglob("*"):
    if not path.is_file() or path.suffix.lower() not in {".strings", ".xcstrings", ".json", ".html"}:
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except Exception:
        continue
    if "Nullex Scripts" in text:
        path.write_text(text.replace("Nullex Scripts", "Nullex Advanced"), encoding="utf-8")




# Preserve upstream legal/FAQ/source URLs after the visible-string rebrand.
replace_text(ROOT / "wBlock/SettingsView.swift", [
    ("https://github.com/0xCUB3/Nullex/blob/main/PRIVACY_POLICY.md",
     "https://github.com/0xCUB3/wBlock/blob/main/PRIVACY_POLICY.md"),
    ("https://github.com/0xCUB3/Nullex#faq",
     "https://github.com/0xCUB3/wBlock#faq"),
    ("https://github.com/0xCUB3/Nullex",
     "https://github.com/0xCUB3/wBlock"),
])



# Remaining WebExtension fallback labels can surface if localization lookup fails.
for rel in [
    "wBlock Scripts (iOS)/Resources/background.js",
    "wBlock Scripts (iOS)/Resources/pages/popup/popup.js",
    "wBlock Scripts (iOS)/Resources/zapper-content.js",
]:
    p = ROOT / rel
    if not p.exists():
        continue
    replace_text(p, [
        ("wBlock Scripts", "Nullex Advanced"),
        ("Open wBlock", "Open Nullex"),
        ("wBlock Element Zapper", "Nullex Element Zapper"),
    ])


# Safari popup/accessibility fallbacks are user-facing even though they live in JS.
replace_text(ROOT / "wBlock Scripts (iOS)/Resources/pages/popup/popup.js", [
    ("Open wBlock to finish applying filters.", "Open Nullex to finish applying filters."),
    ("Open wBlock to resume blocking.", "Open Nullex to resume blocking."),
    ("'Open wBlock'", "'Open Nullex'"),
    ('"Open wBlock"', '"Open Nullex"'),
])
replace_text(ROOT / "wBlock Scripts (iOS)/Resources/zapper-content.js", [
    ("'wBlock Element Zapper'", "'Nullex Element Zapper'"),
    ('"wBlock Element Zapper"', '"Nullex Element Zapper"'),
])



# Resolve the ACTUAL signed App Group after SideStore/re-signing.
# This is the critical storage fix: downloads, conversion output, the Safari
# blockers, and the WebExtension must all select the same entitlement-backed group.
group_identifier = ROOT / "wBlockCoreService/GroupIdentifier.swift"
group_identifier.write_text(r'''import Foundation
import Security

public enum RuntimeBundleIdentity {
    public static let baseBundleIdentifier = "com.nightvibes33.nullex"
    public static let baseGroupIdentifier = "group.com.nightvibes33.nullex"

    private static let knownExtensionSuffixes = [
        "ads", "privacy", "security", "regional", "custom",
        "scripts", "multipurpose", "experimental"
    ]

    public static func containingAppBundleIdentifier(
        from bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return baseBundleIdentifier
        }
        let components = bundleIdentifier.split(separator: ".").map(String.init)
        if let last = components.last, knownExtensionSuffixes.contains(last), components.count > 1 {
            return components.dropLast().joined(separator: ".")
        }
        return bundleIdentifier
    }

    public static func extensionBundleIdentifier(
        _ suffix: String,
        from bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        "\(containingAppBundleIdentifier(from: bundleIdentifier)).\(suffix)"
    }

    public static func isContainingApp(
        _ bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == containingAppBundleIdentifier(from: bundleIdentifier)
    }

    public static func signedApplicationGroups() -> [String] {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault),
              let raw = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.security.application-groups" as CFString,
                nil
              ) else {
            return []
        }
        return raw as? [String] ?? []
    }

    static func groupCandidates(
        from bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> [String] {
        let family = containingAppBundleIdentifier(from: bundleIdentifier)
        var candidates = signedApplicationGroups()
        candidates.append("group.\(family)")
        candidates.append(baseGroupIdentifier)

        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

public final class GroupIdentifier {
    public static let shared = GroupIdentifier()

    public let value: String
    public let containerURL: URL?

    private init() {
        let fm = FileManager.default

        // Signed entitlements are authoritative. This survives identifiers such as
        // com.nightvibes33.nullex.39A8Q3T3TR and whatever App Group the signer emits.
        for candidate in RuntimeBundleIdentity.groupCandidates() {
            if let url = fm.containerURL(forSecurityApplicationGroupIdentifier: candidate) {
                value = candidate
                containerURL = url
                return
            }
        }

        // Keep a stable value for diagnostics. Callers must treat containerURL == nil
        // as a signing/capability failure instead of silently writing somewhere else.
        value = RuntimeBundleIdentity.signedApplicationGroups().first
            ?? RuntimeBundleIdentity.baseGroupIdentifier
        containerURL = nil
    }
}
''', encoding="utf-8")

# Make the loader use the already-resolved container instead of guessing again.
replace_text(ROOT / "wBlock/FilterListLoader.swift", [
    ('''    func getSharedContainerURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: GroupIdentifier.shared.value)
    }''',
     '''    func getSharedContainerURL() -> URL? {
        GroupIdentifier.shared.containerURL
    }''')
])

# Better user-visible failure diagnostics during Apply. The previous generic
# "Failed" hid the actual converter/storage error.
apply_pipeline = ROOT / "wBlock/AppFilterManager+ApplyPipeline.swift"
replace_text(apply_pipeline, [
    ('''        let resolvedStatusMessage = statusMessage
            ?? LocalizedStrings.text("Failed", comment: "Generic failure status")''',
     '''        let resolvedStatusMessage = statusMessage
            ?? metadata["error"].map { "Failed: \($0)" }
            ?? logMessage''')
])

# Surface a concrete storage error when Get/download cannot publish a list.
updater = ROOT / "wBlock/FilterListUpdater.swift"
replace_text(updater, [
    ('''        guard let containerURL = loader.getSharedContainerURL() else {
            await ConcurrentLogManager.shared.error(
                .system, LocalizedStrings.text("Unable to access shared container"), metadata: [:])
            return .failed
        }''',
     '''        guard let containerURL = loader.getSharedContainerURL() else {
            let groups = RuntimeBundleIdentity.signedApplicationGroups().joined(separator: ", ")
            let message = groups.isEmpty
                ? "Shared App Group is unavailable after signing."
                : "Shared App Group could not be opened: \(groups)"
            await ConcurrentLogManager.shared.error(
                .system,
                LocalizedStrings.text("Unable to access shared container"),
                metadata: ["error": message, "group": GroupIdentifier.shared.value]
            )
            await MainActor.run {
                filterListManager?.statusDescription = message
                filterListManager?.hasError = true
            }
            return .failed
        }''')
])

# Extend the Files-visible launch diagnostics so a real device immediately tells
# us the signed groups and whether the shared container actually resolved.
app_delegate = ROOT / "wBlock/AppDelegate.swift"
replace_text(app_delegate, [
    ('''        let line = "\(Date().timeIntervalSince1970) \(event) bundle=\(Bundle.main.bundleIdentifier ?? "nil") group=\(GroupIdentifier.shared.value)\n"''',
     '''        let signedGroups = RuntimeBundleIdentity.signedApplicationGroups().joined(separator: ",")
        let available = GroupIdentifier.shared.containerURL != nil ? "1" : "0"
        let line = "\(Date().timeIntervalSince1970) \(event) bundle=\(Bundle.main.bundleIdentifier ?? "nil") group=\(GroupIdentifier.shared.value) groupContainer=\(available) signedGroups=\(signedGroups)\n"''')
])

# Finish the user-visible rebrand while preserving upstream legal/source attribution.
visible_replacements = {
    "wBlock/FilterFallbacksView.swift": [
        ("If the source URL fails, wBlock tries these URLs in order.",
         "If the source URL fails, Nullex tries these URLs in order."),
    ],
    "wBlock/FilterUpdateShortcuts.swift": [
        ("Update wBlock Filters", "Update Nullex Filters"),
        ("Checks for wBlock filter updates and applies them when available.",
         "Checks for Nullex filter updates and applies them when available."),
        ("A wBlock filter update is already in progress.", "A Nullex filter update is already in progress."),
        ("wBlock filter update completed.", "Nullex filter update completed."),
        ("wBlock filter update completed with errors.", "Nullex filter update completed with errors."),
    ],
    "wBlock/FilterCategorySupport.swift": [
        ("Organizes userscripts and userstyles added to wBlock.",
         "Organizes userscripts and userstyles added to Nullex."),
    ],
    "wBlock/AppFilterManager.swift": [
        ("Total capacity (all wBlock blockers):", "Total capacity (all Nullex blockers):"),
        ("wBlock distributes your enabled filter lists", "Nullex distributes your enabled filter lists"),
    ],
    "wBlock/OnboardingView.swift": [
        ("An existing wBlock configuration", "An existing Nullex configuration"),
        ("Set up wBlock", "Set up Nullex"),
        ("Welcome to wBlock!", "Welcome to Nullex!"),
        ("wBlock will automatically recommend", "Nullex will automatically recommend"),
        ("so wBlock can block ads", "so Nullex can block ads"),
        ("Enable 'wBlock Scripts'", "Enable 'Nullex Advanced'"),
        ("wBlock Scripts must be enabled", "Nullex Advanced must be enabled"),
        ("for wBlock Scripts and the 5 content blockers", "for Nullex Advanced and the 5 content blockers"),
    ],
    "wBlock/SettingsView.swift": [
        ("An existing wBlock configuration", "An existing Nullex configuration"),
        ("when wBlock isn't running", "when Nullex isn't running"),
        ("while wBlock is open", "while Nullex is open"),
        ("Force-quitting wBlock", "Force-quitting Nullex"),
        ('return "wBlock-Backup-', 'return "Nullex-Backup-'),
        ("updates run while wBlock is open", "updates run while Nullex is open"),
    ],
    "wBlock/LogsView.swift": [
        ("wBlock_logs_", "Nullex_logs_"),
    ],
    "wBlock/SponsorBlockTransferView.swift": [
        ("wBlock-SponsorBlock-settings", "Nullex-SponsorBlock-settings"),
    ],
    "wBlock/ConcurrentLogManager.swift": [
        ("wBlock launched", "Nullex launched"),
        ("wBlock Logs Export", "Nullex Logs Export"),
        ('appendingPathComponent("wBlock", isDirectory: true)',
         'appendingPathComponent("Nullex", isDirectory: true)'),
    ],
}
for rel, reps in visible_replacements.items():
    replace_text(ROOT / rel, reps)

# Localization keys/values are user-facing. Rebrand them in every shipped locale.
for path in (ROOT / "wBlock").glob("*.lproj/Localizable.strings"):
    replace_text(path, [("wBlock", "Nullex")])

# Safari extension localization is also user-facing.
for path in (ROOT / "wBlock Scripts (iOS)/Resources/_locales").glob("*/messages.json"):
    replace_text(path, [("wBlock", "Nullex")])


# Mark derivative clearly and retain GPL attribution.
notice = ROOT / "NULLEX_NOTICE.md"
notice.write_text("""# Nullex

Nullex is a modified GPL-3.0 derivative of wBlock by Alexander Skula / 0xCUB3.

Upstream: https://github.com/0xCUB3/wBlock
Pinned upstream revision: 98539c863ca42098b62895e1fa1798eaed9e84de

Changes in this build include Nullex branding, bundle/app-group identities,
sideload-safe runtime identifier resolution, SideStore-compatible shared storage,
and Nullex icon assets. The visible app hierarchy intentionally follows upstream. The blocking engine, filter compiler, userscript engine,
userstyle support, element zapper, update pipeline, and Safari integration are
derived from wBlock.

The complete work remains licensed under GNU GPL v3. See LICENSE.
""", encoding="utf-8")

print("Nullex overlay applied.")
