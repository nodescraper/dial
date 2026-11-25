using MediaBrowser.Common.Configuration;
using MediaBrowser.Common.Plugins;
using MediaBrowser.Model.Plugins;
using MediaBrowser.Model.Serialization;

namespace Dial.Plugin;

public class DialPlugin : BasePlugin<PluginConfiguration>, IHasWebPages
{
    public DialPlugin(IApplicationPaths applicationPaths, IXmlSerializer xmlSerializer)
        : base(applicationPaths, xmlSerializer) { Instance = this; }

    public static DialPlugin? Instance { get; private set; }
    public override string Name => "Dial";
    public override Guid Id => Guid.Parse("b5c1f0a2-7d3e-4c58-9a41-2f6e8d0c1b73");
    public IEnumerable<PluginPageInfo> GetPages() => new[]
    {
        new PluginPageInfo { Name = "Dial", EmbeddedResourcePath = GetType().Namespace + ".Web.config.html" },
    };

    public override string Description => "Discovery and mixtapes for the Dial music app.";
}
