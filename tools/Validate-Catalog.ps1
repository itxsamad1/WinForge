<#
.SYNOPSIS
    Validates catalog/apps.json and catalog/presets.json.
.DESCRIPTION
    Two passes. The offline pass checks structure: unique keys, known
    categories, resolvable "after" references, post-install scripts that exist
    on disk, and detect rules whose regexes actually compile. The online pass
    asks winget whether each package id resolves, which is the failure mode
    that would otherwise only show up mid-install on a user's machine.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Validate-Catalog.ps1 -SkipWinget
#>
[CmdletBinding()]
param(
    [switch]$SkipWinget,
    [int]$ThrottleLimit = 6
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'server\Common.ps1')

$catalogDir = Join-Path $root 'catalog'
$appsDoc = Read-JsonFile -Path (Join-Path $catalogDir 'apps.json')
$presetsDoc = Read-JsonFile -Path (Join-Path $catalogDir 'presets.json')

if ($null -eq $appsDoc) { throw 'apps.json could not be parsed.' }

$errors = New-Object System.Collections.ArrayList
$warnings = New-Object System.Collections.ArrayList
function Add-Problem { param($List, $Text) [void]$List.Add($Text) }

$apps = ConvertTo-Array (Get-Prop $appsDoc 'apps')
$categories = ConvertTo-Array (Get-Prop $appsDoc 'categories')
$categoryIds = @()
foreach ($category in $categories) { $categoryIds += (Get-Prop $category 'id') }

Write-Host ''
Write-Host "Structure: $($apps.Count) apps, $($categoryIds.Count) categories" -ForegroundColor Cyan

$seenKeys = @{}
$wingetTargets = New-Object System.Collections.ArrayList

foreach ($app in $apps) {
    $key = Get-Prop $app 'key'
    $name = Get-Prop $app 'name' $key

    if ([string]::IsNullOrWhiteSpace($key)) {
        Add-Problem $errors "An app entry is missing 'key' (name: $name)"
        continue
    }
    if ($seenKeys.ContainsKey($key)) {
        Add-Problem $errors "Duplicate key '$key'"
        continue
    }
    $seenKeys[$key] = $app

    if ([string]::IsNullOrWhiteSpace($name)) { Add-Problem $errors "[$key] missing 'name'" }
    if ([string]::IsNullOrWhiteSpace((Get-Prop $app 'description'))) { Add-Problem $warnings "[$key] missing 'description'" }

    $category = Get-Prop $app 'category'
    if ($categoryIds -notcontains $category) {
        Add-Problem $errors "[$key] unknown category '$category'"
    }

    $kind = Get-Prop $app 'kind' 'winget'
    switch ($kind) {
        'winget' {
            $id = Get-Prop $app 'id'
            if ([string]::IsNullOrWhiteSpace($id)) {
                Add-Problem $errors "[$key] kind 'winget' requires an 'id'"
            } else {
                [void]$wingetTargets.Add([pscustomobject]@{ Key = $key; Id = $id })
            }
        }
        'script' {
            $command = Get-Prop $app 'command'
            if ([string]::IsNullOrWhiteSpace($command)) {
                Add-Problem $errors "[$key] kind 'script' requires a 'command'"
            } else {
                $scriptPath = Join-Path $catalogDir "scripts\$command.ps1"
                if (-not (Test-Path -LiteralPath $scriptPath)) {
                    Add-Problem $errors "[$key] script not found: catalog\scripts\$command.ps1"
                }
            }
        }
        'manual' {
            if ([string]::IsNullOrWhiteSpace((Get-Prop $app 'instructions'))) {
                Add-Problem $errors "[$key] kind 'manual' requires 'instructions'"
            }
        }
        default { Add-Problem $errors "[$key] unknown kind '$kind'" }
    }

    foreach ($step in (ConvertTo-Array (Get-Prop $app 'postInstall'))) {
        $stepPath = Join-Path $catalogDir "postinstall\$step.ps1"
        if (-not (Test-Path -LiteralPath $stepPath)) {
            Add-Problem $errors "[$key] post-install script not found: catalog\postinstall\$step.ps1"
        }
    }

    $detect = Get-Prop $app 'detect'
    if ($null -eq $detect) {
        Add-Problem $warnings "[$key] no detect rule, will never show as already installed"
    } else {
        $registry = Get-Prop $detect 'registry'
        if (-not [string]::IsNullOrWhiteSpace($registry)) {
            try { [void][regex]::new($registry) }
            catch { Add-Problem $errors "[$key] detect.registry is not a valid regex: $registry" }
        }
        if ([string]::IsNullOrWhiteSpace($registry) -and
            [string]::IsNullOrWhiteSpace((Get-Prop $detect 'cmd')) -and
            [string]::IsNullOrWhiteSpace((Get-Prop $detect 'path'))) {
            Add-Problem $warnings "[$key] detect rule is empty"
        }
    }
}

foreach ($app in $apps) {
    $key = Get-Prop $app 'key'
    foreach ($dep in (ConvertTo-Array (Get-Prop $app 'after'))) {
        if (-not $seenKeys.ContainsKey($dep)) {
            Add-Problem $errors "[$key] 'after' references unknown app '$dep'"
        }
    }
}

foreach ($preset in (ConvertTo-Array (Get-Prop $presetsDoc 'presets'))) {
    $presetKey = Get-Prop $preset 'key'
    $presetApps = ConvertTo-Array (Get-Prop $preset 'apps')
    if ($presetApps.Count -eq 0) { Add-Problem $errors "Preset '$presetKey' has no apps" }
    foreach ($appKey in $presetApps) {
        if (-not $seenKeys.ContainsKey($appKey)) {
            Add-Problem $errors "Preset '$presetKey' references unknown app '$appKey'"
        }
    }
}

if (-not $SkipWinget) {
    Write-Host "Resolving $($wingetTargets.Count) package ids against winget..." -ForegroundColor Cyan

    $scriptBlock = {
        param($Id)
        $output = & winget show --id $Id -e --source winget --disable-interactivity --accept-source-agreements 2>&1
        [pscustomobject]@{
            Id       = $Id
            Found    = ($LASTEXITCODE -eq 0)
            Output   = ($output | Out-String)
        }
    }

    $queue = New-Object System.Collections.Queue
    foreach ($target in $wingetTargets) { $queue.Enqueue($target) }

    $running = @()
    $results = @{}
    $completed = 0

    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($queue.Count -gt 0 -and $running.Count -lt $ThrottleLimit) {
            $target = $queue.Dequeue()
            $job = Start-Job -ScriptBlock $scriptBlock -ArgumentList $target.Id
            $running += [pscustomobject]@{ Job = $job; Target = $target }
        }

        Start-Sleep -Milliseconds 250

        $stillRunning = @()
        foreach ($entry in $running) {
            if ($entry.Job.State -eq 'Running') {
                $stillRunning += $entry
                continue
            }
            $result = Receive-Job -Job $entry.Job
            Remove-Job -Job $entry.Job -Force
            $completed++
            $results[$entry.Target.Key] = $result
            if ($null -eq $result -or -not $result.Found) {
                Add-Problem $errors "[$($entry.Target.Key)] winget id does not resolve: $($entry.Target.Id)"
                Write-Host "  x  $($entry.Target.Key.PadRight(24)) $($entry.Target.Id)" -ForegroundColor Red
            } else {
                Write-Host "  ok $($entry.Target.Key.PadRight(24)) $($entry.Target.Id)" -ForegroundColor DarkGray
            }
        }
        $running = $stillRunning
    }

    Write-Host "Checked $completed package ids." -ForegroundColor Cyan
}

Write-Host ''
if ($warnings.Count -gt 0) {
    Write-Host "Warnings ($($warnings.Count)):" -ForegroundColor Yellow
    foreach ($warning in $warnings) { Write-Host "  - $warning" -ForegroundColor Yellow }
    Write-Host ''
}
if ($errors.Count -gt 0) {
    Write-Host "Errors ($($errors.Count)):" -ForegroundColor Red
    foreach ($problem in $errors) { Write-Host "  - $problem" -ForegroundColor Red }
    Write-Host ''
    exit 1
}

Write-Host 'Catalog is valid.' -ForegroundColor Green
exit 0
