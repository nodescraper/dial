package app.dial.data

/** Your library, to tell what you have from what you don't. */
class Owned(val artists: List<Item>, val albums: List<Item>) {
    fun artist(pick: PublicMusic.Pick): Item? =
        artists.firstOrNull { it.musicBrainzId == pick.mbid } ?: artists.firstOrNull { ArtistNames.key(it.name) == ArtistNames.key(pick.title) }
    fun artistOf(pick: PublicMusic.Pick): Item? =
        pick.artistMbid?.let { m -> artists.firstOrNull { it.musicBrainzId == m } }
            ?: pick.artist?.let { a -> artists.firstOrNull { ArtistNames.key(it.name) == ArtistNames.key(ArtistNames.primary(a)) } }
    fun album(pick: PublicMusic.Pick): Item? = albums.firstOrNull {
        LibraryMatcher.key(it.name) == LibraryMatcher.key(pick.title) &&
            (pick.artist == null || ArtistNames.key(ArtistNames.primary(it.albumArtistLine)) == ArtistNames.key(ArtistNames.primary(pick.artist)))
    }
}
