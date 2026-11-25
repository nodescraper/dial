using MediaBrowser.Model.Plugins;

namespace Dial.Plugin;

public class PluginConfiguration : BasePluginConfiguration
{
    /// Ticketmaster Discovery API key. Empty turns concerts off.
    public string TicketmasterKey { get; set; } = "";
    /// Country code used for concerts, e.g. "HU".
    public string CountryCode { get; set; } = "";
    public bool ConcertsEnabled { get; set; } = true;
}
