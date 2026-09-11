param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [switch]$SingleFile
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$desktop = Split-Path -Parent $root
$sln = Join-Path $desktop 'WinForge.Desktop.sln'
$app = [System.IO.Path]::GetFullPath((Join-Path $desktop 'src\WinForge.App\WinForge.App.csproj'))
$outDir = [System.IO.Path]::GetFullPath((Join-Path $desktop 'dist'))

Push-Location $desktop
try {
    # Old WinForge.exe locks dist\ during publish if still running.
    $running = Get-Process -Name 'WinForge' -ErrorAction SilentlyContinue
    if ($running) {
        Write-Host "Stopping running WinForge process(es) so publish can overwrite dist\..." -ForegroundColor Yellow
        $running | Stop-Process -Force
        Start-Sleep -Milliseconds 500
    }

    dotnet restore $sln
    if ($LASTEXITCODE -ne 0) { throw "dotnet restore failed ($LASTEXITCODE)" }

    dotnet test (Join-Path $desktop 'tests\WinForge.Core.Tests\WinForge.Core.Tests.csproj') -c $Configuration --no-restore
    if ($LASTEXITCODE -ne 0) { throw "dotnet test failed ($LASTEXITCODE)" }

    # NOTE: do NOT put 'publish' in the arg array — we already call `dotnet publish`.
    $publishArgs = @(
        $app,
        '-c', $Configuration,
        '-r', 'win-x64',
        '--self-contained', 'true',
        '-p:PublishReadyToRun=true',
        '-o', $outDir
    )

    if ($SingleFile) {
        $publishArgs += @(
            '-p:PublishSingleFile=true',
            '-p:IncludeNativeLibrariesForSelfExtract=true'
        )
    }

    Write-Host "dotnet publish $($publishArgs -join ' ')" -ForegroundColor DarkGray
    & dotnet publish @publishArgs
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed ($LASTEXITCODE)" }

    $exe = Join-Path $outDir 'WinForge.exe'
    if (-not (Test-Path $exe)) {
        throw "Publish succeeded but WinForge.exe was not found at $exe"
    }

    Write-Host ""
    Write-Host "Published: $exe" -ForegroundColor Green
}
finally {
    Pop-Location
}
