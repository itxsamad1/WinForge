<#
    Installs a starter set of VS Code extensions. The user can override the
    list from the UI; otherwise nothing is installed, because opinionated
    extensions are a matter of taste.
#>
param($Context, $Options)

Update-PathFromRegistry

$extensions = ConvertTo-Array (Get-Prop $Options 'vscodeExtensions')
if ($extensions.Count -eq 0) {
    Write-Output 'No extensions requested.'
    return
}

$code = Get-Command 'code' -ErrorAction SilentlyContinue
if ($null -eq $code) {
    $fallback = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'
    if (-not (Test-Path -LiteralPath $fallback)) {
        $fallback = Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd'
    }
    if (-not (Test-Path -LiteralPath $fallback)) {
        throw 'The "code" command was not found. Open VS Code once, then re-run this step.'
    }
    $codePath = $fallback
} else {
    $codePath = $code.Source
}

foreach ($extension in $extensions) {
    # Extension ids are publisher.name; reject anything else rather than pass
    # an arbitrary string to a command line.
    if ($extension -notmatch '^[A-Za-z0-9][A-Za-z0-9\-]*\.[A-Za-z0-9][A-Za-z0-9\-\.]*$') {
        Write-Output "Skipping invalid extension id: $extension"
        continue
    }
    Write-Output "Installing $extension"
    & $codePath --install-extension $extension --force 2>&1 | ForEach-Object { Write-Output $_ }
}

Write-Output 'Extension install finished.'
