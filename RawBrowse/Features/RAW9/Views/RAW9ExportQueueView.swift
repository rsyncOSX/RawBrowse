import SwiftUI

struct RAW9ExportQueueView: View {
    let queue: RAW9ExportQueue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Exports").font(.headline)
                if let job = queue.activeJob {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(job.destination.lastPathComponent)
                            Text(queue.isCancellingActiveJob ? "Cancelling…" : "Exporting…")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel Export") { queue.cancelActiveJob() }
                            .disabled(queue.isCancellingActiveJob)
                    }
                }
                ForEach(queue.queuedJobs) { job in
                    HStack {
                        Text(job.destination.lastPathComponent)
                        Spacer()
                        Button("Remove") { queue.removeQueuedJob(job.id) }
                    }
                }
                if queue.outstandingCount > 0 {
                    Button("Cancel All Exports") { queue.cancelAll() }
                } else {
                    Text("No pending exports").foregroundStyle(.secondary)
                }
                ForEach(queue.failures) { failure in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(failure.message, systemImage: "exclamationmark.triangle")
                        Text(failure.job.destination.path).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Retry") { queue.retryFailure(failure.id) }
                            Button("Dismiss") { queue.dismissFailure(failure.id) }
                        }
                    }
                }
            }
            .padding()
        }
        .frame(width: 440, height: 360)
    }
}
