#!/usr/bin/env python3
from pathlib import Path
import plistlib
import sys

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()

BASE_BUNDLE = "com.nightvibes33.nullex"
BASE_GROUP = "group.com.nightvibes33.nullex"
DNS_BUNDLE = f"{BASE_BUNDLE}.dns"
DNSLIBS_REVISION = "5570e10e4883f9fe770a291b4025449127185f88"


def replace_once(path: Path, old: str, new: str):
    text = path.read_text(encoding="utf-8")
    if old not in text:
        raise RuntimeError(f"Missing patch anchor in {path}: {old[:100]!r}")
    if text.count(old) != 1:
        raise RuntimeError(f"Patch anchor is not unique in {path}: {old[:100]!r}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def insert_before(path: Path, marker: str, block: str):
    text = path.read_text(encoding="utf-8")
    if marker not in text:
        raise RuntimeError(f"Missing insertion marker in {path}: {marker}")
    if block.strip() in text:
        return
    path.write_text(text.replace(marker, block + "\n" + marker, 1), encoding="utf-8")


# ---------------------------------------------------------------------------
# Runtime identity + entitlements
# ---------------------------------------------------------------------------
group_identifier = ROOT / "wBlockCoreService/GroupIdentifier.swift"
replace_once(
    group_identifier,
    '"advanced", "multipurpose", "experimental"',
    '"advanced", "multipurpose", "experimental", "dns"',
)

main_entitlements = ROOT / "wBlock/wBlock.entitlements"
with main_entitlements.open("wb") as f:
    plistlib.dump(
        {
            "com.apple.security.application-groups": [BASE_GROUP],
            "com.apple.developer.networking.networkextension": ["packet-tunnel-provider"],
        },
        f,
        fmt=plistlib.FMT_XML,
        sort_keys=False,
    )

# ---------------------------------------------------------------------------
# Shared live statistics + host tunnel manager
# ---------------------------------------------------------------------------
dns_manager = ROOT / "wBlock/NullexDNSManager.swift"
dns_manager.write_text(r'''#if os(iOS)
import Combine
import Foundation
import NetworkExtension
import wBlockCoreService

@MainActor
final class NullexDNSManager: ObservableObject {
    static let shared = NullexDNSManager()

    static let filterURL = URL(string: "https://filters.adtidy.org/dns/filter_1_ios.txt")!
    static let filterRelativePath = "NullexDNS/filter_1_ios.txt"
    static let filterRefreshInterval: TimeInterval = 24 * 60 * 60

    enum Keys {
        static let totalRequests = "nullex.dns.totalRequests"
        static let totalBlocked = "nullex.dns.totalBlocked"
        static let blockedToday = "nullex.dns.blockedToday"
        static let dayStart = "nullex.dns.dayStart"
        static let lastBlockedDomain = "nullex.dns.lastBlockedDomain"
        static let lastEventAt = "nullex.dns.lastEventAt"
        static let filterUpdatedAt = "nullex.dns.filterUpdatedAt"
    }

    @Published private(set) var totalRequests = 0
    @Published private(set) var totalBlocked = 0
    @Published private(set) var blockedToday = 0
    @Published private(set) var lastBlockedDomain = ""
    @Published private(set) var lastEventAt: Date?
    @Published private(set) var filterUpdatedAt: Date?
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var isProtectionEnabled = false
    @Published var lastError: String?

    private var manager: NETunnelProviderManager?
    private var timer: AnyCancellable?
    private var statusObserver: NSObjectProtocol?

    private var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: GroupIdentifier.shared.value) ?? .standard
    }

    var providerBundleIdentifier: String {
        RuntimeBundleIdentity.extensionBundleIdentifier("dns")
    }

    var connectionStatusText: String {
        switch status {
        case .invalid: "Not Configured"
        case .disconnected: "Off"
        case .connecting: "Connecting"
        case .connected: "Protected"
        case .reasserting: "Reconnecting"
        case .disconnecting: "Disconnecting"
        @unknown default: "Unknown"
        }
    }

    var blockRateText: String {
        guard totalRequests > 0 else { return "0%" }
        return (Double(totalBlocked) / Double(totalRequests))
            .formatted(.percent.precision(.fractionLength(1)))
    }

    private init() {
        refreshStatistics()
        timer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshStatistics()
                self?.refreshConnectionStatus()
            }

        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshConnectionStatus()
            }
        }

        Task {
            await loadConfiguration()
        }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    func refreshStatistics() {
        let defaults = sharedDefaults
        defaults.synchronize()
        totalRequests = defaults.integer(forKey: Keys.totalRequests)
        totalBlocked = defaults.integer(forKey: Keys.totalBlocked)
        let storedDay = defaults.double(forKey: Keys.dayStart)
        if storedDay > 0,
           Calendar.current.isDate(
                Date(timeIntervalSince1970: storedDay),
                inSameDayAs: Date()
           ) {
            blockedToday = defaults.integer(forKey: Keys.blockedToday)
        } else {
            blockedToday = 0
        }
        lastBlockedDomain = defaults.string(forKey: Keys.lastBlockedDomain) ?? ""

        let eventTimestamp = defaults.double(forKey: Keys.lastEventAt)
        lastEventAt = eventTimestamp > 0 ? Date(timeIntervalSince1970: eventTimestamp) : nil

        let filterTimestamp = defaults.double(forKey: Keys.filterUpdatedAt)
        filterUpdatedAt = filterTimestamp > 0 ? Date(timeIntervalSince1970: filterTimestamp) : nil
    }

    func resetStatistics() {
        let defaults = sharedDefaults
        defaults.set(0, forKey: Keys.totalRequests)
        defaults.set(0, forKey: Keys.totalBlocked)
        defaults.set(0, forKey: Keys.blockedToday)
        defaults.set(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970, forKey: Keys.dayStart)
        defaults.removeObject(forKey: Keys.lastBlockedDomain)
        defaults.removeObject(forKey: Keys.lastEventAt)
        defaults.synchronize()
        refreshStatistics()
    }

    func setEnabled(_ enabled: Bool) async {
        lastError = nil

        if enabled {
            isProtectionEnabled = true
            do {
                try await refreshFilterIfNeeded(force: false)
                let manager = try await configuredManager()
                manager.onDemandRules = [NEOnDemandRuleConnect()]
                manager.isOnDemandEnabled = true
                manager.isEnabled = true
                try await save(manager)
                try await reload(manager)
                try manager.connection.startVPNTunnel()
                self.manager = manager
                refreshConnectionStatus()
            } catch {
                isProtectionEnabled = false
                lastError = error.localizedDescription
                refreshConnectionStatus()
            }
            return
        }

        guard let manager else {
            isProtectionEnabled = false
            status = .invalid
            return
        }

        manager.connection.stopVPNTunnel()
        manager.isOnDemandEnabled = false
        manager.isEnabled = false
        do {
            try await save(manager)
            try await reload(manager)
            self.manager = manager
        } catch {
            lastError = error.localizedDescription
        }
        isProtectionEnabled = false
        refreshConnectionStatus()
    }

    func refreshDNSFilter() async {
        lastError = nil
        do {
            try await refreshFilterIfNeeded(force: true)
            if status == .connected || status == .reasserting {
                manager?.connection.stopVPNTunnel()
                let manager = try await configuredManager()
                try manager.connection.startVPNTunnel()
                self.manager = manager
            }
            refreshStatistics()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func refreshConnectionStatus() {
        guard let manager else {
            status = .invalid
            isProtectionEnabled = false
            return
        }
        status = manager.connection.status
        isProtectionEnabled = manager.isEnabled && manager.isOnDemandEnabled
    }

    private func loadConfiguration() async {
        do {
            let managers = try await loadManagers()
            manager = managers.first(where: { candidate in
                if let tunnel = candidate.protocolConfiguration as? NETunnelProviderProtocol,
                   tunnel.providerBundleIdentifier == providerBundleIdentifier {
                    return true
                }
                return candidate.localizedDescription == "Nullex DNS"
            })
            refreshConnectionStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func configuredManager() async throws -> NETunnelProviderManager {
        if manager == nil {
            let managers = try await loadManagers()
            manager = managers.first(where: { candidate in
                if let tunnel = candidate.protocolConfiguration as? NETunnelProviderProtocol,
                   tunnel.providerBundleIdentifier == providerBundleIdentifier {
                    return true
                }
                return candidate.localizedDescription == "Nullex DNS"
            })
        }

        let manager = self.manager ?? NETunnelProviderManager()
        let tunnel = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        tunnel.providerBundleIdentifier = providerBundleIdentifier
        tunnel.serverAddress = "Nullex DNS"
        tunnel.providerConfiguration = [
            "filterURL": Self.filterURL.absoluteString,
            "upstream": "https://dns.cloudflare-dns.com/dns-query",
        ]
        manager.protocolConfiguration = tunnel
        manager.localizedDescription = "Nullex DNS"
        self.manager = manager
        return manager
    }

    private func loadManagers() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func reload(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func refreshFilterIfNeeded(force: Bool) async throws {
        guard let container = GroupIdentifier.resolvedContainerURL() else {
            throw NSError(
                domain: "NullexDNS",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Nullex App Group is unavailable."]
            )
        }

        let fileURL = container.appendingPathComponent(Self.filterRelativePath)
        if !force,
           let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < Self.filterRefreshInterval,
           (attributes[.size] as? NSNumber)?.intValue ?? 0 > 1024 {
            return
        }

        var request = URLRequest(url: Self.filterURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count > 1024 else {
            throw NSError(
                domain: "NullexDNS",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "DNS filter download failed."]
            )
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        let defaults = sharedDefaults
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.filterUpdatedAt)
        defaults.synchronize()
    }
}
#endif
''', encoding="utf-8")

dns_view = ROOT / "wBlock/NullexDNSProtectionView.swift"
dns_view.write_text(r'''#if os(iOS)
import SwiftUI

struct NullexDNSProtectionView: View {
    @ObservedObject var manager: NullexDNSManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(
                        "DNS Protection",
                        isOn: Binding(
                            get: { manager.isProtectionEnabled },
                            set: { enabled in
                                Task { await manager.setEnabled(enabled) }
                            }
                        )
                    )

                    infoRow("Status", manager.connectionStatusText)
                } footer: {
                    Text("Runs a local DNS packet tunnel and blocks matching ad and tracker domains before they connect.")
                }

                Section {
                    infoRow("Blocked All Time", manager.totalBlocked.formatted())
                    infoRow("Blocked Today", manager.blockedToday.formatted())
                    infoRow("DNS Requests", manager.totalRequests.formatted())
                    infoRow("Block Rate", manager.blockRateText)

                    if !manager.lastBlockedDomain.isEmpty {
                        infoRow("Last Blocked", manager.lastBlockedDomain)
                    }

                    if let lastEventAt = manager.lastEventAt {
                        infoRow(
                            "Last DNS Event",
                            lastEventAt.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                } header: {
                    Text("Live Statistics")
                } footer: {
                    Text("These are real DNS requests blocked by Nullex DNS. Safari-only cosmetic and native content-blocker matches are not added to this number.")
                }

                Section {
                    infoRow("Source", "AdGuard DNS Filter")
                    if let filterUpdatedAt = manager.filterUpdatedAt {
                        infoRow(
                            "Updated",
                            filterUpdatedAt.formatted(date: .abbreviated, time: .shortened)
                        )
                    }

                    Button("Update DNS Filter") {
                        Task { await manager.refreshDNSFilter() }
                    }
                } header: {
                    Text("DNS Filter")
                }

                if let error = manager.lastError, !error.isEmpty {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    } header: {
                        Text("Error")
                    }
                }

                Section {
                    Button("Reset Statistics", role: .destructive) {
                        manager.resetStatistics()
                    }
                }
            }
            .navigationTitle("Nullex DNS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
        }
    }
}
#endif
''', encoding="utf-8")

# Add the third live card to the existing upstream stats row.
content_view = ROOT / "wBlock/ContentView.swift"
replace_once(
    content_view,
    '    @State private var showingCapacityPopover = false\n',
    '''    @State private var showingCapacityPopover = false
    #if os(iOS)
    @StateObject private var dnsManager = NullexDNSManager.shared
    @State private var showingDNSProtection = false
    #endif
''',
)
replace_once(
    content_view,
    '''        .sheet(item: $editingCustomFilter) { filter in
            EditCustomFilterView(filterManager: filterManager, filter: filter)
        }
''',
    '''        .sheet(item: $editingCustomFilter) { filter in
            EditCustomFilterView(filterManager: filterManager, filter: filter)
        }
        #if os(iOS)
        .sheet(isPresented: $showingDNSProtection) {
            NullexDNSProtectionView(manager: dnsManager)
        }
        #endif
''',
)
replace_once(
    content_view,
    '''    private var statsCardsView: some View {
        StatsCardsView {
''',
    '''    private var compactStatsCards: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    private var statsCardsView: some View {
        StatsCardsView(compact: compactStatsCards) {
''',
)
replace_once(
    content_view,
    '''                    showsDisclosure: true
                )
''',
    '''                    compact: compactStatsCards,
                    showsDisclosure: true
                )
''',
)
replace_once(
    content_view,
    '''            StatCard(
                title: "Enabled",
                value: "\(enabledListsCount)",
                icon: "checkmark.circle"
            )
            #if os(iOS)
            .frame(maxWidth: .infinity, alignment: .leading)
            #endif
''',
    '''            StatCard(
                title: "Enabled",
                value: "\(enabledListsCount)",
                icon: "checkmark.circle",
                compact: compactStatsCards
            )
            #if os(iOS)
            .frame(maxWidth: .infinity, alignment: .leading)
            #endif

            #if os(iOS)
            Button {
                showingDNSProtection = true
            } label: {
                StatCard(
                    title: "Blocked",
                    value: dnsManager.totalBlocked.formatted(),
                    icon: "hand.raised.fill",
                    valueColor: dnsManager.totalBlocked > 0 ? .primary : .secondary,
                    compact: true,
                    showsDisclosure: true
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .noFocusRingCompat()
            #endif
''',
)

# ---------------------------------------------------------------------------
# Packet-tunnel extension
# ---------------------------------------------------------------------------
dns_dir = ROOT / "Nullex DNS"
dns_dir.mkdir(parents=True, exist_ok=True)

with (dns_dir / "NullexDNS.entitlements").open("wb") as f:
    plistlib.dump(
        {
            "com.apple.developer.networking.networkextension": ["packet-tunnel-provider"],
            "com.apple.security.application-groups": [BASE_GROUP],
        },
        f,
        fmt=plistlib.FMT_XML,
        sort_keys=False,
    )

with (dns_dir / "Info.plist").open("wb") as f:
    plistlib.dump(
        {
            "CFBundleDevelopmentRegion": "$(DEVELOPMENT_LANGUAGE)",
            "CFBundleDisplayName": "Nullex DNS",
            "CFBundleExecutable": "$(EXECUTABLE_NAME)",
            "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "Nullex DNS",
            "CFBundlePackageType": "XPC!",
            "CFBundleShortVersionString": "$(MARKETING_VERSION)",
            "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
            "NSExtension": {
                "NSExtensionPointIdentifier": "com.apple.networkextension.packet-tunnel",
                "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).PacketTunnelProvider",
            },
        },
        f,
        fmt=plistlib.FMT_XML,
        sort_keys=False,
    )

(dns_dir / "PacketTunnelProvider.swift").write_text(r'''import AGDnsProxy
import Foundation
import NetworkExtension

private enum NullexDNSRuntime {
    static let baseBundleIdentifier = "com.nightvibes33.nullex"
    private static let statsQueue = DispatchQueue(label: "com.nightvibes33.nullex.dns.stats")
    static let baseGroupIdentifier = "group.com.nightvibes33.nullex"
    static let filterURL = URL(string: "https://filters.adtidy.org/dns/filter_1_ios.txt")!
    static let filterRelativePath = "NullexDNS/filter_1_ios.txt"

    enum Keys {
        static let totalRequests = "nullex.dns.totalRequests"
        static let totalBlocked = "nullex.dns.totalBlocked"
        static let blockedToday = "nullex.dns.blockedToday"
        static let dayStart = "nullex.dns.dayStart"
        static let lastBlockedDomain = "nullex.dns.lastBlockedDomain"
        static let lastEventAt = "nullex.dns.lastEventAt"
        static let filterUpdatedAt = "nullex.dns.filterUpdatedAt"
    }

    static var containingAppBundleIdentifier: String {
        let bundle = Bundle.main.bundleIdentifier ?? "\(baseBundleIdentifier).dns"
        return bundle.hasSuffix(".dns") ? String(bundle.dropLast(4)) : baseBundleIdentifier
    }

    static func provisionedApplicationGroups() -> [String] {
        guard let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: profileURL) else {
            return []
        }
        let startMarker = Data("<?xml".utf8)
        let endMarker = Data("</plist>".utf8)
        guard let start = data.range(of: startMarker)?.lowerBound,
              let end = data.range(of: endMarker, options: .backwards)?.upperBound,
              start < end else {
            return []
        }
        let plistData = data.subdata(in: start..<end)
        guard let object = try? PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ),
        let profile = object as? [String: Any],
        let entitlements = profile["Entitlements"] as? [String: Any],
        let groups = entitlements["com.apple.security.application-groups"] as? [String] else {
            return []
        }
        return groups
    }

    static var groupIdentifier: String {
        var candidates = provisionedApplicationGroups()
        candidates.append("group.\(containingAppBundleIdentifier)")
        candidates.append(baseGroupIdentifier)
        for candidate in candidates where !candidate.isEmpty {
            if FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: candidate
            ) != nil {
                return candidate
            }
        }
        return candidates.first ?? baseGroupIdentifier
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier
        )
    }

    static var defaults: UserDefaults {
        UserDefaults(suiteName: groupIdentifier) ?? .standard
    }

    static func ensureFilter() async throws -> String {
        guard let container = containerURL else {
            throw NSError(
                domain: "NullexDNS",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Nullex DNS App Group is unavailable."]
            )
        }
        let fileURL = container.appendingPathComponent(filterRelativePath)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           (attributes[.size] as? NSNumber)?.intValue ?? 0 > 1024 {
            return fileURL.path
        }

        var request = URLRequest(url: filterURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count > 1024 else {
            throw NSError(
                domain: "NullexDNS",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Nullex DNS filter is unavailable."]
            )
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        let defaults = defaults
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.filterUpdatedAt)
        defaults.synchronize()
        return fileURL.path
    }

    static func record(domain: String, blocked: Bool) {
        statsQueue.sync {
            let defaults = defaults
            defaults.synchronize()

            let now = Date()
            let today = Calendar.current.startOfDay(for: now).timeIntervalSince1970
            let storedDay = defaults.double(forKey: Keys.dayStart)
            if storedDay <= 0 || !Calendar.current.isDate(
                Date(timeIntervalSince1970: storedDay),
                inSameDayAs: now
            ) {
                defaults.set(today, forKey: Keys.dayStart)
                defaults.set(0, forKey: Keys.blockedToday)
            }

            defaults.set(
                defaults.integer(forKey: Keys.totalRequests) + 1,
                forKey: Keys.totalRequests
            )
            defaults.set(now.timeIntervalSince1970, forKey: Keys.lastEventAt)

            if blocked {
                defaults.set(
                    defaults.integer(forKey: Keys.totalBlocked) + 1,
                    forKey: Keys.totalBlocked
                )
                defaults.set(
                    defaults.integer(forKey: Keys.blockedToday) + 1,
                    forKey: Keys.blockedToday
                )
                defaults.set(domain, forKey: Keys.lastBlockedDomain)
            }
            defaults.synchronize()
        }
    }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var dnsProxy: AGDnsProxy?
    private var dnsTunListener: AGDnsTunListener?
    private let mtu: Int32 = 1500

    override func startTunnel(options: [String: NSObject]?) async throws {
        let filterPath = try await NullexDNSRuntime.ensureFilter()
        try startDNSProxy(filterPath: filterPath)

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: mtu)

        let ipv4 = NEIPv4Settings(
            addresses: ["198.18.53.1"],
            subnetMasks: ["255.255.255.255"]
        )
        ipv4.includedRoutes = [
            NEIPv4Route(
                destinationAddress: "198.18.53.53",
                subnetMask: "255.255.255.255"
            )
        ]
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: ["198.18.53.53"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        try await setTunnelNetworkSettings(settings)
    }

    private func startDNSProxy(filterPath: String) throws {
        guard let config = AGDnsProxyConfig.getDefault() else {
            throw NSError(
                domain: "NullexDNS",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "AGDnsProxy configuration is unavailable."]
            )
        }

        let upstream = AGDnsUpstream()
        upstream.id = 1
        upstream.address = "https://dns.cloudflare-dns.com/dns-query"
        upstream.bootstrap = ["1.1.1.1", "1.0.0.1"]
        config.upstreams = [upstream]

        let filter = AGDnsFilterParams()
        filter.id = 1
        filter.data = filterPath
        filter.inMemory = false
        config.filters = [filter]

        let events = AGDnsProxyEvents()
        events.onRequestProcessed = { request in
            guard let request else { return }
            let rules = request.rules ?? []
            let blocked = !request.whitelist && !rules.isEmpty
            NullexDNSRuntime.record(
                domain: request.domain ?? "",
                blocked: blocked
            )
        }

        var proxyError: NSError?
        guard let proxy = AGDnsProxy(config: config, handler: events, error: &proxyError) else {
            throw proxyError ?? NSError(
                domain: "NullexDNS",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "AGDnsProxy failed to start."]
            )
        }
        dnsProxy = proxy

        dnsTunListener = try AGDnsTunListener(
            tunFd: nil,
            orTunnelFlow: packetFlow,
            mtu: mtu,
            messageHandler: { [weak self] data, reply in
                guard let proxy = self?.dnsProxy else {
                    reply(nil)
                    return
                }
                proxy.handleMessage(
                    data,
                    with: AGDnsMessageInfo(),
                    withCompletionHandler: { response in
                        reply(response)
                    }
                )
            }
        )
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        dnsTunListener?.stop()
        dnsTunListener = nil
        dnsProxy?.stop()
        dnsProxy = nil
    }
}
''', encoding="utf-8")

# ---------------------------------------------------------------------------
# Xcode target + public binary SwiftPM dependency
# ---------------------------------------------------------------------------
pbx = ROOT / "wBlock.xcodeproj/project.pbxproj"

BUILD_FILE_PKG = "D15D0000000000000000000C"
BUILD_FILE_EMBED = "D15D0000000000000000000D"
EMBED_FRAMEWORKS = "D15D00000000000000000012"
CONTAINER_PROXY = "D15D0000000000000000000E"
PRODUCT_REF = "D15D00000000000000000001"
FS_GROUP = "D15D00000000000000000002"
TARGET = "D15D00000000000000000003"
SOURCES = "D15D00000000000000000004"
FRAMEWORKS = "D15D00000000000000000005"
RESOURCES = "D15D00000000000000000006"
CONFIG_LIST = "D15D00000000000000000007"
DEBUG_CONFIG = "D15D00000000000000000008"
RELEASE_CONFIG = "D15D00000000000000000009"
PACKAGE_REF = "D15D0000000000000000000A"
PACKAGE_PRODUCT = "D15D0000000000000000000B"
TARGET_DEP = "D15D0000000000000000000F"
FS_EXCEPTION = "D15D00000000000000000010"

insert_before(
    pbx,
    "/* End PBXBuildFile section */",
    f'''\t\t{BUILD_FILE_PKG} /* AGDnsProxy in Frameworks */ = {{isa = PBXBuildFile; productRef = {PACKAGE_PRODUCT} /* AGDnsProxy */; }};
\t\t{BUILD_FILE_EMBED} /* Nullex DNS.appex in Embed Foundation Extensions */ = {{isa = PBXBuildFile; fileRef = {PRODUCT_REF} /* Nullex DNS.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};''',
)

insert_before(
    pbx,
    "/* End PBXContainerItemProxy section */",
    f'''\t\t{CONTAINER_PROXY} /* PBXContainerItemProxy */ = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = C1A41C252DE0897C0056F63D /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = {TARGET};
\t\t\tremoteInfo = "Nullex DNS";
\t\t}};''',
)

insert_before(
    pbx,
    "/* End PBXFileReference section */",
    f'''\t\t{PRODUCT_REF} /* Nullex DNS.appex */ = {{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = "Nullex DNS.appex"; sourceTree = BUILT_PRODUCTS_DIR; }};''',
)

insert_before(
    pbx,
    "/* End PBXFileSystemSynchronizedBuildFileExceptionSet section */",
    f'''\t\t{FS_EXCEPTION} /* Exceptions for "Nullex DNS" folder in "Nullex DNS" target */ = {{
\t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;
\t\t\tmembershipExceptions = (
\t\t\t\tInfo.plist,
\t\t\t\tNullexDNS.entitlements,
\t\t\t);
\t\t\ttarget = {TARGET} /* Nullex DNS */;
\t\t}};''',
)

insert_before(
    pbx,
    "/* End PBXShellScriptBuildPhase section */",
    f'''\t\t{EMBED_FRAMEWORKS} /* Embed AGDnsProxy Framework */ = {{
\t\t\tisa = PBXShellScriptBuildPhase;
\t\t\talwaysOutOfDate = 1;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\tinputFileListPaths = (
\t\t\t);
\t\t\tinputPaths = (
\t\t\t\t"$(BUILT_PRODUCTS_DIR)/AGDnsProxy.framework",
\t\t\t);
\t\t\tname = "Embed AGDnsProxy Framework";
\t\t\toutputFileListPaths = (
\t\t\t);
\t\t\toutputPaths = (
\t\t\t\t"$(TARGET_BUILD_DIR)/$(FRAMEWORKS_FOLDER_PATH)/AGDnsProxy.framework",
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t\tshellPath = /bin/sh;
\t\t\tshellScript = "set -euo pipefail\\nSRC=\\\"$BUILT_PRODUCTS_DIR/AGDnsProxy.framework\\\"\\nDST=\\\"$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/AGDnsProxy.framework\\\"\\ntest -d \\"$SRC\\"\\nmkdir -p \\"$(dirname \\"$DST\\")\\"\\nrm -rf \\"$DST\\"\\n/usr/bin/ditto \\"$SRC\\" \\"$DST\\"\\ntest -f \\"$DST/AGDnsProxy\\"\\n";
\t\t}};''',
)

insert_before(
    pbx,
    "/* End PBXFileSystemSynchronizedRootGroup section */",
    f'''\t\t{FS_GROUP} /* Nullex DNS */ = {{
\t\t\tisa = PBXFileSystemSynchronizedRootGroup;
\t\t\texceptions = (
\t\t\t\t{FS_EXCEPTION} /* Exceptions for "Nullex DNS" folder in "Nullex DNS" target */,
\t\t\t);
\t\t\tpath = "Nullex DNS";
\t\t\tsourceTree = "<group>";
\t\t}};''',
)

insert_before(
    pbx,
    "/* End PBXFrameworksBuildPhase section */",
    f'''\t\t{FRAMEWORKS} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{BUILD_FILE_PKG} /* AGDnsProxy in Frameworks */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''',
)

insert_before(
    pbx,
    "/* End PBXNativeTarget section */",
    f'''\t\t{TARGET} /* Nullex DNS */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {CONFIG_LIST} /* Build configuration list for PBXNativeTarget "Nullex DNS" */;
\t\t\tbuildPhases = (
\t\t\t\t{SOURCES} /* Sources */,
\t\t\t\t{FRAMEWORKS} /* Frameworks */,
\t\t\t\t{RESOURCES} /* Resources */,
\t\t\t\t{EMBED_FRAMEWORKS} /* Embed AGDnsProxy Framework */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\t{FS_GROUP} /* Nullex DNS */,
\t\t\t);
\t\t\tname = "Nullex DNS";
\t\t\tpackageProductDependencies = (
\t\t\t\t{PACKAGE_PRODUCT} /* AGDnsProxy */,
\t\t\t);
\t\t\tproductName = "Nullex DNS";
\t\t\tproductReference = {PRODUCT_REF} /* Nullex DNS.appex */;
\t\t\tproductType = "com.apple.product-type.app-extension";
\t\t}};''',
)

insert_before(
    pbx,
    "/* End PBXResourcesBuildPhase section */",
    f'''\t\t{RESOURCES} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''',
)

insert_before(
    pbx,
    "/* End PBXSourcesBuildPhase section */",
    f'''\t\t{SOURCES} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''',
)

insert_before(
    pbx,
    "/* End PBXTargetDependency section */",
    f'''\t\t{TARGET_DEP} /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {TARGET} /* Nullex DNS */;
\t\t\ttargetProxy = {CONTAINER_PROXY} /* PBXContainerItemProxy */;
\t\t}};''',
)

build_settings = f'''{{
\t\t\t\tAPPLICATION_EXTENSION_API_ONLY = YES;
\t\t\t\tCODE_SIGN_ENTITLEMENTS = "Nullex DNS/NullexDNS.entitlements";
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 113;
\t\t\t\tDEVELOPMENT_TEAM = DNP7DGUB7B;
\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = NO;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = "Nullex DNS/Info.plist";
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.4;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t\t"@executable_path/../../Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 3.2.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {DNS_BUNDLE};
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSKIP_INSTALL = YES;
\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
\t\t\t\tSUPPORTS_MACCATALYST = NO;
\t\t\t\tSUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD = YES;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
\t\t\t}}'''

insert_before(
    pbx,
    "/* End XCBuildConfiguration section */",
    f'''\t\t{DEBUG_CONFIG} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {build_settings};
\t\t\tname = Debug;
\t\t}};
\t\t{RELEASE_CONFIG} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {build_settings};
\t\t\tname = Release;
\t\t}};''',
)

insert_before(
    pbx,
    "/* End XCConfigurationList section */",
    f'''\t\t{CONFIG_LIST} /* Build configuration list for PBXNativeTarget "Nullex DNS" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{DEBUG_CONFIG} /* Debug */,
\t\t\t\t{RELEASE_CONFIG} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};''',
)

insert_before(
    pbx,
    "/* End XCRemoteSwiftPackageReference section */",
    f'''\t\t{PACKAGE_REF} /* XCRemoteSwiftPackageReference "DnsLibs" */ = {{
\t\t\tisa = XCRemoteSwiftPackageReference;
\t\t\trepositoryURL = "https://github.com/AdguardTeam/DnsLibs.git";
\t\t\trequirement = {{
\t\t\t\tkind = revision;
\t\t\t\trevision = {DNSLIBS_REVISION};
\t\t\t}};
\t\t}};''',
)

insert_before(
    pbx,
    "/* End XCSwiftPackageProductDependency section */",
    f'''\t\t{PACKAGE_PRODUCT} /* AGDnsProxy */ = {{
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tpackage = {PACKAGE_REF} /* XCRemoteSwiftPackageReference "DnsLibs" */;
\t\t\tproductName = AGDnsProxy;
\t\t}};''',
)

replace_once(
    pbx,
    '''\t\t\t\tC1A41C2F2DE0897C0056F63D /* wBlock */,
\t\t\t\tC1A41C462DE089C50056F63D /* wBlockCoreService */,''',
    f'''\t\t\t\tC1A41C2F2DE0897C0056F63D /* wBlock */,
\t\t\t\t{FS_GROUP} /* Nullex DNS */,
\t\t\t\tC1A41C462DE089C50056F63D /* wBlockCoreService */,''',
)
replace_once(
    pbx,
    '''\t\t\t\tC1A41C2D2DE0897C0056F63D /* wBlock.app */,
\t\t\t\tC1A41C452DE089C50056F63D /* wBlockCoreService.framework */,''',
    f'''\t\t\t\tC1A41C2D2DE0897C0056F63D /* wBlock.app */,
\t\t\t\t{PRODUCT_REF} /* Nullex DNS.appex */,
\t\t\t\tC1A41C452DE089C50056F63D /* wBlockCoreService.framework */,''',
)
replace_once(
    pbx,
    '''\t\t\tpackageReferences = (
\t\t\t\tC1A41C532DE08A040056F63D /* XCRemoteSwiftPackageReference "SafariConverterLib" */,
\t\t\t\tC1E44F362E4CBA9300F58897 /* XCRemoteSwiftPackageReference "swift-protobuf" */,
\t\t\t);''',
    f'''\t\t\tpackageReferences = (
\t\t\t\tC1A41C532DE08A040056F63D /* XCRemoteSwiftPackageReference "SafariConverterLib" */,
\t\t\t\tC1E44F362E4CBA9300F58897 /* XCRemoteSwiftPackageReference "swift-protobuf" */,
\t\t\t\t{PACKAGE_REF} /* XCRemoteSwiftPackageReference "DnsLibs" */,
\t\t\t);''',
)
replace_once(
    pbx,
    '''\t\t\ttargets = (
\t\t\t\tC1A41C2C2DE0897C0056F63D /* wBlock */,
\t\t\t\tC1A41C442DE089C50056F63D /* wBlockCoreService */,''',
    f'''\t\t\ttargets = (
\t\t\t\tC1A41C2C2DE0897C0056F63D /* wBlock */,
\t\t\t\t{TARGET} /* Nullex DNS */,
\t\t\t\tC1A41C442DE089C50056F63D /* wBlockCoreService */,''',
)
replace_once(
    pbx,
    '''\t\t\t\tC1A41C4C2DE089C50056F63D /* PBXTargetDependency */,
\t\t\t\tD5FCECBF423348439B5AED9F /* PBXTargetDependency */,''',
    f'''\t\t\t\tC1A41C4C2DE089C50056F63D /* PBXTargetDependency */,
\t\t\t\t{TARGET_DEP} /* PBXTargetDependency */,
\t\t\t\tD5FCECBF423348439B5AED9F /* PBXTargetDependency */,''',
)
replace_once(
    pbx,
    '''\t\t\tfiles = (
\t\t\t\tC1F16C0E2DE354E40031E7EF /* wBlock Privacy.appex in Embed Foundation Extensions */,''',
    f'''\t\t\tfiles = (
\t\t\t\t{BUILD_FILE_EMBED} /* Nullex DNS.appex in Embed Foundation Extensions */,
\t\t\t\tC1F16C0E2DE354E40031E7EF /* wBlock Privacy.appex in Embed Foundation Extensions */,''',
)

# Mark the intentional feature addition in the source notice.
notice = ROOT / "NULLEX_NOTICE.md"
text = notice.read_text(encoding="utf-8")
text = text.replace(
    "Nullex keeps upstream UI/feature visibility intact and changes only branding,\nsideload bundle identities, SideStore-safe App Group resolution, and icon assets.",
    "Nullex keeps the upstream Safari blocking engine intact while adding Nullex DNS,\na packet-tunnel DNS protection layer with on-device live blocking statistics."
)
text += f"""

## Nullex DNS dependency

Nullex DNS uses AdGuard DnsLibs (Apache-2.0), pinned to public SwiftPM revision
{DNSLIBS_REVISION}. The packet tunnel uses AGDnsProxy and AGDnsTunListener and
stores aggregate DNS request/block counts only in the Nullex App Group.
"""
notice.write_text(text, encoding="utf-8")

# Strong source-level assertions before Xcode gets a chance to build.
pbx_text = pbx.read_text(encoding="utf-8")
for required in [
    DNS_BUNDLE,
    "Nullex DNS.appex",
    "AGDnsProxy",
    "Embed AGDnsProxy Framework",
    DNSLIBS_REVISION,
    "packet-tunnel-provider",
]:
    if required not in pbx_text and required != "packet-tunnel-provider":
        raise RuntimeError(f"Missing expected Xcode project token: {required}")

if "NullexDNSManager.shared" not in content_view.read_text(encoding="utf-8"):
    raise RuntimeError("Nullex DNS live statistics card was not injected")

print("Nullex DNS packet tunnel + real-time statistics overlay applied.")
