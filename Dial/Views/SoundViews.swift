import SwiftUI

// Views built on AudioMuse's sound analysis. Each appears only when your AudioMuse
// version offers the feature behind it.

extension SoundMood {
    var gradient: [Color] {
        [Color(red: colors[0], green: colors[1], blue: colors[2]),
         Color(red: colors[3], green: colors[4], blue: colors[5])]
    }
}

/// A mood station card on the Radio tab. Tapping plays songs from your library with that feel.
struct MoodCard: View {
    let mood: SoundMood
    @Environment(AppModel.self) private var app

    var body: some View {
        Button { app.play(.mood(id: mood.id)) } label: {
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: mood.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(mood.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(Theme.Spacing.m)
                Image(systemName: mood.symbol)
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.35))
                    .rotationEffect(.degrees(-12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(Theme.Spacing.s)
                    .accessibilityHidden(true)
            }
            .frame(height: Theme.Size.categoryCard)
            .clipShape(.rounded(Theme.Radius.tile))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mood.title) mood station")
    }
}
