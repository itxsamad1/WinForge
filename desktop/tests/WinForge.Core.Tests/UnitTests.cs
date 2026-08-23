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
