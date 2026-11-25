# Contributing

Thanks for looking. Dial is a personal project that is opening up, so the process is light.

## Ways to help

- **Try it and report** what breaks, with your Jellyfin version, device and what you expected. Screenshots help.
- **Improve the docs**, especially the [digitising guide](docs/DIGITISING.md) and [server setup](docs/SERVER-SETUP.md).
- **Fix a bug or build a feature.** For anything bigger than a small fix, open an issue first so we agree on the direction.

## Ground rules

- **Keep the product idea.** Dial is for people who own and chose their music: no endless feeds of unrelated music, no empty-state placeholders, rows that are not ready show a skeleton and rows with nothing are left out.
- **Hide what is not available.** If a feature needs a server add-on, hide it when the add-on is missing.
- **Saved first.** Screens show what they had at once and refresh in the background.
- **Use Jellyfin's data** before inventing a new source.
- **Accessibility:** icon-only buttons need labels; use Apple's text styles on iOS.
- **No secrets** in the repo: API keys, server addresses, tokens.

## Development

See [docs/BUILD.md](docs/BUILD.md) to build the apps and the plugin, and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the pieces fit.

- After adding a Swift file, run `xcodegen`.
- Keep commits focused, with a message that says *why*.
- Open a pull request against `main`; Android work goes against the `android` / `android-tv` branches.

## Code style

Match the surrounding code. Swift: SwiftUI, `@Observable`, design tokens from `Theme.swift` instead of magic numbers. Kotlin: Compose, the shared `Spacing` and theme. C#: nullable on, small services.

## License

By contributing you agree your work is released under the [PolyForm Noncommercial License](LICENSE), and that the project owner may also license it in other ways (including commercially).
