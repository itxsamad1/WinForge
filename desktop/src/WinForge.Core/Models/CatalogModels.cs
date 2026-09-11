using System.Text.Json.Serialization;

namespace WinForge.Core.Models;

public sealed class Category
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Icon { get; set; } = "";
}

public sealed class CatalogApp
{
    public string Key { get; set; } = "";
    public string Name { get; set; } = "";
    public string? Id { get; set; }
    public string Category { get; set; } = "";
    public string? Description { get; set; }
    public string? Notes { get; set; }
    public bool Popular { get; set; }
    public string Kind { get; set; } = "winget";
    public string? Scope { get; set; }
    public string? Source { get; set; }
    public string? Override { get; set; }
    public string? Command { get; set; }
    public string? Url { get; set; }
    public string? Instructions { get; set; }
    public List<string> After { get; set; } = [];
    public List<string> PostInstall { get; set; } = [];
    public bool RequiresRestart { get; set; }
    public DetectRules? Detect { get; set; }
}

public sealed class DetectRules
{
    public string? Cmd { get; set; }
    public string? Registry { get; set; }
    public string? Path { get; set; }
}

public sealed class Preset
{
    public string Key { get; set; } = "";
    public string Name { get; set; } = "";
    public string? Description { get; set; }
    public List<string> Apps { get; set; } = [];
}

public sealed class InstallStep
{
    public string Key { get; set; } = "";
    public string Name { get; set; } = "";
    public string Kind { get; set; } = "winget";
    public string? Id { get; set; }
    public string? Scope { get; set; }
    public string Source { get; set; } = "winget";
    public string? Override { get; set; }
    public string? Command { get; set; }
    public string? Url { get; set; }
    public string? Instructions { get; set; }
    public List<string> PostInstall { get; set; } = [];
    public bool Reboot { get; set; }
}

public sealed class InstallPlan
{
    public List<InstallStep> Steps { get; set; } = [];
    public List<string> Unknown { get; set; } = [];
}

public sealed class InstallOptions
{
    public string GitName { get; set; } = "";
    public string GitEmail { get; set; } = "";
    public List<string> VscodeExtensions { get; set; } = [];
    public List<string> CursorExtensions { get; set; } = [];
}

public sealed class JobStepStatus
{
    public int Index { get; set; }
    public string Key { get; set; } = "";
    public string Name { get; set; } = "";
    public string Kind { get; set; } = "winget";
    public string State { get; set; } = "pending";
    public string? Message { get; set; }
    public int? ExitCode { get; set; }
    public string? Phase { get; set; }
    public int? Percent { get; set; }
    public string? ProgressDetail { get; set; }
    public string LogFile { get; set; } = "";
    public string? StartedAt { get; set; }
    public string? FinishedAt { get; set; }
}

public sealed class JobStatus
{
    public string JobId { get; set; } = "";
    public string State { get; set; } = "pending";
    public string? StartedAt { get; set; }
    public string? FinishedAt { get; set; }
    public bool Elevated { get; set; }
    public bool RebootNeeded { get; set; }
    public string? LaunchError { get; set; }
    public List<JobStepStatus> Steps { get; set; } = [];
}

public sealed class TweakEntry
{
    public string Key { get; set; } = "";
    public string Name { get; set; } = "";
    public string Group { get; set; } = "";
    public string Risk { get; set; } = "safe";
    public string? Description { get; set; }
    public string? ApplyScript { get; set; }
    public string? UndoScript { get; set; }

    [JsonIgnore]
    public bool IsSelected { get; set; }
}

public sealed class FixEntry
{
    public string Key { get; set; } = "";
    public string Name { get; set; } = "";
    public string? Description { get; set; }
    public string? Script { get; set; }
    public string? Panel { get; set; }
}

public sealed class UpdatePolicyEntry
{
    public string Key { get; set; } = "";
    public string Name { get; set; } = "";
    public string? Description { get; set; }
    public string? Warning { get; set; }
    public string? Script { get; set; }
}

public sealed class UserProfile
{
    public string Name { get; set; } = "";
    public List<string> Apps { get; set; } = [];
    public List<string> Tweaks { get; set; } = [];
    public string? UpdatePolicy { get; set; }
    public InstallOptions Options { get; set; } = new();
}
