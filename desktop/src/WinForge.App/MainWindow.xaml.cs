using System.Globalization;
using System.Windows;
using System.Windows.Data;
using WinForge.App.ViewModels;
using WinForge.Core.Models;

namespace WinForge.App;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        Resources.Add("InstalledConverter", new InstalledConverter());
        InitializeComponent();
        DataContext = new MainViewModel();
    }

    private MainViewModel Vm => (MainViewModel)DataContext;

    private void Preset_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: Preset preset })
            Vm.ApplyPreset(preset);
    }

    private async void Fix_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: FixEntry fix })
            await Vm.RunFixAsync(fix);
    }

    private async void Policy_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: UpdatePolicyEntry policy })
            await Vm.ApplyUpdatePolicyAsync(policy);
    }
}

public sealed class InstalledConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is true ? "Installed" : "";

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}
