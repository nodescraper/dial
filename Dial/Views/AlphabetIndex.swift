import SwiftUI

/// Groups a sorted list under A to Z (and #), the way Apple's lists do. "The Weeknd" is filed under W.
enum AlphaGroups {
    static let letters: [String] = (65...90).map { String(UnicodeScalar($0)!) } + ["#"]

    static func letter(for name: String) -> String {
        var text = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for article in ["the ", "a ", "an "] where text.hasPrefix(article) && text.count > article.count + 1 {
            text = String(text.dropFirst(article.count))
            break
        }
        guard let first = text.unicodeScalars.first(where: { CharacterSet.alphanumerics.contains($0) }) else { return "#" }
        let letter = String(first).uppercased()
        return letters.contains(letter) && letter != "#" ? letter : "#"
    }

    /// The items under their letters, A to Z and then #, keeping the order they came in within each letter.
    static func group<T>(_ items: [T], name: (T) -> String) -> [(letter: String, items: [T])] {
        var buckets: [String: [T]] = [:]
        for item in items { buckets[letter(for: name(item)), default: []].append(item) }
        return letters.compactMap { letter in buckets[letter].map { (letter, $0) } }
    }
}

/// The letters down the right edge: touch or drag along them to jump through a long list.
struct AlphabetIndex: View {
    let available: Set<String>
    let onSelect: (String) -> Void
    @State private var last: String?
    private let rowHeight: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            ForEach(AlphaGroups.letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(available.contains(letter) ? Color.dial : Color.secondary.opacity(0.35))
                    .frame(width: 22, height: rowHeight)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let index = min(max(Int((value.location.y - 4) / rowHeight), 0), AlphaGroups.letters.count - 1)
                    // A letter with nothing under it jumps to the next one that has something.
                    guard let target = AlphaGroups.letters[index...].first(where: available.contains)
                            ?? AlphaGroups.letters[..<index].last(where: available.contains), target != last else { return }
                    last = target
                    #if !targetEnvironment(macCatalyst)
                    UISelectionFeedbackGenerator().selectionChanged()
                    #endif
                    onSelect(target)
                }
                .onEnded { _ in last = nil }
        )
        .accessibilityHidden(true)
    }
}

extension View {
    /// Puts the A to Z index on the right edge of a scrolling list, when there is more than one letter to jump to.
    func alphabetIndex(_ groups: [(letter: String, items: [some Any])], enabled: Bool = true, proxy: ScrollViewProxy) -> some View {
        overlay(alignment: .trailing) {
            if enabled, groups.count > 1 {
                AlphabetIndex(available: Set(groups.map(\.letter))) { letter in
                    proxy.scrollTo("alpha-\(letter)", anchor: .top)
                }
                .padding(.trailing, 2)
            }
        }
    }
}
