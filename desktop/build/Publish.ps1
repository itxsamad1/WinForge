param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [switch]$SingleFile
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$sln = Join-Path (Split-Path -Parent $root) 'WinForge.Desktop.sln'
$app = Join-Path $root '..\src\WinForge.App\WinForge.App.csproj'

Push-Location (Split-Path -Parent $sln)
try {
    dotnet restore $sln
    dotnet test (Join-Path $root '..\tests\WinForge.Core.Tests\WinForge.Core.Tests.csproj') -c $Configuration --no-restore

    $publishArgs = @(
        'publish', $app,
        '-c', $Configuration,
        '-r', 'win-x64',
        '--self-contained', 'true',
        '-p:PublishReadyToRun=true',
        '-o', (Join-Path $root '..\dist')
    )

    if ($SingleFile) {
        $publishArgs += @('-p:PublishSingleFile=true', '-p:IncludeNativeLibrariesForSelfExtract=true')
    }

    dotnet publish @publishArgs

    Write-Host ""
    Write-Host "Published to desktop\dist\" -ForegroundColor Green
    Write-Host "Run WinForge.exe on Windows." -ForegroundColor Green
}
finally {
    Pop-Location
}
