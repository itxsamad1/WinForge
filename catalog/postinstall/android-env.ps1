<#
    Points ANDROID_HOME / ANDROID_SDK_ROOT at the SDK and puts the command line
    tools on PATH so adb and sdkmanager work from any terminal.
#>
param($Context, $Options)

$sdkRoot = Join-Path $env:LOCALAPPDATA 'Android\Sdk'

if (-not (Test-Path -LiteralPath $sdkRoot)) {
    # Android Studio downloads the SDK on first launch, so this is expected on
    # a fresh install. Set the variables anyway: Studio reads ANDROID_HOME and
    # will populate exactly this directory.
    Write-Output "SDK directory does not exist yet: $sdkRoot"
    Write-Output 'Creating it and pointing the environment variables there.'
    New-Item -ItemType Directory -Path $sdkRoot -Force | Out-Null
}

# User scope: the SDK lives under the user profile, so a machine-wide value
# would be wrong for every other account on the box.
Set-PersistentEnvVar -Name 'ANDROID_HOME' -Value $sdkRoot -Scope 'User'
Set-PersistentEnvVar -Name 'ANDROID_SDK_ROOT' -Value $sdkRoot -Scope 'User'
Write-Output "Set ANDROID_HOME and ANDROID_SDK_ROOT to $sdkRoot"

$toolDirs = @(
    (Join-Path $sdkRoot 'platform-tools'),
    (Join-Path $sdkRoot 'cmdline-tools\latest\bin'),
    (Join-Path $sdkRoot 'emulator')
)

foreach ($dir in $toolDirs) {
    if (Add-ToSystemPath -Directory $dir -Scope 'User') {
        Write-Output "Added $dir to PATH"
    } else {
        Write-Output "Already on PATH: $dir"
    }
}

Write-Output ''
Write-Output 'Next: launch Android Studio once and complete the setup wizard so it'
Write-Output 'downloads the SDK, platform-tools and an emulator image into the path above.'
