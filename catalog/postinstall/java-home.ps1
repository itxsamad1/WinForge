<#
    Sets JAVA_HOME and puts the JDK's bin directory on PATH.

    Contract for every post-install script:
      - Receives $Context (Root, StateDir, Elevated) and $Options (user input).
      - Writes progress with Write-Output.
      - Throws only on genuine failure; the job continues with the next app.
      - Must be idempotent, since a user may re-run the same selection.
#>
param($Context, $Options)

$searchRoots = @(
    (Join-Path $env:ProgramFiles 'Eclipse Adoptium'),
    (Join-Path $env:ProgramFiles 'Java'),
    (Join-Path $env:ProgramFiles 'Microsoft'),
    (Join-Path ${env:ProgramFiles(x86)} 'Eclipse Adoptium')
)

$candidates = @()
foreach ($root in $searchRoots) {
    if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) { continue }
    $found = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'bin\javac.exe') }
    $candidates += $found
}

if ($candidates.Count -eq 0) {
    throw 'No JDK found. Expected javac.exe under Program Files\Eclipse Adoptium or Program Files\Java.'
}

# Prefer the highest version so a machine with both 17 and 21 points at 21.
$jdk = $candidates | Sort-Object -Property Name -Descending | Select-Object -First 1
$javaHome = $jdk.FullName

Write-Output "Found JDK at $javaHome"
Set-PersistentEnvVar -Name 'JAVA_HOME' -Value $javaHome -Scope 'Machine'
Write-Output 'Set JAVA_HOME (machine scope)'

$binDir = Join-Path $javaHome 'bin'
if (Add-ToSystemPath -Directory $binDir -Scope 'Machine') {
    Write-Output "Added $binDir to PATH"
} else {
    Write-Output 'JDK bin directory was already on PATH'
}
