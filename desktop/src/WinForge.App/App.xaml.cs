using System.Drawing;
using System.Windows;
using System.Windows.Forms;

namespace WinForge.App;

public partial class App : System.Windows.Application
{
    private NotifyIcon? _tray;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        if (e.Args.Length > 0 && e.Args.Any(a => a.StartsWith("--", StringComparison.Ordinal)))
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            _ = RunCliAsync(e.Args);
            return;
        }

        _tray = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Visible = true,
            Text = "WinForge"
        };
        _tray.DoubleClick += (_, _) =>
        {
            if (Current.MainWindow is { } w)
            {
                w.Show();
                w.WindowState = WindowState.Normal;
                w.Activate();
            }
        };
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (_tray is not null)
        {
            _tray.Visible = false;
            _tray.Dispose();
        }
        base.OnExit(e);
    }

    private static async Task RunCliAsync(string[] args)
    {
        try
        {
            var paths = new WinForge.Core.AppPaths();
            var catalog = new WinForge.Core.Services.CatalogService(paths);
            var runner = new WinForge.Core.Services.PowerShellRunner(paths);
            var jobs = new WinForge.Core.Services.JobService(paths, runner);
            var cli = new WinForge.Core.Services.CliRunner(catalog, jobs);
            var code = await cli.RunAsync(args);
            Current.Shutdown(code >= 0 ? code : 1);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            Current.Shutdown(1);
        }
    }
}
