<#
    Same as vscode-extensions but targets the Cursor CLI.
#>
param($Context, $Options)

Update-PathFromRegistry

$extensions = ConvertTo-Array (Get-Prop $Options 'cursorExtensions')
if ($extensions.Count -eq 0) {
    Write-Output 'No extensions requested.'
    return
}

$cursor = Get-Command 'cursor' -ErrorAction SilentlyContinue
if ($null -eq $cursor) {
    $fallback = Join-Path $env:LOCALAPPDATA 'Programs\cursor\resources\app\bin\cursor.cmd'
    if (-not (Test-Path -LiteralPath $fallback)) {
        throw 'The "cursor" command was not found. Open Cursor once, then re-run this step.'
    }
    $cursorPath = $fallback
} else {
    $cursorPath = $cursor.Source
}

foreach ($extension in $extensions) {
    if ($extension -notmatch '^[A-Za-z0-9][A-Za-z0-9\-]*\.[A-Za-z0-9][A-Za-z0-9\-\.]*$') {
        Write-Output "Skipping invalid extension id: $extension"
        continue
    }
    Write-Output "Installing $extension"
    & $cursorPath --install-extension $extension --force 2>&1 | ForEach-Object { Write-Output $_ }
}

Write-Output 'Extension install finished.'
