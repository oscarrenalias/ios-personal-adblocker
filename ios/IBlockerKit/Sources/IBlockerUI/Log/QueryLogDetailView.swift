#if os(iOS)
import SwiftUI
import UIKit
import IBlockerKit

/// Sheet shown when a query-log row is tapped. Same actions as the row's context menu.
struct QueryLogDetailView: View {
    let record: QueryLogRecord
    @Environment(FilterListsViewModel.self) private var lists
    @Environment(\.dismiss) private var dismiss

    private static let uiLog = Log(category: "ui")

    var body: some View {
        let explanation = DecisionExplanationPresentation(record: record, state: lists.state)
        NavigationStack {
            List {
                Section {
                    LabeledContent("Domain") {
                        Text(record.domain)
                            .font(.callout.monospaced())
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Time") {
                        Text(record.date, format: .dateTime.hour().minute().second())
                    }
                    LabeledContent("Type", value: DNSRecordType.name(record.qtype))
                    LabeledContent("Verdict") {
                        Text(verdictText).foregroundStyle(verdictColor)
                    }
                }
                Section {
                    LabeledContent("Why", value: explanation.why)
                    if let route = explanation.routeLine {
                        LabeledContent("Route", value: route)
                    }
                }
                Section {
                    if record.verdict == .blocked {
                        Button {
                            Task { await lists.addAllow(record.domain) }
                            dismiss()
                        } label: {
                            Label("Allow this domain", systemImage: "checkmark.circle")
                        }
                    } else {
                        Button(role: .destructive) {
                            Task { await lists.addDeny(record.domain) }
                            dismiss()
                        } label: {
                            Label("Block this domain", systemImage: "nosign")
                        }
                    }
                    Button {
                        UIPasteboard.general.string = record.domain
                    } label: {
                        Label("Copy domain", systemImage: "doc.on.doc")
                    }
                }
            }
            .navigationTitle("Query Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { Self.uiLog.debug("explain opened: \(record.domain)") }
    }

    private var verdictText: String {
        switch record.verdict {
        case .blocked: return "Blocked"
        case .allowed: return "Allowed"
        case .failed: return "Failed"
        }
    }

    private var verdictColor: Color {
        switch record.verdict {
        case .blocked: return .red
        case .allowed: return .green
        case .failed: return .orange
        }
    }
}
#endif
