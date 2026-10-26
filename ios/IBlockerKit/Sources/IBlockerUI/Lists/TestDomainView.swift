#if os(iOS)
import SwiftUI
import IBlockerKit

/// Offline "Test a domain" screen: runs the on-device matcher against a typed
/// name and explains the verdict. Never touches the network.
struct TestDomainView: View {
    @Environment(FilterListsViewModel.self) private var lists
    @State private var input = ""
    @State private var outcome: Outcome?
    @State private var needsRebuild = false
    @State private var isRebuilding = false

    private static let log = Log(category: "ui")

    private struct Outcome {
        let domain: String
        let verdict: Verdict
        let why: String
        let lines: [DecisionExplanationPresentation.MatchLine]
    }

    var body: some View {
        List {
            Section {
                TextField("example.com", text: $input)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { runTest() }
                    .onChange(of: input) { outcome = nil }
                Button("Test", action: runTest)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || needsRebuild)
            } footer: {
                Text("Checked against the rules on this device. Nothing is sent over the network.")
            }

            if needsRebuild {
                Section {
                    Text("Rules are being rebuilt")
                        .font(.headline)
                    if isRebuilding {
                        ProgressView()
                    } else {
                        Button("Recompile now") {
                            Self.log.info("test domain: recompile requested")
                            isRebuilding = true
                            Task {
                                await lists.compileOnly()
                                isRebuilding = false
                                needsRebuild = !rulesAreCurrent()
                                if !needsRebuild, !input.isEmpty { runTest() }
                            }
                        }
                    }
                } footer: {
                    Text("The compiled rules are missing or from an older version of the app.")
                }
            } else if let outcome {
                Section("Result") {
                    Label(verdictText(outcome.verdict), systemImage: verdictIcon(outcome.verdict))
                        .foregroundStyle(verdictColor(outcome.verdict))
                        .font(.headline)
                    LabeledContent("Why", value: outcome.why)
                }
                if !outcome.lines.isEmpty {
                    Section("All matches") {
                        ForEach(Array(outcome.lines.enumerated()), id: \.offset) { _, line in
                            Text(line.text)
                                .font(.callout)
                                .foregroundStyle(line.isOverridden ? .secondary : .primary)
                                .strikethrough(line.isOverridden)
                        }
                    }
                }
            } else if !input.isEmpty, DomainValidator.normalize(input) == nil {
                Section { Text("Enter a full domain name, like example.com").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Test a domain")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { needsRebuild = !rulesAreCurrent() }
    }

    private func rulesAreCurrent() -> Bool {
        guard let blocklist = AppEnvironment.paths.loadMatcherReportingFailures().matcher.blocklist else { return false }
        return blocklist.formatVersion == CompiledBlocklist.formatVersion
    }

    private func runTest() {
        guard let domain = DomainValidator.normalize(input) else {
            outcome = nil
            return
        }
        let state = lists.state
        let matcher = AppEnvironment.paths.loadMatcherReportingFailures(
            builtInBlockHashes: SeedRules.fallbackHashes(state: state)).matcher
        guard let blocklist = matcher.blocklist, blocklist.formatVersion == CompiledBlocklist.formatVersion else {
            needsRebuild = true
            return
        }
        let explanation = matcher.explain(domain)
        let why = DecisionExplanationPresentation(explanation: explanation, state: state).why
        let lines = DecisionExplanationPresentation.matchLines(
            deciding: explanation.decidingMatch,
            all: matcher.allMatches(for: domain),
            state: state)
        outcome = Outcome(domain: domain, verdict: explanation.verdict, why: why, lines: lines)
        Self.log.debug("test domain: \(domain) verdict=\(explanation.verdict)")
    }

    private func verdictText(_ verdict: Verdict) -> String {
        switch verdict {
        case .allow: return "Allowed"
        case .block: return "Blocked"
        case .none: return "No rule matched"
        }
    }

    private func verdictIcon(_ verdict: Verdict) -> String {
        switch verdict {
        case .allow: return "checkmark.circle.fill"
        case .block: return "nosign"
        case .none: return "questionmark.circle"
        }
    }

    private func verdictColor(_ verdict: Verdict) -> Color {
        switch verdict {
        case .allow: return .green
        case .block: return .red
        case .none: return .secondary
        }
    }
}
#endif
