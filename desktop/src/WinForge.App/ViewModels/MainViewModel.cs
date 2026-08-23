using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using WinForge.Core;
using WinForge.Core.Models;
using WinForge.Core.Services;

namespace WinForge.App.ViewModels;

public sealed class AppItemViewModel : ViewModelBase
{
    private bool _isSelected;
    private bool _isInstalled;

    public AppItemViewModel(CatalogApp app)
    {
        Key = app.Key;
        Name = app.Name;
        Description = app.Description ?? "";
        Category = app.Category;
        Popular = app.Popular;
    }

    public string Key { get; }
    public string Name { get; }
    public string Description { get; }
    public string Category { get; }
    public bool Popular { get; }

    public bool IsSelected
    {
        get => _isSelected;
        set => SetProperty(ref _isSelected, value);
    }

    public bool IsInstalled
    {
        get => _isInstalled;
        set => SetProperty(ref _isInstalled, value);
    }
}

public sealed class MainViewModel : ViewModelBase
{
    private readonly AppPaths _paths;
    private readonly CatalogService _catalog;
    private readonly JobService _jobs;
    private readonly ProfileService _profiles;
    private readonly DispatcherTimer _pollTimer;

    private string _searchText = "";
    private string _statusText = "Ready";
    private string _progressText = "";
    private double _progressValue;
    private bool _isBusy;
    private string? _activeJobId;
    private string _gitName = "";
    private string _gitEmail = "";
    private int _selectedTabIndex;

    public MainViewModel()
    {
        _paths = new AppPaths();
        _catalog = new CatalogService(_paths);
        _jobs = new JobService(_paths, new PowerShellRunner(_paths));
        _profiles = new ProfileService(_paths);

        Presets = new ObservableCollection<Preset>();
        Categories = new ObservableCollection<Category>();
        Apps = new ObservableCollection<AppItemViewModel>();
        Tweaks = new ObservableCollection<TweakEntry>();
        Fixes = new ObservableCollection<FixEntry>();
        UpdatePolicies = new ObservableCollection<UpdatePolicyEntry>();
        LogLines = new ObservableCollection<string>();

        InstallCommand = new RelayCommand(_ => _ = InstallSelectedAsync(), _ => !IsBusy && SelectedApps.Count > 0);
        RescanCommand = new RelayCommand(_ => _ = RescanAsync(), _ => !IsBusy);
        ApplyTweaksCommand = new RelayCommand(_ => _ = ApplyTweaksAsync(), _ => !IsBusy && SelectedTweaks.Count > 0);
        SaveProfileCommand = new RelayCommand(_ => _ = SaveProfileAsync(), _ => !IsBusy);
        LoadProfileCommand = new RelayCommand(_ => _ = LoadProfileAsync(), _ => !IsBusy);

        _pollTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _pollTimer.Tick += async (_, _) => await PollJobAsync();

        LoadCatalog();
        _ = RescanAsync();
    }

    public ObservableCollection<Preset> Presets { get; }
    public ObservableCollection<Category> Categories { get; }
    public ObservableCollection<AppItemViewModel> Apps { get; }
    public ObservableCollection<AppItemViewModel> FilteredApps { get; } = new();
    public ObservableCollection<TweakEntry> Tweaks { get; }
    public ObservableCollection<FixEntry> Fixes { get; }
    public ObservableCollection<UpdatePolicyEntry> UpdatePolicies { get; }
    public ObservableCollection<string> LogLines { get; }

    public ICommand InstallCommand { get; }
    public ICommand RescanCommand { get; }
    public ICommand ApplyTweaksCommand { get; }
    public ICommand SaveProfileCommand { get; }
    public ICommand LoadProfileCommand { get; }

    public string SearchText
    {
        get => _searchText;
        set { SetProperty(ref _searchText, value); RefreshFilter(); }
    }

    public string StatusText
    {
        get => _statusText;
        set => SetProperty(ref _statusText, value);
    }

    public string ProgressText
    {
        get => _progressText;
        set => SetProperty(ref _progressText, value);
    }

    public double ProgressValue
    {
        get => _progressValue;
        set => SetProperty(ref _progressValue, value);
    }

    public bool IsBusy
    {
        get => _isBusy;
        set
        {
            SetProperty(ref _isBusy, value);
            (InstallCommand as RelayCommand)?.RaiseCanExecuteChanged();
            (RescanCommand as RelayCommand)?.RaiseCanExecuteChanged();
            (ApplyTweaksCommand as RelayCommand)?.RaiseCanExecuteChanged();
        }
    }

    public int SelectedTabIndex
    {
        get => _selectedTabIndex;
        set => SetProperty(ref _selectedTabIndex, value);
    }

    public string GitName
    {
        get => _gitName;
        set => SetProperty(ref _gitName, value);
    }

    public string GitEmail
    {
        get => _gitEmail;
        set => SetProperty(ref _gitEmail, value);
    }

    public IEnumerable<AppItemViewModel> FilteredAppsLegacy =>
        string.IsNullOrWhiteSpace(SearchText)
            ? Apps
            : Apps.Where(a =>
                a.Name.Contains(SearchText, StringComparison.OrdinalIgnoreCase) ||
                a.Key.Contains(SearchText, StringComparison.OrdinalIgnoreCase) ||
                a.Description.Contains(SearchText, StringComparison.OrdinalIgnoreCase));

    private void RefreshFilter()
    {
        FilteredApps.Clear();
        foreach (var app in FilteredAppsLegacy)
            FilteredApps.Add(app);
    }

    public List<AppItemViewModel> SelectedApps => Apps.Where(a => a.IsSelected).ToList();
    public List<TweakEntry> SelectedTweaks => Tweaks.Where(t => t.IsSelected).ToList();

    public void ApplyPreset(Preset preset)
    {
        foreach (var app in Apps)
            app.IsSelected = preset.Apps.Contains(app.Key, StringComparer.OrdinalIgnoreCase);
        StatusText = $"Preset applied: {preset.Name} ({preset.Apps.Count} apps)";
    }

    public async Task RunFixAsync(FixEntry fix)
    {
        try
        {
            IsBusy = true;
            StatusText = $"Running: {fix.Name}";
            await _jobs.RunFixAsync(fix.Key);
            StatusText = $"Done: {fix.Name}";
        }
        catch (Exception ex)
        {
            StatusText = ex.Message;
            System.Windows.MessageBox.Show(ex.Message, "WinForge", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            IsBusy = false;
        }
    }

    public async Task ApplyUpdatePolicyAsync(UpdatePolicyEntry policy)
    {
        if (!string.IsNullOrWhiteSpace(policy.Warning))
        {
            var confirm = System.Windows.MessageBox.Show(policy.Warning + "\n\nContinue?", policy.Name,
                MessageBoxButton.YesNo, MessageBoxImage.Warning);
            if (confirm != MessageBoxResult.Yes)
                return;
        }

        try
        {
            IsBusy = true;
            StatusText = $"Applying update policy: {policy.Name}";
            await _jobs.ApplyUpdatePolicyAsync(policy.Key);
            StatusText = $"Update policy applied: {policy.Name}";
        }
        catch (Exception ex)
        {
            StatusText = ex.Message;
            System.Windows.MessageBox.Show(ex.Message, "WinForge", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            IsBusy = false;
        }
    }

    private void LoadCatalog()
    {
        var snap = _catalog.Load();
        Presets.Clear();
        foreach (var p in snap.Presets) Presets.Add(p);

        Categories.Clear();
        foreach (var c in snap.Categories) Categories.Add(c);

        Apps.Clear();
        foreach (var app in snap.Apps) Apps.Add(new AppItemViewModel(app));
        RefreshFilter();

        Tweaks.Clear();
        foreach (var t in snap.Tweaks)
        {
            t.IsSelected = false;
            Tweaks.Add(t);
        }

        Fixes.Clear();
        foreach (var f in snap.Fixes) Fixes.Add(f);

        UpdatePolicies.Clear();
        foreach (var u in snap.UpdatePolicies) UpdatePolicies.Add(u);

        StatusText = $"{snap.Apps.Count} apps loaded";
    }

    private async Task RescanAsync()
    {
        try
        {
            IsBusy = true;
            StatusText = "Scanning installed apps...";
            await _jobs.RefreshInstalledAsync();
            var installed = await _jobs.GetInstalledAsync();
            foreach (var app in Apps)
                app.IsInstalled = installed.TryGetValue(app.Key, out var yes) && yes;
            StatusText = "Scan complete";
        }
        catch (Exception ex)
        {
            StatusText = ex.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task InstallSelectedAsync()
    {
        var snap = _catalog.Load();
        var keys = SelectedApps.Select(a => a.Key);
        var plan = InstallPlanResolver.Resolve(snap.AppsByKey, keys);

        if (plan.Steps.Count == 0)
        {
            System.Windows.MessageBox.Show("No valid apps selected.", "WinForge", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        var options = OptionsSanitizer.Sanitize(new InstallOptions
        {
            GitName = GitName,
            GitEmail = GitEmail
        });

        try
        {
            IsBusy = true;
            LogLines.Clear();
            StatusText = "Starting install...";
            ProgressValue = 0;

            var result = await _jobs.StartInstallJobAsync(plan, options);
            if (!result.Started)
            {
                StatusText = result.Error ?? "Install could not start";
                System.Windows.MessageBox.Show(StatusText, "WinForge", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            _activeJobId = result.JobId;
            if (result.NeedsElevation)
                StatusText = "Waiting for UAC — check the taskbar";

            _pollTimer.Start();
        }
        catch (Exception ex)
        {
            StatusText = ex.Message;
            IsBusy = false;
        }
    }

    private async Task PollJobAsync()
    {
        if (_activeJobId is null)
            return;

        var status = await _jobs.GetJobStatusAsync(_activeJobId);
        if (status is null)
            return;

        if (status.State == "awaiting_elevation")
            StatusText = "Waiting for UAC — accept the security prompt";

        var running = status.Steps.FirstOrDefault(s => s.State == "running");
        if (running is not null)
        {
            ProgressText = $"{running.Name} — {running.Phase ?? running.State} ({running.Percent ?? 0}%)";
            ProgressValue = running.Percent ?? ProgressValue;
            var lines = await _jobs.ReadLogTailAsync(_activeJobId, running.Index, LogLines.Count);
            foreach (var line in lines) LogLines.Add(line);
        }

        if (status.State is "finished" or "failed")
        {
            _pollTimer.Stop();
            _activeJobId = null;
            IsBusy = false;
            ProgressValue = status.State == "finished" ? 100 : ProgressValue;
            StatusText = status.State == "finished"
                ? "Install complete — open a new terminal for PATH changes"
                : "Install finished with errors";

            if (status.RebootNeeded)
                System.Windows.MessageBox.Show("Some packages need a reboot to finish.", "WinForge",
                    MessageBoxButton.OK, MessageBoxImage.Information);

            if (status.State == "finished")
                System.Windows.MessageBox.Show("Install complete. Open a new terminal for PATH changes.", "WinForge",
                    MessageBoxButton.OK, MessageBoxImage.Information);

            await RescanAsync();
        }
    }

    private async Task ApplyTweaksAsync()
    {
        var keys = SelectedTweaks.Select(t => t.Key).ToList();
        if (keys.Count == 0) return;

        var advanced = SelectedTweaks.Any(t => t.Risk == "advanced");
        if (advanced)
        {
            var confirm = System.Windows.MessageBox.Show(
                "You selected advanced tweaks. Continue?",
                "WinForge", MessageBoxButton.YesNo, MessageBoxImage.Warning);
            if (confirm != MessageBoxResult.Yes) return;
        }

        try
        {
            IsBusy = true;
            StatusText = "Applying tweaks...";
            await _jobs.RunTweaksAsync(keys);
            StatusText = "Tweaks applied";
        }
        catch (Exception ex)
        {
            StatusText = ex.Message;
            System.Windows.MessageBox.Show(ex.Message, "WinForge", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task SaveProfileAsync()
    {
        var dlg = new Microsoft.Win32.SaveFileDialog
        {
            Filter = "WinForge profile (*.json)|*.json",
            FileName = "my-setup.json"
        };
        if (dlg.ShowDialog() != true) return;

        var profile = new UserProfile
        {
            Name = System.IO.Path.GetFileNameWithoutExtension(dlg.FileName),
            Apps = SelectedApps.Select(a => a.Key).ToList(),
            Tweaks = SelectedTweaks.Select(t => t.Key).ToList(),
            Options = OptionsSanitizer.Sanitize(new InstallOptions { GitName = GitName, GitEmail = GitEmail })
        };

        await _profiles.SaveAsync(profile, dlg.FileName);
        StatusText = "Profile saved";
    }

    private async Task LoadProfileAsync()
    {
        var dlg = new Microsoft.Win32.OpenFileDialog { Filter = "WinForge profile (*.json)|*.json" };
        if (dlg.ShowDialog() != true) return;

        var profile = await _profiles.LoadAsync(dlg.FileName);
        if (profile is null) return;

        foreach (var app in Apps)
            app.IsSelected = profile.Apps.Contains(app.Key, StringComparer.OrdinalIgnoreCase);

        foreach (var tweak in Tweaks)
            tweak.IsSelected = profile.Tweaks.Contains(tweak.Key, StringComparer.OrdinalIgnoreCase);

        GitName = profile.Options.GitName;
        GitEmail = profile.Options.GitEmail;
        StatusText = $"Profile loaded: {profile.Name}";
    }
}
