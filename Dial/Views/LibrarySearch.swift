import SwiftUI

/// The big search bar at the top of the Library: it is where you search everything you own (and a little beyond).
/// Empty, the page shows whatever is passed in; with something typed, the results take over.
struct LibrarySearchContainer<Content: View>: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var scope: LibrarySearchScope = .all
    @FocusState private var focused: Bool
    /// Counts up to ask the Mac's field for the cursor.
    @State private var focusTick = 0
    /// Discovery's search: your library and music beyond it. The Library's search stays with your own library.
    var outside = false
    @ViewBuilder var content: () -> Content

    private var prompt: String { outside ? "Search music" : "Search your library" }

    private func takeFocusRequest() {
        guard app.navigator.searchFocusPending else { return }
        app.navigator.searchFocusPending = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350)) // after the tab has switched
            focused = true
            focusTick += 1
        }
    }

    private var searching: Bool { query.trimmingCharacters(in: .whitespaces).count >= 2 }

    var body: some View {
        if Platform.isMac { macBody } else { phoneBody }
    }

    // MARK: Mac

    /// The Mac has no navigation bar to hang the system search on (it only showed up on the second visit), so the page has
    /// its own: a field that takes the cursor the moment the page opens, and the filters right under it.
    private var macBody: some View {
        VStack(spacing: 0) {
            VStack(spacing: Theme.Spacing.s) {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    MacSearchField(text: $query, prompt: prompt, focusTick: $focusTick)
                        .frame(height: 30)
                    if !query.isEmpty {
                        Button { query = ""; focusTick += 1 } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear")
                    }
                }
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.s + 2)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 12, style: .continuous))

                Picker("Show", selection: $scope) {
                    ForEach(LibrarySearchScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .opacity(searching ? 1 : 0.35)
                .disabled(!searching)
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.m)
            Divider()
            Group {
                if searching {
                    LibrarySearchResults(query: query, scope: $scope, outside: outside)
                } else {
                    content()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { takeFocusRequest(); focusSoon() }
        .onChange(of: app.navigator.searchFocusRequest) { _, _ in takeFocusRequest(); focusSoon() }
    }

    /// The cursor goes into the field once the page is on screen (setting it earlier is ignored).
    private func focusSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            focused = true
            focusTick += 1
        }
    }

    // MARK: iPhone and iPad

    private var phoneBody: some View {
        // The system search field (it gets the current look of the OS by itself), with the scopes under it while typing.
        Group {
            if searching {
                LibrarySearchResults(query: query, scope: $scope, outside: outside)
            } else {
                content()
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        .modifier(SearchFocus(focused: $focused))
        .searchScopes($scope, activation: .onSearchPresentation) {
            ForEach(LibrarySearchScope.allCases) { Text($0.rawValue).tag($0) }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        // \u{2318}F, the Search command and the search icon on Home put the cursor here, even when this page is only just opening.
        .onAppear { takeFocusRequest() }
        .onChange(of: app.navigator.searchFocusRequest) { _, _ in takeFocusRequest() }
    }
}

/// The Library page for the Mac's sidebar, which has no Library overview: just the search and a hint.
struct LibrarySearchPage: View {
    var body: some View {
        LibrarySearchContainer {
            ContentUnavailableView("Search your library", systemImage: "magnifyingglass",
                                   description: Text("Artists, albums, songs and playlists."))
                .frame(maxHeight: .infinity)
        }
        .navigationTitle("Search")
    }
}

/// Puts the cursor in the search field when asked (iOS 18 and later; earlier systems just show the field).
private struct SearchFocus: ViewModifier {
    var focused: FocusState<Bool>.Binding
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) { content.searchFocused(focused) } else { content }
    }
}


/// The Mac's search field: a plain text field with every helper switched off, so the spelling-suggestion bubble ("alba, alb,
/// album...") and inline predictions never pop up over the results while you type a name.
struct MacSearchField: UIViewRepresentable {
    @Binding var text: String
    var prompt: String
    @Binding var focusTick: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = prompt
        field.font = .preferredFont(forTextStyle: .title3)
        field.borderStyle = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.returnKeyType = .search
        if #available(iOS 17.0, *) { field.inlinePredictionType = .no }
        if #available(iOS 18.0, *) { field.writingToolsBehavior = .none }
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        if field.text != text { field.text = text }
        if context.coordinator.tick != focusTick {
            context.coordinator.tick = focusTick
            DispatchQueue.main.async { field.becomeFirstResponder() }
        }
    }

    final class Coordinator: NSObject {
        var parent: MacSearchField
        var tick = 0
        init(_ parent: MacSearchField) { self.parent = parent }
        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
    }
}
