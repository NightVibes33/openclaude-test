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

# Sideload builds should not depend on CloudKit capability. Local backup remains available.
main_entitlements = ROOT / "wBlock/wBlock.entitlements"
if main_entitlements.exists():
    with main_entitlements.open("rb") as f:
        ent = plistlib.load(f)
    ent.pop("com.apple.developer.icloud-container-identifiers", None)
    ent.pop("com.apple.developer.icloud-services", None)
    with main_entitlements.open("wb") as f:
        plistlib.dump(ent, f, fmt=plistlib.FMT_XML, sort_keys=False)

# Product-name text in localization resources and the Safari Web Extension.
for path in (ROOT / "wBlock").glob("*.lproj/Localizable.strings"):
    replace_text(path, [("wBlock", "Nullex")])
for path in (ROOT / "wBlock Scripts (iOS)/Resources/_locales").glob("*/messages.json"):
    replace_text(path, [("wBlock", "Nullex")])

# User-facing Swift strings only. Keep internal symbol/module names unchanged.
swift_replacements = {
    "wBlock/AppTabView.swift": [
        ('Picker("wBlock"', 'Picker("Nullex"'),
        ('Label("Filters", systemImage:', 'Label("Protection", systemImage:'),
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
#if os(macOS)
import Security
#endif

/// Runtime bundle identity used by the app and all embedded extensions.
///
/// Sideloading tools can rewrite a bundle family, for example:
/// com.nightvibes33.nullex -> com.nightvibes33.nullex.<token>
/// and then append each extension suffix.  Nullex resolves the containing app
/// family at runtime so Safari extension IDs and the shared App Group stay in sync.
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
        guard components.count > 1 else { return bundleIdentifier }

        if let last = components.last, knownExtensionSuffixes.contains(last) {
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

    static func groupCandidates(
        from bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> [String] {
        let family = containingAppBundleIdentifier(from: bundleIdentifier)
        var candidates = [
            "group.\(family)",
            baseGroupIdentifier,
        ]

        // Some signers preserve the base App Group even after rewriting bundle IDs.
        if family.hasPrefix(baseBundleIdentifier + ".") {
            candidates.append(baseGroupIdentifier)
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }
}

/// GroupIdentifier provides access to the shared App Group container.
public final class GroupIdentifier {
    public static let shared = GroupIdentifier()
    public let value: String

    private init() {
        #if os(macOS)
        value = Self.resolvedMacOSGroupIdentifier()
        #else
        value = Self.resolvedMobileGroupIdentifier()
        #endif
    }

    #if !os(macOS)
    private static func resolvedMobileGroupIdentifier() -> String {
        for candidate in RuntimeBundleIdentity.groupCandidates() {
            if FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: candidate
            ) != nil {
                return candidate
            }
        }
        return RuntimeBundleIdentity.baseGroupIdentifier
    }
    #endif

    #if os(macOS)
    private static func resolvedMacOSGroupIdentifier() -> String {
        if let identifier = teamPrefixedApplicationGroupFromSigningEntitlements() {
            return identifier
        }

        if let prefix = Bundle.main.infoDictionary?["AppIdentifierPrefix"] as? String,
           let identifier = applicationGroupIdentifier(withAppIdentifierPrefix: prefix) {
            return identifier
        }

        return RuntimeBundleIdentity.baseGroupIdentifier
    }

    private static func applicationGroupIdentifier(withAppIdentifierPrefix prefix: String) -> String? {
        guard !prefix.isEmpty, !prefix.contains("$(") else { return nil }
        if prefix.hasSuffix(".") {
            return "\(prefix)\(RuntimeBundleIdentity.baseGroupIdentifier)"
        }
        return "\(prefix).\(RuntimeBundleIdentity.baseGroupIdentifier)"
    }

    private static func teamPrefixedApplicationGroupFromSigningEntitlements() -> String? {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault),
              let entitlement = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.security.application-groups" as CFString,
                nil
              ),
              let applicationGroups = entitlement as? [String]
        else {
            return nil
        }

        let suffix = ".\(RuntimeBundleIdentity.baseGroupIdentifier)"
        return applicationGroups.first { $0.hasSuffix(suffix) }
    }
    #endif
}
''', encoding="utf-8")

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

# Add a compact branded hero to the iPhone Protection tab while leaving the
# underlying wBlock list engine and controls intact.
content = ROOT / "wBlock/ContentView.swift"
text = content.read_text(encoding="utf-8")
needle = '''        return List {
            Section {
                statsCardsView
                    .unifiedTabCardSectionRow()
            }
'''
replacement = '''        return List {
            Section {
                nullexHeroView
                    .unifiedTabCardSectionRow()
            }

            Section {
                statsCardsView
                    .unifiedTabCardSectionRow()
            }
'''
if needle in text:
    text = text.replace(needle, replacement, 1)

anchor = '''    private var userscriptsView: some View {
'''
hero = r'''    #if os(iOS)
    private var nullexHeroView: some View {
        HStack(spacing: 14) {
            Image("NullexMark")
                .resizable()
                .scaledToFill()
                .frame(width: 62, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .shadow(radius: 10, y: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text("Nullex")
                    .font(.title2.bold())
                Text(filterManager.isBlockingPaused ? "Protection paused" : "Safari protection ready")
                    .font(.subheadline)
                    .foregroundStyle(filterManager.isBlockingPaused ? .orange : .secondary)

                Text("\(enabledListsCount) lists • \(appliedSafariRulesCount.formatted()) Safari rules")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCompat(cornerRadius: 22)
    }
    #endif

'''
if anchor in text and "private var nullexHeroView" not in text:
    text = text.replace(anchor, hero + anchor, 1)
content.write_text(text, encoding="utf-8")

# Rename main iOS tab titles while keeping feature semantics.
replace_text(ROOT / "wBlock/AppTabView.swift", [
    ('Label("Userscripts", systemImage:', 'Label("Scripts", systemImage:'),
])

# Mark derivative clearly and retain GPL attribution.
notice = ROOT / "NULLEX_NOTICE.md"
notice.write_text("""# Nullex

Nullex is a modified GPL-3.0 derivative of wBlock by Alexander Skula / 0xCUB3.

Upstream: https://github.com/0xCUB3/wBlock
Pinned upstream revision: 98539c863ca42098b62895e1fa1798eaed9e84de

Changes in this build include Nullex branding, bundle/app-group identities,
sideload-safe runtime identifier resolution, an iPhone-first Protection header,
and Nullex icon assets. The blocking engine, filter compiler, userscript engine,
userstyle support, element zapper, update pipeline, and Safari integration are
derived from wBlock.

The complete work remains licensed under GNU GPL v3. See LICENSE.
""", encoding="utf-8")

print("Nullex overlay applied.")
