using System.Diagnostics;
using System.Security.Principal;
using System.Text.RegularExpressions;
using WinForge.Core.Models;

namespace WinForge.Core.Services;

public sealed class PowerShellRunner
{
    private readonly AppPaths _paths;

    public PowerShellRunner(AppPaths paths) => _paths = paths;

    public static bool IsElevated()
    {
        if (!OperatingSystem.IsWindows())
            return false;

        using var identity = WindowsIdentity.GetCurrent();
        var principal = new WindowsPrincipal(identity);
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }

    public ProcessStartInfo CreateStartInfo(string scriptPath, IDictionary<string, string>? arguments = null, bool hidden = true)
    {
        var args = new List<string>
        {
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy", "Bypass",
            "-File", Quote(scriptPath)
        };

        if (arguments is not null)
        {
            foreach (var (key, value) in arguments)
            {
                args.Add($"-{key}");
                args.Add(Quote(value));
            }
        }

        return new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = string.Join(' ', args),
            UseShellExecute = false,
            CreateNoWindow = hidden,
            WindowStyle = hidden ? ProcessWindowStyle.Hidden : ProcessWindowStyle.Normal,
            WorkingDirectory = _paths.Root
        };
    }

    public ProcessStartInfo CreateElevatedStartInfo(string scriptPath, IDictionary<string, string>? arguments = null)
    {
        var info = CreateStartInfo(scriptPath, arguments);
        if (!IsElevated())
            info.Verb = "runas";
        return info;
    }

    public async Task<int> RunAsync(ProcessStartInfo startInfo, CancellationToken ct = default)
    {
        using var process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("Could not start PowerShell.");

        await process.WaitForExitAsync(ct);
        return process.ExitCode;
    }

    public Process StartDetached(ProcessStartInfo startInfo) =>
        Process.Start(startInfo) ?? throw new InvalidOperationException("Could not start PowerShell.");

    private static string Quote(string value) =>
        value.Contains('"') ? $"'{value.Replace("'", "''")}'" : $"\"{value}\"";
}

public sealed class JobService
{
    private static readonly Regex JobIdPattern = new(@"^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$", RegexOptions.Compiled);

    private readonly AppPaths _paths;
    private readonly PowerShellRunner _runner;

    public JobService(AppPaths paths, PowerShellRunner runner)
    {
        _paths = paths;
        _runner = runner;
    }

    public async Task<JobLaunchResult> StartInstallJobAsync(InstallPlan plan, InstallOptions options, CancellationToken ct = default)
    {
        _paths.EnsureStateDirectories();

        var jobId = $"{DateTime.Now:yyyyMMdd-HHmmss}-{Guid.NewGuid():N[..6]}";
        var jobDir = Path.Combine(_paths.JobsDir, jobId);
        Directory.CreateDirectory(Path.Combine(jobDir, "logs"));

        var planDocument = new
        {
            jobId,
            createdAt = DateTimeOffset.Now.ToString("o"),
            options,
            steps = plan.Steps
        };

        await JsonFileHelper.WriteAsync(Path.Combine(jobDir, "plan.json"), planDocument, ct);

        var needsElevation = !PowerShellRunner.IsElevated();
        var seedSteps = plan.Steps.Select((step, index) => new JobStepStatus
        {
            Index = index,
            Key = step.Key,
            Name = step.Name,
            Kind = step.Kind,
            State = "pending",
            LogFile = $"{index}.log"
        }).ToList();

        await JsonFileHelper.WriteAsync(Path.Combine(jobDir, "status.json"), new JobStatus
        {
            JobId = jobId,
            State = needsElevation ? "awaiting_elevation" : "starting",
            Elevated = !needsElevation,
            Steps = seedSteps
        }, ct);

        var launcher = Path.Combine(_paths.EngineDir, "Launch-Job.ps1");
        if (!File.Exists(launcher))
            launcher = Path.Combine(_paths.Root, "server", "Launch-Job.ps1");

        var startInfo = _runner.CreateStartInfo(launcher, new Dictionary<string, string>
        {
            ["JobDir"] = jobDir,
            ["Root"] = _paths.Root
        });

        try
        {
            _runner.StartDetached(startInfo);
            return new JobLaunchResult(jobId, true, needsElevation, null);
        }
        catch (Exception ex)
        {
            var status = await JsonFileHelper.ReadAsync<JobStatus>(Path.Combine(jobDir, "status.json"), ct);
            if (status is not null)
            {
                status.State = "failed";
                status.FinishedAt = DateTimeOffset.Now.ToString("o");
                status.LaunchError = ex.Message;
                await JsonFileHelper.WriteAsync(Path.Combine(jobDir, "status.json"), status, ct);
            }

            return new JobLaunchResult(jobId, false, needsElevation, ex.Message);
        }
    }

    public async Task<JobStatus?> GetJobStatusAsync(string jobId, CancellationToken ct = default)
    {
        if (!JobIdPattern.IsMatch(jobId))
            return null;

        var path = Path.Combine(_paths.JobsDir, jobId, "status.json");
        return await JsonFileHelper.ReadAsync<JobStatus>(path, ct);
    }

    public async Task<List<string>> ReadLogTailAsync(string jobId, int stepIndex, int since = 0, CancellationToken ct = default)
    {
        var logPath = Path.Combine(_paths.JobsDir, jobId, "logs", $"{stepIndex}.log");
        if (!File.Exists(logPath))
            return [];

        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                await using var stream = new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
                using var reader = new StreamReader(stream);
                var lines = new List<string>();
                while (await reader.ReadLineAsync(ct) is { } line)
                    lines.Add(line);

                if (since >= lines.Count)
                    return [];

                return lines.Skip(since).ToList();
            }
            catch (IOException) when (attempt < 2)
            {
                await Task.Delay(50, ct);
            }
        }

        return [];
    }

    public async Task RunTweaksAsync(IEnumerable<string> tweakKeys, bool undo = false, CancellationToken ct = default)
    {
        var script = Path.Combine(_paths.EngineDir, undo ? "Undo-Tweaks.ps1" : "Apply-Tweaks.ps1");
        var keys = string.Join(",", tweakKeys);
        var startInfo = _runner.CreateElevatedStartInfo(script, new Dictionary<string, string>
        {
            ["Keys"] = keys,
            ["Root"] = _paths.Root
        });
        await _runner.RunAsync(startInfo, ct);
    }

    public async Task RunFixAsync(string fixKey, CancellationToken ct = default)
    {
        var script = Path.Combine(_paths.EngineDir, "Run-Fix.ps1");
        var startInfo = _runner.CreateElevatedStartInfo(script, new Dictionary<string, string>
        {
            ["Key"] = fixKey,
            ["Root"] = _paths.Root
        });
        await _runner.RunAsync(startInfo, ct);
    }

    public async Task ApplyUpdatePolicyAsync(string policyKey, CancellationToken ct = default)
    {
        var script = Path.Combine(_paths.EngineDir, "Apply-UpdatePolicy.ps1");
        var startInfo = _runner.CreateElevatedStartInfo(script, new Dictionary<string, string>
        {
            ["Policy"] = policyKey,
            ["Root"] = _paths.Root
        });
        await _runner.RunAsync(startInfo, ct);
    }

    public async Task RefreshInstalledAsync(CancellationToken ct = default)
    {
        var script = Path.Combine(_paths.EngineDir, "Detect-Installed.ps1");
        var cachePath = Path.Combine(_paths.StateDir, "installed.json");
        _paths.EnsureStateDirectories();
        var startInfo = _runner.CreateStartInfo(script, new Dictionary<string, string>
        {
            ["Root"] = _paths.Root,
            ["OutPath"] = cachePath
        });
        await _runner.RunAsync(startInfo, ct);
    }

    public async Task<Dictionary<string, bool>> GetInstalledAsync(CancellationToken ct = default)
    {
        var cachePath = Path.Combine(_paths.StateDir, "installed.json");
        var result = await JsonFileHelper.ReadAsync<Dictionary<string, bool>>(cachePath, ct);
        return result ?? new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
    }
}

public sealed record JobLaunchResult(string JobId, bool Started, bool NeedsElevation, string? Error);
