namespace WinForge.Core;

public sealed class AppPaths
{
    public string Root { get; }
    public string CatalogDir { get; }
    public string EngineDir { get; }
    public string StateDir { get; }
    public string JobsDir { get; }

    public AppPaths(string? rootOverride = null)
    {
        Root = rootOverride ?? ResolveRoot();
        CatalogDir = Path.Combine(Root, "catalog");
        EngineDir = Path.Combine(Root, "engine");
        StateDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "WinForge",
            "state");
        JobsDir = Path.Combine(StateDir, "jobs");
    }

    private static string ResolveRoot()
    {
        var baseDir = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

        // Published layout: WinForge.exe with catalog/ and engine/ next to it.
        if (Directory.Exists(Path.Combine(baseDir, "catalog")))
            return baseDir;

        // Dev layout: desktop/src/WinForge.App/bin/... -> repo root
        var dir = new DirectoryInfo(baseDir);
        while (dir is not null)
        {
            if (Directory.Exists(Path.Combine(dir.FullName, "catalog"))
                && Directory.Exists(Path.Combine(dir.FullName, "server")))
            {
                return dir.FullName;
            }

            if (dir.Name == "WinForge.App" && dir.Parent?.Parent?.Parent is DirectoryInfo desktop)
            {
                var repoRoot = desktop.Parent;
                if (repoRoot is not null && Directory.Exists(Path.Combine(repoRoot.FullName, "catalog")))
                    return repoRoot.FullName;
            }

            dir = dir.Parent;
        }

        return baseDir;
    }

    public void EnsureStateDirectories()
    {
        Directory.CreateDirectory(StateDir);
        Directory.CreateDirectory(JobsDir);
    }
}
