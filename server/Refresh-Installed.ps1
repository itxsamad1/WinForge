<#
.SYNOPSIS
    Writes the set of installed winget package ids to a cache file.
.DESCRIPTION
    Runs detached from the server because "winget export" takes around 13
    seconds and would otherwise stall the first page load.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'server\Common.ps1')

$packageIds = @()
$succeeded = $false

$tempFile = Join-Path $env:TEMP ("winforge-export-" + [guid]::NewGuid().ToString('n') + '.json')

try {
    & winget export --output $tempFile --accept-source-agreements --disable-interactivity --nowarn 2>&1 | Out-Null

    if (Test-Path -LiteralPath $tempFile) {
        $document = Read-JsonFile -Path $tempFile
        foreach ($source in (ConvertTo-Array (Get-Prop $document 'Sources'))) {
            foreach ($package in (ConvertTo-Array (Get-Prop $source 'Packages'))) {
                $identifier = Get-Prop $package 'PackageIdentifier'
                if (-not [string]::IsNullOrWhiteSpace($identifier)) {
                    $packageIds += $identifier
                }
            }
        }
        $succeeded = $true
    }
} catch {
    $succeeded = $false
} finally {
    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
}

Write-JsonFile -Path $OutputPath -Value ([pscustomobject]@{
    generatedAt = (Get-Date).ToString('o')
    succeeded   = $succeeded
    packageIds  = @($packageIds | Sort-Object -Unique)
})
