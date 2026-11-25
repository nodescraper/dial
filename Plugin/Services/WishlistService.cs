using System.Text.Json;

namespace Dial.Plugin.Services;

/// Each user's wishlist: albums and songs they want but don't have, kept on the server so every device shows the same list.
/// The apps decide what an item holds; the server only needs its "id", keeps the newest first and saves it to disk.
public class WishlistService
{
    readonly object _lock = new();
    const int MaxItems = 1000;
    const int MaxItemLength = 4000;

    static string FileFor(Guid userId)
    {
        var folder = Path.Combine(DialPlugin.Instance!.DataFolderPath, "data");
        Directory.CreateDirectory(folder);
        return Path.Combine(folder, $"wishlist-{userId:N}.json");
    }

    public string Read(Guid userId)
    {
        lock (_lock) return JsonSerializer.Serialize(Load(userId));
    }

    /// Adds an item (or moves it to the top if it is already there). False when it has no id or is too large.
    public bool Add(Guid userId, JsonElement item, out string json)
    {
        json = "";
        var id = IdOf(item);
        if (string.IsNullOrEmpty(id) || item.GetRawText().Length > MaxItemLength) return false;
        lock (_lock)
        {
            var list = Load(userId);
            list.RemoveAll(e => IdOf(e) == id);
            list.Insert(0, item.Clone());
            if (list.Count > MaxItems) list.RemoveRange(MaxItems, list.Count - MaxItems);
            json = Save(userId, list);
        }
        return true;
    }

    public string Remove(Guid userId, string id)
    {
        lock (_lock)
        {
            var list = Load(userId);
            list.RemoveAll(e => IdOf(e) == id);
            return Save(userId, list);
        }
    }

    static List<JsonElement> Load(Guid userId)
    {
        var file = FileFor(userId);
        if (!File.Exists(file)) return new();
        try { return JsonSerializer.Deserialize<List<JsonElement>>(File.ReadAllText(file)) ?? new(); }
        catch { return new(); }
    }

    static string Save(Guid userId, List<JsonElement> list)
    {
        var json = JsonSerializer.Serialize(list);
        File.WriteAllText(FileFor(userId), json);
        return json;
    }

    static string? IdOf(JsonElement e) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty("id", out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
}
