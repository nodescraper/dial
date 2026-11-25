package app.dial.data

/**
 * Folds the many spellings of a genre into one family by meaning, not exact spelling: "Reggaeton", "Trap Latino"
 * and "Urbano Latino" are all Latin; "Hip-Hop/Rap" is Hip-Hop. The same rules as Dial on iPhone and Mac.
 */
object GenreNames {
    private class Rule(val family: String, val contains: List<String> = emptyList(),
                       val words: List<String> = emptyList(), val whole: List<String> = emptyList())

    /** In priority order: the first family that fits a tag wins ("Latin Pop" is Latin, "Pop Rap" is Hip-Hop). */
    private val rules = listOf(
        Rule("Latin", contains = listOf("latin", "reggaeton", "urbano", "bachata", "salsa", "cumbia", "dembow", "corrido",
            "regionalmexican", "banda", "norteno", "merengue", "flamenco", "mariachi", "vallenato", "perreo", "tropical",
            "mexican", "reguet", "sertanejo", "bossanova"), words = listOf("mpb", "tejano")),
        Rule("K-Pop", contains = listOf("kpop", "korean", "jpop", "japanese")),
        Rule("Afrobeats", contains = listOf("afrobeat", "afropop", "amapiano", "highlife", "afroswing", "naija")),
        Rule("Reggae", contains = listOf("reggae", "dancehall"), words = listOf("ska", "dub")),
        Rule("Hip-Hop", contains = listOf("hiphop", "drill", "grime", "boombap", "gangsta", "mumble"), words = listOf("rap", "trap", "hh")),
        Rule("R&B", contains = listOf("rhythmandblues", "contemporaryrb", "alternativerb"), whole = listOf("rb", "rnb", "randb")),
        Rule("Soul", contains = listOf("soul", "motown")),
        Rule("Funk", contains = listOf("funk")),
        Rule("Disco", contains = listOf("disco")),
        Rule("Metal", contains = listOf("metal")),
        Rule("Punk", contains = listOf("punk", "hardcore"), words = listOf("emo")),
        Rule("Indie", contains = listOf("indie", "shoegaze", "dreampop")),
        Rule("Alternative", contains = listOf("alternative", "grunge", "newwave", "postrock"), words = listOf("alt")),
        Rule("Rock", contains = listOf("rock", "psychedelic")),
        Rule("Electronic", contains = listOf("electro", "techno", "trance", "dubstep", "synth", "drumandbass", "ambient",
            "downtempo", "idm", "triphop", "chillout", "lofi"), words = listOf("edm", "dnb")),
        Rule("Dance", contains = listOf("dance", "house", "club", "garage", "eurodance")),
        Rule("Pop", contains = listOf("pop")),
        Rule("Jazz", contains = listOf("jazz", "swing", "bebop", "bigband")),
        Rule("Blues", contains = listOf("blues")),
        Rule("Country", contains = listOf("country", "bluegrass", "americana")),
        Rule("Folk", contains = listOf("folk", "singersongwriter", "acoustic")),
        Rule("Classical", contains = listOf("classical", "orchestra", "opera", "baroque", "symphon", "chambermusic")),
        Rule("Soundtrack", contains = listOf("soundtrack", "score", "musical"), words = listOf("ost", "film")),
        Rule("Gospel", contains = listOf("gospel", "christian", "worship")),
    )

    /** The genres a tag stands for ("Pop, Rock" is two; "Trap Latino" is one: Latin). */
    fun canonical(tag: String): List<String> {
        val names = LinkedHashSet<String>()
        for (part in tag.split(',', ';', '/', '|').map { it.trim() }.filter { it.isNotEmpty() }) {
            names += family(part) ?: titleCase(part)
        }
        return names.toList()
    }

    /** Every family for a list of tags, in order, without repeats. */
    fun families(tags: List<String>): List<String> = tags.flatMap(::canonical).distinct()

    private fun family(part: String): String? {
        val lower = part.lowercase()
        val squashed = lower.replace("&", "and").filter { it.isLetterOrDigit() }
        val words = lower.replace("&", " and ").split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }.toSet()
        val whole = if ("&" in lower) lower.filter { it.isLetter() } else squashed
        for (rule in rules) {
            if (whole in rule.whole || squashed in rule.whole) return rule.family
            if (rule.contains.any { it in squashed }) return rule.family
            if (rule.words.any { it in words }) return rule.family
        }
        return null
    }

    private fun titleCase(text: String) =
        text.split(' ').joinToString(" ") { it.take(1).uppercase() + it.drop(1).lowercase() }
}

/**
 * Decides what genre every album is, in order of trust: its own file tags, grouped by meaning; its artist's genres
 * (from their other tagged albums) for albums with no tag; MusicBrainz's genres for artists with no tags at all
 * (looked up a few at a time and saved). AudioMuse is only for how music feels, never for genres.
 */
object GenreResolver {
    private fun artistKey(album: Item): String =
        ArtistNames.key(album.albumArtist ?: album.albumArtists?.firstOrNull()?.name ?: album.artistItems?.firstOrNull()?.name ?: "")

    /** Album id to its genre families. `lookups` is how many new MusicBrainz lookups may run. */
    suspend fun families(albums: List<Item>, lookups: Int = 0): Map<String, List<String>> {
        val own = HashMap<String, List<String>>()
        val tally = HashMap<String, HashMap<String, Int>>()
        for (album in albums) {
            val found = GenreNames.families(album.genres ?: emptyList())
            own[album.id] = found
            val counts = tally.getOrPut(artistKey(album)) { HashMap() }
            for (family in found) counts[family] = (counts[family] ?: 0) + 1
        }
        // An artist's genres: those on at least a third of their tagged albums, at most three.
        val artist = HashMap<String, List<String>>()
        for ((key, counts) in tally) {
            val top = counts.values.maxOrNull() ?: 0
            artist[key] = counts.filter { it.value * 3 >= top }.entries.sortedByDescending { it.value }.take(3).map { it.key }
        }
        // Artists with nothing: MusicBrainz, saved answers first, a few new lookups.
        var remaining = lookups
        val asked = HashSet<String>()
        for (album in albums) {
            val key = artistKey(album)
            if (own[album.id]?.isEmpty() != true || artist[key] != null || key.isEmpty() || !asked.add(key)) continue
            val name = ArtistNames.primary(album.albumArtist ?: album.albumArtists?.firstOrNull()?.name ?: "")
            var tags = PublicMusic.artistGenres(name, fetch = false)
            if (tags == null && remaining > 0) {
                remaining--
                tags = PublicMusic.artistGenres(name, fetch = true)
            }
            artist[key] = GenreNames.families(tags ?: emptyList()).take(3)
        }
        return albums.associate { album ->
            val mine = own[album.id] ?: emptyList()
            album.id to if (mine.isEmpty()) artist[artistKey(album)] ?: emptyList() else mine
        }
    }
}
