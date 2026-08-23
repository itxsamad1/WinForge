using System.Text.Json;
using WinForge.Core.Models;

namespace WinForge.Core.Services;

public sealed class ProfileService
{
    private readonly AppPaths _paths;

    public ProfileService(AppPaths paths) => _paths = paths;

    private string ProfilesDir
    {
        get
        {
            var dir = Path.Combine(_paths.StateDir, "profiles");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    public async Task SaveAsync(UserProfile profile, string? filePath = null, CancellationToken ct = default)
    {
        filePath ??= Path.Combine(ProfilesDir, SanitizeFileName(profile.Name) + ".json");
        await JsonFileHelper.WriteAsync(filePath, profile, ct);
    }

    public async Task<UserProfile?> LoadAsync(string filePath, CancellationToken ct = default) =>
        await JsonFileHelper.ReadAsync<UserProfile>(filePath, ct);

    public IEnumerable<string> ListProfiles() =>
        Directory.Exists(ProfilesDir)
            ? Directory.EnumerateFiles(ProfilesDir, "*.json")
            : [];

    private static string SanitizeFileName(string name)
    {
        foreach (var c in Path.GetInvalidFileNameChars())
            name = name.Replace(c, '_');
        return string.IsNullOrWhiteSpace(name) ? "profile" : name.Trim();
    }
}

public sealed class CliRunner
{
    private readonly CatalogService _catalog;
    private readonly JobService _jobs;

    public CliRunner(CatalogService catalog, JobService jobs)
    {
        _catalog = catalog;
        _jobs = jobs;
    }

    public async Task<int> RunAsync(string[] args, CancellationToken ct = default)
    {
        if (args.Length == 0)
            return -1;

        string? preset = null;
        var install = false;
        var dryRun = false;
        var tweaks = new List<string>();

        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i].ToLowerInvariant())
            {
                case "--preset" when i + 1 < args.Length:
                    preset = args[++i];
                    break;
                case "--install":
                    install = true;
                    break;
                case "--dry-run":
                    dryRun = true;
                    break;
                case "--tweaks" when i + 1 < args.Length:
                    tweaks.AddRange(args[++i].Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
                    break;
            }
        }

        if (preset is null)
            return -1;

        var snapshot = _catalog.Load();
        var selectedPreset = snapshot.Presets.FirstOrDefault(p =>
            p.Key.Equals(preset, StringComparison.OrdinalIgnoreCase));

        if (selectedPreset is null)
            return 2;

        var plan = InstallPlanResolver.Resolve(snapshot.AppsByKey, selectedPreset.Apps);

        if (dryRun)
        {
            Console.WriteLine(JsonSerializer.Serialize(plan, new JsonSerializerOptions { WriteIndented = true }));
            return 0;
        }

        if (tweaks.Count > 0)
            await _jobs.RunTweaksAsync(tweaks, ct: ct);

        if (install)
        {
            var result = await _jobs.StartInstallJobAsync(plan, OptionsSanitizer.Sanitize(null), ct);
            if (!result.Started)
                return 3;
            Console.WriteLine($"Job started: {result.JobId}");
        }

        return 0;
    }
}
