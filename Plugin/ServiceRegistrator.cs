using MediaBrowser.Controller;
using MediaBrowser.Controller.Plugins;
using Microsoft.Extensions.DependencyInjection;
using Dial.Plugin.Services;

namespace Dial.Plugin;

public class ServiceRegistrator : IPluginServiceRegistrator
{
    public void RegisterServices(IServiceCollection services, IServerApplicationHost applicationHost)
    {
        services.AddSingleton<DiscoveryService>();
        services.AddSingleton<MixtapeService>();
        services.AddSingleton<WishlistService>();
    }
}
