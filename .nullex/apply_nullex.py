#!/usr/bin/env python3
from pathlib import Path
import plistlib
import re
import sys

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()

BASE_BUNDLE = "com.nightvibes33.nullex"
BASE_GROUP = "group.com.nightvibes33.nullex"
UPSTREAM_SHA = "a57ee911dcaf063e4209e26dd256203dffa072b7"

def replace_text(path: Path, replacements):
    if not path.exists():
        return
    text = path.read_text(encoding="utf-8")
    original = text
    for old, new in replacements:
        text = text.replace(old, new)
    if text != original:
        path.write_text(text, encoding="utf-8")

def rewrite_plist_strings(obj):
    if isinstance(obj, dict):
        return {k: rewrite_plist_strings(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [rewrite_plist_strings(v) for v in obj]
    if isinstance(obj, str):
        # Human-readable product wording only. Runtime identifiers are handled
        # explicitly elsewhere.
        return obj.replace("wBlock", "Nullex")
    return obj

# ---------------------------------------------------------------------------
# Bundle identities
# ---------------------------------------------------------------------------
# Keep the upstream targets, source layout, feature visibility and extension
# count intact. Only identities/display names change.
pbx = ROOT / "wBlock.xcodeproj/project.pbxproj"
replace_text(pbx, [
    ('PRODUCT_BUNDLE_IDENTIFIER = skula.wBlock;', f'PRODUCT_BUNDLE_IDENTIFIER = {BASE_BUNDLE};'),
    ('PRODUCT_BUNDLE_IDENTIFIER = skula.wBlockCoreService;', f'PRODUCT_BUNDLE_IDENTIFIER = {BASE_BUNDLE}.core;'),
    ('PRODUCT_BUNDLE_IDENTIFIER = "skula.wBlock.wBlock-Ads-iOS";', f'PRODUCT_BUNDLE_IDENTIFIER = "{BASE_BUNDLE}.blocker1";'),
    ('PRODUCT_BUNDLE_IDENTIFIER = "skula.wBlock.wBlock-Privacy-iOS";', f'PRODUCT_BUNDLE_IDENTIFIER = "{BASE_BUNDLE}.blocker2";'),
    ('PRODUCT_BUNDLE_IDENTIFIER = "skula.wBlock.wBlock-Security-iOS";', f'PRODUCT_BUNDLE_IDENTIFIER = "{BASE_BUNDLE}.blocker3";'),
    ('PRODUCT_BUNDLE_IDENTIFIER = "skula.wBlock.wBlock-Foreign-iOS";', f'PRODUCT_BUNDLE_IDENTIFIER = "{BASE_BUNDLE}.blocker4";'),
    ('PRODUCT_BUNDLE_IDENTIFIER = "skula.wBlock.wBlock-Custom-iOS";', f'PRODUCT_BUNDLE_IDENTIFIER = "{BASE_BUNDLE}.blocker5";'),
    ('PRODUCT_BUNDLE_IDENTIFIER = "skula.wBlock.wBlock-Scripts--iOS-";', f'PRODUCT_BUNDLE_IDENTIFIER = "{BASE_BUNDLE}.advanced";'),
    ('PRODUCT_BUNDLE_IDENTIFIER = "skula.wBlock.wBlock-Multipurpose-iOS";', f'PRODUCT_BUNDLE_IDENTIFIER = "{BASE_BUNDLE}.multipurpose";'),
    ('PRODUCT_BUNDLE_IDENTIFIER = "skula.wBlock.wBlock-Experimental-iOS";', f'PRODUCT_BUNDLE_IDENTIFIER = "{BASE_BUNDLE}.experimental";'),

    # macOS-only targets are not shipped in this iOS build, but keeping their
    # identities coherent prevents accidental old-brand leakage during builds.
    ('PRODUCT_BUNDLE_IDENTIFIER = "skula.wBlock.wBlock-Ads";', f'PRODUCT_BUNDLE_IDENTIFIER = "{BASE_BUNDLE}.blocker1.macos";'),
    ('PRODUCT_BUNDLE_IDENTIFIER = "skula.wBlock.wBlock-Privacy";', f'PRODUCT_BUNDLE_IDENTIFIER = "{BASE_BUNDLE}.blocker2.macos";'),
    ('PRODUCT_BUNDLE_IDENTIFIER = "skula.wBlock.wBlock-Security";', f'PRODUCT_BUNDLE_IDENTIFIER = "{BASE_BUNDLE}.blocker3.macos";'),
    ('PRODUCT_BUNDLE_IDENTIFIER = "skula.wBlock.wBlock-Foreign";', f'PRODUCT_BUNDLE_IDENTIFIER = "{BASE_BUNDLE}.blocker4.macos";'),
    ('PRODUCT_BUNDLE_IDENTIFIER = "skula.wBlock.wBlock-Custom";', f'PRODUCT_BUNDLE_IDENTIFIER = "{BASE_BUNDLE}.blocker5.macos";'),
    ('PRODUCT_BUNDLE_IDENTIFIER = "skula.wBlock.wBlock-Scripts";', f'PRODUCT_BUNDLE_IDENTIFIER = "{BASE_BUNDLE}.advanced.macos";'),

    # Match upstream wBlock exposure exactly: five generic blocker slots plus
    # the Advanced Safari Web Extension. Do not expose semantic internals.
    ('INFOPLIST_KEY_CFBundleDisplayName = wBlock;', 'INFOPLIST_KEY_CFBundleDisplayName = Nullex;'),
    ('INFOPLIST_KEY_CFBundleDisplayName = "wBlock 1";', 'INFOPLIST_KEY_CFBundleDisplayName = "Nullex 1";'),
    ('INFOPLIST_KEY_CFBundleDisplayName = "wBlock 2";', 'INFOPLIST_KEY_CFBundleDisplayName = "Nullex 2";'),
    ('INFOPLIST_KEY_CFBundleDisplayName = "wBlock 3";', 'INFOPLIST_KEY_CFBundleDisplayName = "Nullex 3";'),
    ('INFOPLIST_KEY_CFBundleDisplayName = "wBlock 4";', 'INFOPLIST_KEY_CFBundleDisplayName = "Nullex 4";'),
    ('INFOPLIST_KEY_CFBundleDisplayName = "wBlock 5";', 'INFOPLIST_KEY_CFBundleDisplayName = "Nullex 5";'),
    ('INFOPLIST_KEY_CFBundleDisplayName = "wBlock Scripts";', 'INFOPLIST_KEY_CFBundleDisplayName = "Nullex Advanced";'),
    ('INFOPLIST_KEY_CFBundleDisplayName = "wBlock Multipurpose";', 'INFOPLIST_KEY_CFBundleDisplayName = "Nullex Multipurpose";'),
    ('INFOPLIST_KEY_CFBundleDisplayName = "wBlock Experimental";', 'INFOPLIST_KEY_CFBundleDisplayName = "Nullex Experimental";'),
])

# Entitlements: the sideload build needs one shared App Group. CloudKit and
# macOS sandbox entitlements are intentionally excluded from the unsigned IPA.
for path in ROOT.rglob("*.entitlements"):
    replace_text(path, [
        ("group.skula.wBlock", BASE_GROUP),
        ("iCloud.skula.wBlock", "iCloud.com.nightvibes33.nullex"),
    ])

main_entitlements = ROOT / "wBlock/wBlock.entitlements"
if main_entitlements.exists():
    with main_entitlements.open("wb") as f:
        plistlib.dump(
            {"com.apple.security.application-groups": [BASE_GROUP]},
            f,
            fmt=plistlib.FMT_XML,
            sort_keys=False,
        )

# Rebrand plist human-readable strings and identifiers.
for path in ROOT.rglob("Info.plist"):
    try:
        with path.open("rb") as f:
            info = plistlib.load(f)
    except Exception:
        continue
    info = rewrite_plist_strings(info)

    # Old group/cloud/url identifiers can exist in plists independently of the
    # target build settings.
    def replace_identifiers(value):
        if isinstance(value, dict):
            return {k: replace_identifiers(v) for k, v in value.items()}
        if isinstance(value, list):
            return [replace_identifiers(v) for v in value]
        if isinstance(value, str):
            return (
                value
                .replace("group.skula.wBlock", BASE_GROUP)
                .replace("iCloud.skula.wBlock", "iCloud.com.nightvibes33.nullex")
                .replace("com.alexanderskula.wblock", BASE_BUNDLE)
                .replace("wblockapp", "nullex")
            )
        return value
    info = replace_identifiers(info)
    with path.open("wb") as f:
        plistlib.dump(info, f, fmt=plistlib.FMT_XML, sort_keys=False)

# Preserve upstream background auto-update support under Nullex identities.
# BGTaskScheduler requires both the permitted identifiers and the matching
# background modes in Info.plist; removing either produces notPermitted.
main_info = ROOT / "wBlock/Info.plist"
if main_info.exists():
    with main_info.open("rb") as f:
        info = plistlib.load(f)
    info["BGTaskSchedulerPermittedIdentifiers"] = [
        f"{BASE_BUNDLE}.filter-update",
        f"{BASE_BUNDLE}.filter-processing",
    ]
    info["UIBackgroundModes"] = ["fetch", "processing"]
    with main_info.open("wb") as f:
        plistlib.dump(info, f, fmt=plistlib.FMT_XML, sort_keys=False)

app_delegate = ROOT / "wBlock/AppDelegate.swift"
replace_text(app_delegate, [
    (
        'private let backgroundTaskIdentifier = "com.alexanderskula.wblock.filter-update"',
        f'private let backgroundTaskIdentifier = "{BASE_BUNDLE}.filter-update"',
    ),
    (
        'private let backgroundProcessingIdentifier = "com.alexanderskula.wblock.filter-processing"',
        f'private let backgroundProcessingIdentifier = "{BASE_BUNDLE}.filter-processing"',
    ),
])

# ---------------------------------------------------------------------------
# SideStore-safe runtime identity
# ---------------------------------------------------------------------------
# SideStore can rewrite the host bundle identifier and App Group. Resolve the
# actual post-signing group from embedded.mobileprovision, then fall back to
# deterministic host-family candidates.
group_identifier = ROOT / "wBlockCoreService/GroupIdentifier.swift"
group_identifier.write_text(r'''import Foundation
#if os(macOS)
import Security
#endif

public enum RuntimeBundleIdentity {
    public static let baseBundleIdentifier = "com.nightvibes33.nullex"
    public static let baseGroupIdentifier = "group.com.nightvibes33.nullex"

    private static let extensionSuffixes: Set<String> = [
        "blocker1", "blocker2", "blocker3", "blocker4", "blocker5",
        "advanced", "multipurpose", "experimental"
    ]

    public static func containingAppBundleIdentifier(
        from bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return baseBundleIdentifier
        }
        let parts = bundleIdentifier.split(separator: ".").map(String.init)
        guard let last = parts.last,
              extensionSuffixes.contains(last),
              parts.count > 1 else {
            return bundleIdentifier
        }
        return parts.dropLast().joined(separator: ".")
    }

    public static func extensionBundleIdentifier(
        _ suffix: String,
        from bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        "\(containingAppBundleIdentifier(from: bundleIdentifier)).\(suffix)"
    }

    public static func provisionedApplicationGroups(
        bundle: Bundle = .main
    ) -> [String] {
        guard let profileURL = bundle.url(
            forResource: "embedded",
            withExtension: "mobileprovision"
        ),
        let data = try? Data(contentsOf: profileURL)
        else { return [] }

        let startMarker = Data("<?xml".utf8)
        let endMarker = Data("</plist>".utf8)
        guard let start = data.range(of: startMarker)?.lowerBound,
              let end = data.range(of: endMarker, options: .backwards)?.upperBound,
              start < end else { return [] }

        let plistData = data.subdata(in: start..<end)
        guard let object = try? PropertyListSerialization.propertyList(
            from: plistData, options: [], format: nil
        ),
        let profile = object as? [String: Any],
        let entitlements = profile["Entitlements"] as? [String: Any],
        let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else { return [] }

        return groups.filter { !$0.isEmpty }
    }

    static func groupCandidates(
        from bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> [String] {
        let family = containingAppBundleIdentifier(from: bundleIdentifier)
        var candidates = provisionedApplicationGroups()
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
        #if os(macOS)
        value = RuntimeBundleIdentity.baseGroupIdentifier
        containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: value
        )
        #else
        let candidates = RuntimeBundleIdentity.groupCandidates()
        var chosen = candidates.first ?? RuntimeBundleIdentity.baseGroupIdentifier
        var resolved: URL?
        for candidate in candidates {
            if let url = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: candidate
            ) {
                chosen = candidate
                resolved = url
                break
            }
        }
        value = chosen
        containerURL = resolved
        #endif
    }

    public static func resolvedContainerURL() -> URL? {
        shared.containerURL
    }

    public var isAvailable: Bool {
        containerURL != nil
    }
}
''', encoding="utf-8")

# Every shared-container call must use the one runtime-resolved URL.
for rel in [
    "wBlock/FilterListLoader.swift",
    "wBlockCoreService/ProtobufDataManager.swift",
    "wBlockCoreService/UserScriptStorageManager.swift",
    "wBlockCoreService/HeadlessLaunch.swift",
    "wBlockCoreService/wBlockCoreService.swift",
    "wBlock/ConcurrentLogManager.swift",
    "wBlock/CloudSyncManager.swift",
]:
    p = ROOT / rel
    if not p.exists():
        continue
    replace_text(p, [
        (
            "FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: GroupIdentifier.shared.value)",
            "GroupIdentifier.resolvedContainerURL()",
        ),
        (
            "fileManager.containerURL(forSecurityApplicationGroupIdentifier: GroupIdentifier.shared.value)",
            "GroupIdentifier.resolvedContainerURL()",
        ),
    ])

# Keep the upstream 5-slot blocker model exactly. Experimental filter lists are
# normal filter inputs distributed by upstream across these five slots; there
# is intentionally no sixth "Experimental" content blocker exposed to users.
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
        let iOSFamily = RuntimeBundleIdentity.containingAppBundleIdentifier()
        targets = [
            ContentBlockerTargetInfo(slot: 1, platform: .macOS, bundleIdentifier: "com.nightvibes33.nullex.blocker1.macos", rulesFilename: "rules_ads_macos.json", displayName: "Nullex 1"),
            ContentBlockerTargetInfo(slot: 2, platform: .macOS, bundleIdentifier: "com.nightvibes33.nullex.blocker2.macos", rulesFilename: "rules_privacy_macos.json", displayName: "Nullex 2"),
            ContentBlockerTargetInfo(slot: 3, platform: .macOS, bundleIdentifier: "com.nightvibes33.nullex.blocker3.macos", rulesFilename: "rules_security_annoyances_macos.json", displayName: "Nullex 3"),
            ContentBlockerTargetInfo(slot: 4, platform: .macOS, bundleIdentifier: "com.nightvibes33.nullex.blocker4.macos", rulesFilename: "rules_foreign_experimental_macos.json", displayName: "Nullex 4"),
            ContentBlockerTargetInfo(slot: 5, platform: .macOS, bundleIdentifier: "com.nightvibes33.nullex.blocker5.macos", rulesFilename: "rules_custom_macos.json", displayName: "Nullex 5"),

            ContentBlockerTargetInfo(slot: 1, platform: .iOS, bundleIdentifier: "\(iOSFamily).blocker1", rulesFilename: "rules_ads_ios.json", displayName: "Nullex 1"),
            ContentBlockerTargetInfo(slot: 2, platform: .iOS, bundleIdentifier: "\(iOSFamily).blocker2", rulesFilename: "rules_privacy_ios.json", displayName: "Nullex 2"),
            ContentBlockerTargetInfo(slot: 3, platform: .iOS, bundleIdentifier: "\(iOSFamily).blocker3", rulesFilename: "rules_security_annoyances_ios.json", displayName: "Nullex 3"),
            ContentBlockerTargetInfo(slot: 4, platform: .iOS, bundleIdentifier: "\(iOSFamily).blocker4", rulesFilename: "rules_foreign_experimental_ios.json", displayName: "Nullex 4"),
            ContentBlockerTargetInfo(slot: 5, platform: .iOS, bundleIdentifier: "\(iOSFamily).blocker5", rulesFilename: "rules_custom_ios.json", displayName: "Nullex 5"),
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

# Safari Advanced extension ID follows the rewritten host family.
safari_setup = ROOT / "wBlock/SafariExtensionSetupSupport.swift"
replace_text(safari_setup, [
    (
        'static let scriptsExtensionIdentifier = "skula.wBlock.wBlock-Scripts--iOS-"',
        'static let scriptsExtensionIdentifier = RuntimeBundleIdentity.extensionBundleIdentifier("advanced")',
    ),
])

# ---------------------------------------------------------------------------
# User-visible branding only
# ---------------------------------------------------------------------------
# Localized resources are safe to rebrand wholesale.
for path in (ROOT / "wBlock").glob("*.lproj/Localizable.strings"):
    replace_text(path, [("wBlock", "Nullex")])

for path in (ROOT / "wBlock Scripts (iOS)/Resources/_locales").glob("*/messages.json"):
    replace_text(path, [("wBlock", "Nullex"), ("Nullex Scripts", "Nullex Advanced")])

manifest = ROOT / "wBlock Scripts (iOS)/Resources/manifest.json"
replace_text(manifest, [("wBlock", "Nullex"), ("Nullex Scripts", "Nullex Advanced")])

# Rebrand visible Swift string literals/comments without renaming modules,
# symbols, notification names, URL schemes, or upstream source URLs.
for path in (ROOT / "wBlock").glob("*.swift"):
    text = path.read_text(encoding="utf-8")
    lines = []
    for line in text.splitlines(keepends=True):
        if "wBlock" not in line:
            lines.append(line)
            continue
        if (
            "import wBlockCoreService" in line
            or "github.com/0xCUB3/wBlock" in line
            or "wblock://" in line
            or "wblock-" in line
            or "wblock_" in line
            or "Notification.Name" in line
            or "NSError(domain:" in line
        ):
            lines.append(line)
            continue
        if '"' in line or line.lstrip().startswith("//"):
            line = line.replace("wBlock", "Nullex")
        lines.append(line)
    branded = "".join(lines).replace("Nullex Scripts", "Nullex Advanced")
    path.write_text(branded, encoding="utf-8")

# WebExtension fallback labels that can surface without localization.
for rel in [
    "wBlock Scripts (iOS)/Resources/pages/popup/popup.js",
    "wBlock Scripts (iOS)/Resources/zapper-content.js",
]:
    replace_text(ROOT / rel, [
        ("Open wBlock", "Open Nullex"),
        ("wBlock Element Zapper", "Nullex Element Zapper"),
        ("wBlock Scripts", "Nullex Advanced"),
    ])

# Keep upstream URLs intact for attribution/legal/source access.
settings = ROOT / "wBlock/SettingsView.swift"
replace_text(settings, [
    ("https://github.com/0xCUB3/Nullex", "https://github.com/0xCUB3/wBlock"),
])

# Source-only GPL notice; not shipped as app UI.
notice = ROOT / "NULLEX_NOTICE.md"
notice.write_text(
    f"""# Nullex

Nullex is a modified GPL-3.0 derivative of wBlock by Alexander Skula / 0xCUB3.

Upstream: https://github.com/0xCUB3/wBlock
Pinned upstream revision: {UPSTREAM_SHA}

Nullex keeps upstream UI/feature visibility intact and changes only branding,
sideload bundle identities, SideStore-safe App Group resolution, and icon assets.
The blocking engine, filter catalog/compiler, userscripts, userstyles, element
zapper, update pipeline, and Safari integration remain derived from upstream.

The complete work remains licensed under GNU GPL v3. See LICENSE.
""",
    encoding="utf-8",
)

print("Nullex minimal upstream-parity overlay applied.")
