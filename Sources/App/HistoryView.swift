import AppKit
import SwiftUI

struct HistoryView: View {
    @ObservedObject var runner: JobRunner
    @State private var showingClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Operation History").font(.title2.bold())
                Spacer()
                if !runner.history.isEmpty {
                    Button("Clear History") { showingClearConfirmation = true }
                }
            }
            if runner.history.isEmpty {
                ContentUnavailableView("No operations yet", systemImage: "clock.arrow.circlepath")
            } else {
                List(runner.history) { record in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: symbol(for: record.outcome))
                            .foregroundStyle(record.outcome == .failed ? .red : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.title).font(.headline)
                            Text(record.detail).lineLimit(1)
                            if let error = record.error { Text(error).foregroundStyle(.red).lineLimit(2) }
                            Text(record.date, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !record.outputs.isEmpty {
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting(record.outputs) }
                        }
                        Button("Remove") { runner.removeHistory(record) }
                            .help("Remove this history entry; output files are kept")
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 320)
        .confirmationDialog("Clear operation history?", isPresented: $showingClearConfirmation) {
            Button("Clear History", role: .destructive) { runner.clearHistory() }
        } message: {
            Text("This removes history entries only. Your files are kept.")
        }
        .alert("Could not update history", isPresented: Binding(
            get: { runner.historyError != nil },
            set: { if !$0 { runner.dismissHistoryError() } }
        )) {
            Button("OK", role: .cancel) { runner.dismissHistoryError() }
        } message: {
            Text(runner.historyError ?? "Please try again.")
        }
    }

    private func symbol(for outcome: JobRecord.Outcome) -> String {
        switch outcome {
        case .done: "checkmark.circle"
        case .cancelled: "xmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}
