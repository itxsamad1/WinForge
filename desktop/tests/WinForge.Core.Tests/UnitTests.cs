using WinForge.Core.Models;
using WinForge.Core.Services;
using Xunit;

namespace WinForge.Core.Tests;

public class InstallPlanResolverTests
{
    [Fact]
    public void OrdersAfterDependencies()
    {
        var catalog = new Dictionary<string, CatalogApp>(StringComparer.OrdinalIgnoreCase)
        {
            ["android-studio"] = new()
            {
                Key = "android-studio",
                Name = "Android Studio",
                After = ["temurin-21"]
            },
            ["temurin-21"] = new() { Key = "temurin-21", Name = "Temurin 21" }
        };

        var plan = InstallPlanResolver.Resolve(catalog, ["android-studio", "temurin-21"]);

        Assert.Equal(2, plan.Steps.Count);
        Assert.Equal("temurin-21", plan.Steps[0].Key);
        Assert.Equal("android-studio", plan.Steps[1].Key);
    }

    [Fact]
    public void RejectsUnknownKeys()
    {
        var catalog = new Dictionary<string, CatalogApp>(StringComparer.OrdinalIgnoreCase)
        {
            ["git"] = new() { Key = "git", Name = "Git" }
        };

        var plan = InstallPlanResolver.Resolve(catalog, ["git", "not-real"]);

        Assert.Single(plan.Steps);
        Assert.Equal("not-real", plan.Unknown[0]);
    }

    [Fact]
    public void DeduplicatesRequestedKeys()
    {
        var catalog = new Dictionary<string, CatalogApp>(StringComparer.OrdinalIgnoreCase)
        {
            ["git"] = new() { Key = "git", Name = "Git" }
        };

        var plan = InstallPlanResolver.Resolve(catalog, ["git", "git", "GIT"]);
        Assert.Single(plan.Steps);
    }

    [Fact]
    public void DoesNotAutoAddMissingDependencies()
    {
        var catalog = new Dictionary<string, CatalogApp>(StringComparer.OrdinalIgnoreCase)
        {
            ["android-studio"] = new()
            {
                Key = "android-studio",
                Name = "Android Studio",
                After = ["temurin-21"]
            },
            ["temurin-21"] = new() { Key = "temurin-21", Name = "Temurin 21" }
        };

        var plan = InstallPlanResolver.Resolve(catalog, ["android-studio"]);
        Assert.Single(plan.Steps);
        Assert.Equal("android-studio", plan.Steps[0].Key);
    }
}

public class OptionsSanitizerTests
{
    [Fact]
    public void StripsInvalidEmailAndShellChars()
    {
        var result = OptionsSanitizer.Sanitize(new InstallOptions
        {
            GitName = "Ada \"Lovelace\"",
            GitEmail = "not-an-email",
            VscodeExtensions = ["ms-python.python", "bad id"]
        });

        Assert.Equal("Ada Lovelace", result.GitName);
        Assert.Equal("", result.GitEmail);
        Assert.Single(result.VscodeExtensions);
        Assert.Equal("ms-python.python", result.VscodeExtensions[0]);
    }

    [Fact]
    public void CapsExtensionLists()
    {
        var extensions = Enumerable.Range(0, 60)
            .Select(i => $"pub.ext{i}")
            .ToList();

        var result = OptionsSanitizer.Sanitize(new InstallOptions
        {
            VscodeExtensions = extensions
        });

        Assert.Equal(50, result.VscodeExtensions.Count);
    }
}

public class CatalogServiceTests
{
    [Fact]
    public void LoadsAppsAndPresetsFromRepo()
    {
        var root = FindRepoRoot();
        var service = new CatalogService(new AppPaths(root));
        var snap = service.Load(force: true);

        Assert.True(snap.Apps.Count > 50);
        Assert.True(snap.Presets.Count >= 5);
        Assert.True(snap.Tweaks.Count >= 3);
        Assert.True(snap.Fixes.Count >= 3);
        Assert.True(snap.UpdatePolicies.Count >= 3);
    }

    [Fact]
    public void EveryPresetAppExistsInCatalog()
    {
        var root = FindRepoRoot();
        var snap = new CatalogService(new AppPaths(root)).Load(force: true);

        foreach (var preset in snap.Presets)
        {
            foreach (var key in preset.Apps)
            {
                Assert.True(snap.AppsByKey.ContainsKey(key),
                    $"Preset '{preset.Key}' references missing app '{key}'");
            }
        }
    }

    [Fact]
    public void TweakScriptsExistOnDisk()
    {
        var root = FindRepoRoot();
        var snap = new CatalogService(new AppPaths(root)).Load(force: true);

        foreach (var tweak in snap.Tweaks)
        {
            if (!string.IsNullOrWhiteSpace(tweak.ApplyScript))
            {
                var path = Path.Combine(root, "catalog", tweak.ApplyScript.Replace('/', Path.DirectorySeparatorChar));
                Assert.True(File.Exists(path), $"Missing apply script: {path}");
            }

            if (!string.IsNullOrWhiteSpace(tweak.UndoScript))
            {
                var path = Path.Combine(root, "catalog", tweak.UndoScript.Replace('/', Path.DirectorySeparatorChar));
                Assert.True(File.Exists(path), $"Missing undo script: {path}");
            }
        }
    }

    private static string FindRepoRoot()
    {
        var dir = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (dir is not null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "catalog", "apps.json")))
                return dir.FullName;
            dir = dir.Parent;
        }

        throw new InvalidOperationException("Could not find repo root.");
    }
}

public class ProfileServiceTests
{
    [Fact]
    public async Task RoundTripsProfileJson()
    {
        var temp = Path.Combine(Path.GetTempPath(), "winforge-test-" + Guid.NewGuid().ToString("n"));
        Directory.CreateDirectory(temp);
        try
        {
            var paths = new AppPaths(temp);
            // Force state under temp by using a custom AppPaths — ProfileService uses StateDir.
            // Create a profile file directly via JsonFileHelper path.
            var service = new ProfileService(paths);
            var profile = new UserProfile
            {
                Name = "lab",
                Apps = ["git", "vscode"],
                Tweaks = ["show-file-extensions"],
                Options = new InstallOptions { GitName = "Ada", GitEmail = "ada@example.com" }
            };

            var file = Path.Combine(temp, "lab.json");
            await service.SaveAsync(profile, file);
            var loaded = await service.LoadAsync(file);

            Assert.NotNull(loaded);
            Assert.Equal("lab", loaded!.Name);
            Assert.Equal(2, loaded.Apps.Count);
            Assert.Equal("Ada", loaded.Options.GitName);
        }
        finally
        {
            try { Directory.Delete(temp, true); } catch { /* ignore */ }
        }
    }
}

public class CliRunnerTests
{
    [Fact]
    public async Task DryRunReturnsZeroForKnownPreset()
    {
        var root = FindRepoRoot();
        var paths = new AppPaths(root);
        var catalog = new CatalogService(paths);
        var jobs = new JobService(paths, new PowerShellRunner(paths));
        var cli = new CliRunner(catalog, jobs);

        var code = await cli.RunAsync(["--preset", "web", "--dry-run"]);
        Assert.Equal(0, code);
    }

    [Fact]
    public async Task UnknownPresetReturnsTwo()
    {
        var root = FindRepoRoot();
        var paths = new AppPaths(root);
        var catalog = new CatalogService(paths);
        var jobs = new JobService(paths, new PowerShellRunner(paths));
        var cli = new CliRunner(catalog, jobs);

        var code = await cli.RunAsync(["--preset", "does-not-exist", "--dry-run"]);
        Assert.Equal(2, code);
    }

    private static string FindRepoRoot()
    {
        var dir = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (dir is not null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "catalog", "apps.json")))
                return dir.FullName;
            dir = dir.Parent;
        }

        throw new InvalidOperationException("Could not find repo root.");
    }
}
