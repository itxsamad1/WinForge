<#
    Enables Microsoft Hyper-V (Windows Pro / Enterprise / Education).

    Home editions do not include Hyper-V. Enabling the feature usually needs a
    reboot before the hypervisor is active.
#>
param($Context, $Options)

$edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).EditionID
Write-Output "Windows edition: $edition"

$feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
if ($null -eq $feature) {
    throw 'Hyper-V feature not found. This edition of Windows likely does not include Hyper-V (Home is unsupported).'
}

if ($feature.State -eq 'Enabled') {
    Write-Output 'Hyper-V is already enabled.'
    return
}

Write-Output 'Enabling Microsoft-Hyper-V-All (may take a few minutes)...'
$result = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart
Write-Output "Feature state after enable: $($result.State)"
if ($result.RestartNeeded) {
    Write-Output 'A reboot is required before Hyper-V is usable.'
} else {
    Write-Output 'Hyper-V enabled. Open Hyper-V Manager from the Start menu after refresh.'
}
