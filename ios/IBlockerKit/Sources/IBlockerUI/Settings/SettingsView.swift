#if os(iOS)
import SwiftUI
import SafariServices
import IBlockerKit

public struct SettingsView: View {
    @Environment(TunnelController.self) private var tunnel
    @Environment(FilterListsViewModel.self) private var lists
    @State private var resolver = AppEnvironment.settings.resolverSettings
    @State private var logEnabled = AppEnvironment.settings.queryLogEnabled
    @State private var verboseLogging = AppEnvironment.settings.verboseLoggingUntil != nil
    @State private var relayStrategy = AppEnvironment.settings.relayStrategy
    @State private var customDoHURL = ""
    @State private var customUDPAddress = ""
    @State private var blockerStatus: String?
    @State private var blockerBusy = false

    private static let log = Log(category: "settings")

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        BlockingTestView()
                    } label: {
                        Label("Verify blocking (in-app ad test)", systemImage: "checkmark.seal")
                    }
                } footer: {
                    Text("Resolves the Google in-app ad domains through the live tunnel and shows whether an ad SDK could reach them.")
                }

                if FeatureFlags.showAppleRelayControls {
                    Section {
                        Picker("Relay handling", selection: relayStrategyBinding) {
                            Text("Auto-suspend while protected").tag(RelayStrategy.autoSuspend)
                            Text("Block relay domains").tag(RelayStrategy.blockDomains)
                            Text("Keep Private Relay").tag(RelayStrategy.keepRelay)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("Apple Private Relay")
                    } footer: {
                        Text(relayFooter)
                    }
                }

                Section {
                    if let status = resolverStatusPresentation {
                        Label(status.mainLine, systemImage: status.icon)
                            .foregroundStyle(Self.color(for: status.tone))
                    }
                    Toggle("Use alternative DNS", isOn: useAlternativeBinding)
                    if resolver.useAlternative {
                        Picker("Provider", selection: presetBinding) {
                            ForEach(UpstreamPreset.all) { preset in
                                Text(preset.label).tag(preset.name)
                            }
                            if resolver.alternativeName == UpstreamPreset.customName {
                                Text(UpstreamPreset.customName).tag(UpstreamPreset.customName)
                            }
                        }
                        DisclosureGroup("Custom upstream") {
                            HStack {
                                TextField("https://10.0.0.1/dns-query", text: $customDoHURL)
                                    .keyboardType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                Button("Set DoH") {
                                    if let _ = URL(string: customDoHURL) {
                                        applyCustom(UpstreamConfig(kind: .doh, dohURL: customDoHURL))
                                    }
                                }
                                .disabled(customDoHURL.isEmpty)
                            }
                            HStack {
                                TextField("9.9.9.11", text: $customUDPAddress)
                                    .keyboardType(.numbersAndPunctuation)
                                    .autocorrectionDisabled()
                                Button("Set UDP") {
                                    applyCustom(UpstreamConfig(kind: .udp, udpAddress: customUDPAddress))
                                }
                                .disabled(customUDPAddress.isEmpty)
                            }
                        }
                        Picker("If the alternative is unreachable", selection: fallbackBinding) {
                            Text("Use network DNS (unencrypted)").tag(FallbackPolicy.networkDNS)
                            Text("Don't fall back (lookups fail)").tag(FallbackPolicy.none)
                        }
                    }
                } header: {
                    Text("Upstream DNS (VPN mode)")
                } footer: {
                    Text("Network DNS is used when this is off, when the alternative is unreachable (if fallback is on), and always for local and carrier names. .local names are handled by your local network.")
                }

                Section {
                    NavigationLink {
                        ProfileExportView()
                    } label: {
                        Label("Export DNS profile (.mobileconfig)", systemImage: "doc.badge.gearshape")
                    }
                    NavigationLink {
                        DNSSettingsView()
                    } label: {
                        Label("System encrypted DNS", systemImage: "network.badge.shield.half.filled")
                    }
                } header: {
                    Text("Blocking without the VPN")
                } footer: {
                    Text("Both alternatives block ads at a public DNS service instead of on-device. While the VPN is connected, its DNS wins; the profile or system DNS takes over whenever the VPN is off.")
                }

                Section {
                    Button {
                        refreshContentBlocker()
                    } label: {
                        HStack {
                            Label("Update Safari content blocker", systemImage: "safari")
                            Spacer()
                            if blockerBusy { ProgressView() }
                        }
                    }
                    .disabled(blockerBusy)
                    if let blockerStatus {
                        Text(blockerStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Safari")
                } footer: {
                    Text("Downloads EasyList and converts it for Safari's built-in blocker (hides in-page ad leftovers). Enable it in Settings ▸ Apps ▸ Safari ▸ Extensions.")
                }

                Section("Privacy") {
                    Toggle("Keep a query log", isOn: $logEnabled)
                        .onChange(of: logEnabled) { _, value in
                            AppEnvironment.settings.queryLogEnabled = value
                        }
                    Text("The log never leaves this device. Turning it off takes effect the next time the tunnel starts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Verbose logging (1 hour)", isOn: $verboseLogging)
                        .onChange(of: verboseLogging) { _, value in
                            setVerboseLogging(value)
                        }
                    Text("Shows per-lookup details, including domain names, in Console.app / Xcode while streaming from this device. Turns itself off after an hour.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    Text("Personal AdBlocker runs entirely on-device: a local VPN inspects only DNS lookups and answers blocked ones itself. No accounts, no subscriptions, no telemetry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .task {
                await refreshLoop()
            }
            .onAppear {
                // The Blocking Test screen can switch the strategy too.
                relayStrategy = AppEnvironment.settings.relayStrategy
                // Reads as off once the hour has passed.
                verboseLogging = AppEnvironment.settings.verboseLoggingUntil != nil
                Log.setVerbose(verboseLogging)
            }
        }
    }

    /// Nil when the tunnel isn't connected or has reported no stats yet.
    private var resolverStatusPresentation: ResolverStatusPresentation? {
        guard tunnel.state == .connected, let stats = tunnel.runtimeStats else { return nil }
        return ResolverStatusPresentation(tunnelConnected: true, resolverStatus: stats.resolverStatus)
    }

    private static func color(for tone: ResolverStatusPresentation.Tone) -> Color {
        switch tone {
        case .positive: return .green
        case .warning: return .orange
        case .critical: return .red
        case .neutral: return .secondary
        }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            await tunnel.refreshStats()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private var relayStrategyBinding: Binding<RelayStrategy> {
        Binding(
            get: { relayStrategy },
            set: { strategy in
                relayStrategy = strategy
                AppEnvironment.settings.relayStrategy = strategy
                Task {
                    // Auto-suspend keeps the domain blocks too (belt + braces —
                    // Private Relay can't run beside a full VPN anyway).
                    await lists.setRelayBlock(enabled: strategy != .keepRelay)
                    // Route presentation only applies at tunnel start.
                    if tunnel.isOn {
                        await tunnel.disable()
                        await tunnel.enable()
                    }
                }
            }
        )
    }

    private var relayFooter: String {
        switch relayStrategy {
        case .autoSuspend:
            return """
            The tunnel presents itself as a full VPN, so iOS pauses Private Relay and \
            tracker relaying by itself while protection runs — no Apple domains blocked, \
            no Settings changes needed. The relay returns the moment protection stops. \
            (This is how commercial blockers behave.) Changing this restarts the tunnel.
            """
        case .blockDomains:
            return """
            The relay endpoints are DNS-blocked while protection is on. Strongest \
            guarantee; iCloud Private Relay reports "unavailable" until protection stops.
            """
        case .keepRelay:
            return """
            Nothing Apple is ever blocked and the relay stays fully functional. You must \
            turn OFF "Limit IP Address Tracking" yourself (Settings ▸ Wi-Fi ▸ ⓘ on each \
            network, and Settings ▸ Cellular ▸ Cellular Data Options) or apps' tracker \
            traffic rides Apple's relay past this filter. Safari ads stay blocked by the \
            content blocker either way.
            """
        }
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func setVerboseLogging(_ on: Bool) {
        let until = on ? Date().addingTimeInterval(3600) : nil
        guard (AppEnvironment.settings.verboseLoggingUntil != nil) != on else { return }
        AppEnvironment.settings.verboseLoggingUntil = until
        Log.setVerbose(on)
        if let until {
            Self.log.notice("verbose logging turned on until \(until.formatted(.iso8601))")
        } else {
            Self.log.notice("verbose logging turned off")
        }
    }

    private var useAlternativeBinding: Binding<Bool> {
        Binding(
            get: { resolver.useAlternative },
            set: { on in
                var updated = resolver
                updated.useAlternative = on
                apply(updated)
            }
        )
    }

    private var presetBinding: Binding<String> {
        Binding(
            get: { resolver.alternativeName },
            set: { name in
                guard let preset = UpstreamPreset.all.first(where: { $0.name == name }) else { return }
                var updated = resolver
                updated.alternative = preset.config
                updated.alternativeName = preset.name
                apply(updated)
            }
        )
    }

    private var fallbackBinding: Binding<FallbackPolicy> {
        Binding(
            get: { resolver.fallbackPolicy },
            set: { policy in
                var updated = resolver
                updated.fallbackPolicy = policy
                apply(updated)
            }
        )
    }

    private func applyCustom(_ config: UpstreamConfig) {
        var updated = resolver
        updated.alternative = config
        updated.alternativeName = UpstreamPreset.name(for: config)
        apply(updated)
    }

    /// Persists the settings and pushes them to the running tunnel.
    private func apply(_ settings: ResolverSettings) {
        resolver = settings
        AppEnvironment.settings.resolverSettings = settings
        Self.log.notice("resolver settings changed: alternative \(settings.useAlternative ? "on" : "off"), provider \(settings.alternativeName), fallback \(settings.fallbackPolicy.rawValue)")
        Task { await tunnel.setResolverSettings(settings) }
    }

    private func refreshContentBlocker() {
        blockerBusy = true
        blockerStatus = nil
        Task {
            do {
                let stats = try await ContentBlockerRefresher.refresh(paths: AppEnvironment.paths)
                blockerStatus = "Converted \(stats.totalRules.formatted()) rules (\(stats.blockRules) blocks, \(stats.scopedHidingRules + stats.genericHidingRules) hiding)."
            } catch {
                blockerStatus = "Failed: \(error.localizedDescription)"
            }
            blockerBusy = false
        }
    }
}
#endif
