using System.Text.Json;
using System.Text.Json.Serialization;
using WinForge.Core.Models;

namespace WinForge.Core.Services;

public sealed class CatalogService
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true
    };

    private readonly AppPaths _paths;
    private CatalogSnapshot? _cache;

    public CatalogService(AppPaths paths) => _paths = paths;

    public CatalogSnapshot Load(bool force = false)
    {
        if (!force && _cache is not null)
            return _cache;

        var appsPath = Path.Combine(_paths.CatalogDir, "apps.json");
        var presetsPath = Path.Combine(_paths.CatalogDir, "presets.json");
        var tweaksPath = Path.Combine(_paths.CatalogDir, "tweaks.json");
        var fixesPath = Path.Combine(_paths.CatalogDir, "fixes.json");
        var updatesPath = Path.Combine(_paths.CatalogDir, "updates.json");

        var appsDoc = ReadJson<AppsDocument>(appsPath)
            ?? throw new FileNotFoundException("Could not read apps catalog.", appsPath);

        var presetsDoc = ReadJson<PresetsDocument>(presetsPath);
        var tweaksDoc = ReadJson<TweaksDocument>(tweaksPath);
        var fixesDoc = ReadJson<FixesDocument>(fixesPath);
        var updatesDoc = ReadJson<UpdatesDocument>(updatesPath);

        var appsByKey = new Dictionary<string, CatalogApp>(StringComparer.OrdinalIgnoreCase);
        foreach (var app in appsDoc.Apps)
        {
            if (string.IsNullOrWhiteSpace(app.Key))
                continue;
            appsByKey[app.Key] = app;
        }

        _cache = new CatalogSnapshot
        {
            Categories = appsDoc.Categories,
            Apps = appsByKey.Values.OrderBy(a => appsDoc.Apps.FindIndex(x => x.Key == a.Key)).ToList(),
            AppsByKey = appsByKey,
            Presets = presetsDoc?.Presets ?? [],
            Tweaks = tweaksDoc?.Tweaks ?? [],
            Fixes = fixesDoc?.Fixes ?? [],
            UpdatePolicies = updatesDoc?.Policies ?? []
        };

        return _cache;
    }

    private static T? ReadJson<T>(string path) where T : class
    {
        if (!File.Exists(path))
            return null;
        var json = File.ReadAllText(path);
        return JsonSerializer.Deserialize<T>(json, JsonOptions);
    }

    private sealed class AppsDocument
    {
        public List<Category> Categories { get; set; } = [];
        public List<CatalogApp> Apps { get; set; } = [];
    }

    private sealed class PresetsDocument
    {
        public List<Preset> Presets { get; set; } = [];
    }

    private sealed class TweaksDocument
    {
        public List<TweakEntry> Tweaks { get; set; } = [];
    }

    private sealed class FixesDocument
    {
        public List<FixEntry> Fixes { get; set; } = [];
    }

    private sealed class UpdatesDocument
    {
        public List<UpdatePolicyEntry> Policies { get; set; } = [];
    }
}

public sealed class CatalogSnapshot
{
    public List<Category> Categories { get; init; } = [];
    public List<CatalogApp> Apps { get; init; } = [];
    public Dictionary<string, CatalogApp> AppsByKey { get; init; } = new(StringComparer.OrdinalIgnoreCase);
    public List<Preset> Presets { get; init; } = [];
    public List<TweakEntry> Tweaks { get; init; } = [];
    public List<FixEntry> Fixes { get; init; } = [];
    public List<UpdatePolicyEntry> UpdatePolicies { get; init; } = [];
}
