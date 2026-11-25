import SwiftUI
import UniformTypeIdentifiers

/// Settings > Export Library: your artists, albums and tracks as spreadsheets (CSV), zipped into one file you save
/// where you like (Files on the iPhone, a Save dialog on the Mac).
struct ExportLibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var working = false
    @State private var counts: LibraryExport.Counts?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await export() }
                } label: {
                    HStack {
                        Label("Export Library\u{2026}", systemImage: "square.and.arrow.up")
                        Spacer()
                        if working { ProgressView() }
                    }
                }
                .disabled(working || app.client == nil)
            } footer: {
                Text("Three spreadsheets in one zip: artists.csv (artist, albums, tracks), albums.csv (album artist, album, year, tracks, length) and tracks.csv (album artist, album, disc, track, title, artists, year, length). They open in Excel, Numbers and Google Sheets.")
            }
            if let counts {
                Section("Last export") {
                    LabeledContent("Artists", value: counts.artists.formatted())
                    LabeledContent("Albums", value: counts.albums.formatted())
                    LabeledContent("Tracks", value: counts.tracks.formatted())
                }
            }
            if let message {
                Section { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Export Library")
    }

    private func export() async {
        guard let client = app.client else { return }
        working = true
        message = nil
        defer { working = false }
        do {
            let made = try await LibraryExport.make(client: client)
            counts = made.counts
            ExportPicker.present(made.url) { saved in message = saved ? "Saved." : nil }
        } catch {
            message = "Couldn\u{2019}t read your library: \(error.localizedDescription)"
        }
    }
}

/// The system's "save a copy" picker (Files on the iPhone, a Save dialog on the Mac), shown over whatever is on screen.
/// SwiftUI's fileExporter didn't appear at all on the Mac, so it is presented directly.
@MainActor
private enum ExportPicker {
    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        let done: (Bool) -> Void
        init(done: @escaping (Bool) -> Void) { self.done = done }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(true) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(false) }
        private func finish(_ saved: Bool) {
            done(saved)
            ExportPicker.delegate = nil
        }
    }

    private static var delegate: Delegate?

    static func present(_ url: URL, done: @escaping (Bool) -> Void) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        guard var top = window?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        let delegate = Delegate(done: done)
        Self.delegate = delegate
        picker.delegate = delegate
        top.present(picker, animated: true)
    }
}
