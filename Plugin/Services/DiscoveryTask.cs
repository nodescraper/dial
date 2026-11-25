using MediaBrowser.Model.Tasks;

namespace Dial.Plugin.Services;

/// Renews everyone's Discovery feed every night.
public class DiscoveryTask : IScheduledTask
{
    readonly DiscoveryService _discovery;
    public DiscoveryTask(DiscoveryService discovery) { _discovery = discovery; }

    public string Name => "Refresh Dial Discovery";
    public string Key => "DialDiscovery";
    public string Description => "Looks up new releases, similar artists and concerts for each user.";
    public string Category => "Dial";

    public Task ExecuteAsync(IProgress<double> progress, CancellationToken cancellationToken)
        => _discovery.RefreshAllAsync(progress, cancellationToken);

    public IEnumerable<TaskTriggerInfo> GetDefaultTriggers() => new[]
    {
        new TaskTriggerInfo { Type = TaskTriggerInfoType.DailyTrigger, TimeOfDayTicks = TimeSpan.FromHours(4).Ticks },
    };
}

/// Makes everyone's mixtapes for the day, in the small hours.
public class MixtapeTask : IScheduledTask
{
    readonly MixtapeService _mixtapes;
    public MixtapeTask(MixtapeService mixtapes) { _mixtapes = mixtapes; }

    public string Name => "Refresh Dial Mixtapes";
    public string Key => "DialMixtapes";
    public string Description => "Builds each user's made-for-you mixtapes for the day.";
    public string Category => "Dial";

    public Task ExecuteAsync(IProgress<double> progress, CancellationToken cancellationToken)
        => _mixtapes.RefreshAllAsync(progress, cancellationToken);

    public IEnumerable<TaskTriggerInfo> GetDefaultTriggers() => new[]
    {
        new TaskTriggerInfo { Type = TaskTriggerInfoType.DailyTrigger, TimeOfDayTicks = TimeSpan.FromHours(4).Add(TimeSpan.FromMinutes(30)).Ticks },
    };
}
