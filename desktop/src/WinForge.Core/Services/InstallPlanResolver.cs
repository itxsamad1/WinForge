using System.Text.RegularExpressions;
using WinForge.Core.Models;

namespace WinForge.Core.Services;

public static partial class InstallPlanResolver
{
    public static InstallPlan Resolve(IReadOnlyDictionary<string, CatalogApp> catalog, IEnumerable<string> keys)
    {
        var requested = new List<string>();
        var unknown = new List<string>();

        foreach (var key in keys)
        {
            if (string.IsNullOrWhiteSpace(key))
                continue;
            if (requested.Contains(key, StringComparer.OrdinalIgnoreCase))
                continue;

            if (catalog.ContainsKey(key))
                requested.Add(key);
            else
                unknown.Add(key);
        }

        var ordered = new List<string>();
        var state = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        foreach (var key in requested)
            AddOrdered(key, requested, catalog, state, ordered);

        var steps = ordered.Select(key =>
        {
            var app = catalog[key];
            return new InstallStep
            {
                Key = key,
                Name = string.IsNullOrWhiteSpace(app.Name) ? key : app.Name,
                Kind = string.IsNullOrWhiteSpace(app.Kind) ? "winget" : app.Kind,
                Id = app.Id,
                Scope = app.Scope,
                Source = string.IsNullOrWhiteSpace(app.Source) ? "winget" : app.Source,
                Override = app.Override,
                Command = app.Command,
                Url = app.Url,
                Instructions = app.Instructions,
                PostInstall = [.. app.PostInstall],
                Reboot = app.RequiresRestart
            };
        }).ToList();

        return new InstallPlan { Steps = steps, Unknown = unknown };
    }

    private static void AddOrdered(
        string key,
        IReadOnlyList<string> requested,
        IReadOnlyDictionary<string, CatalogApp> catalog,
        Dictionary<string, string> state,
        List<string> ordered)
    {
        if (state.TryGetValue(key, out var existing))
        {
            if (existing == "done")
                return;
            return; // cycle
        }

        state[key] = "visiting";
        if (catalog.TryGetValue(key, out var app))
        {
            foreach (var dep in app.After)
            {
                if (requested.Contains(dep, StringComparer.OrdinalIgnoreCase))
                    AddOrdered(dep, requested, catalog, state, ordered);
            }
        }

        state[key] = "done";
        ordered.Add(key);
    }
}

public static partial class OptionsSanitizer
{
    [GeneratedRegex(@"[`""$;&|<>\r\n]")]
    private static partial Regex ShellChars();

    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9\-]*\.[A-Za-z0-9][A-Za-z0-9\-\.]*$")]
    private static partial Regex ExtensionId();

    [GeneratedRegex(@"^[^@\s]+@[^@\s]+\.[^@\s]+$")]
    private static partial Regex EmailPattern();

    public static InstallOptions Sanitize(InstallOptions? raw)
    {
        raw ??= new InstallOptions();

        var gitName = raw.GitName.Length > 100 ? raw.GitName[..100] : raw.GitName;
        var gitEmail = raw.GitEmail.Length > 200 ? raw.GitEmail[..200] : raw.GitEmail;

        if (!string.IsNullOrEmpty(gitEmail) && !EmailPattern().IsMatch(gitEmail))
            gitEmail = "";

        gitName = ShellChars().Replace(gitName, "").Trim();

        return new InstallOptions
        {
            GitName = gitName,
            GitEmail = gitEmail,
            VscodeExtensions = raw.VscodeExtensions.Where(e => ExtensionId().IsMatch(e)).Take(50).ToList(),
            CursorExtensions = raw.CursorExtensions.Where(e => ExtensionId().IsMatch(e)).Take(50).ToList()
        };
    }
}
