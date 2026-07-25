<#
    Catalog loading, validation and install ordering.

    The catalog doubles as the security allowlist: the install endpoint accepts
    catalog keys only and resolves them here, so no caller-supplied string ever
    reaches a command line.
#>

$script:CatalogApps = @{}
$script:CatalogOrder = @()
$script:CatalogPresets = @()
$script:CatalogCategories = @()

function Initialize-Catalog {
    param([Parameter(Mandatory = $true)] [hashtable]$Context)

    $appsPath = Join-Path $Context.CatalogDir 'apps.json'
    $presetsPath = Join-Path $Context.CatalogDir 'presets.json'

    $appsDoc = Read-JsonFile -Path $appsPath
    if ($null -eq $appsDoc) { throw "Could not read catalog at $appsPath" }

    $script:CatalogApps = @{}
    $script:CatalogOrder = @()

    foreach ($app in (ConvertTo-Array (Get-Prop $appsDoc 'apps'))) {
        $key = Get-Prop $app 'key'
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if ($script:CatalogApps.ContainsKey($key)) {
            Write-Host "  [catalog] duplicate key '$key' ignored" -ForegroundColor Yellow
            continue
        }
        $script:CatalogApps[$key] = $app
        $script:CatalogOrder += $key
    }

    $script:CatalogCategories = ConvertTo-Array (Get-Prop $appsDoc 'categories')

    $presetsDoc = Read-JsonFile -Path $presetsPath
    $script:CatalogPresets = ConvertTo-Array (Get-Prop $presetsDoc 'presets')

    # A preset pointing at a removed app would silently install less than the
    # user expects, so surface it at startup instead.
    foreach ($preset in $script:CatalogPresets) {
        foreach ($key in (ConvertTo-Array (Get-Prop $preset 'apps'))) {
            if (-not $script:CatalogApps.ContainsKey($key)) {
                Write-Host "  [catalog] preset '$(Get-Prop $preset 'name')' references unknown app '$key'" -ForegroundColor Yellow
            }
        }
    }

    Write-Host "  Catalog: $($script:CatalogOrder.Count) apps, $($script:CatalogPresets.Count) presets" -ForegroundColor DarkGray
}

function Get-CatalogApps {
    $result = @()
    foreach ($key in $script:CatalogOrder) {
        $result += $script:CatalogApps[$key]
    }
    return $result
}

function Get-CatalogApp {
    param([Parameter(Mandatory = $true)] [string]$Key)
    if ($script:CatalogApps.ContainsKey($Key)) { return $script:CatalogApps[$Key] }
    return $null
}

function Get-CatalogCategories { return $script:CatalogCategories }
function Get-CatalogPresets { return $script:CatalogPresets }

function Add-OrderedApp {
    param(
        [Parameter(Mandatory = $true)] [string]$Key,
        [Parameter(Mandatory = $true)] [string[]]$Requested,
        [Parameter(Mandatory = $true)] [hashtable]$State,
        [Parameter(Mandatory = $true)] $Ordered
    )
    if ($State[$Key] -eq 'done') { return }
    if ($State[$Key] -eq 'visiting') { return }  # cycle; keep the original order
    $State[$Key] = 'visiting'
    $app = $script:CatalogApps[$Key]
    foreach ($dep in (ConvertTo-Array (Get-Prop $app 'after'))) {
        if ($Requested -contains $dep) {
            Add-OrderedApp -Key $dep -Requested $Requested -State $State -Ordered $Ordered
        }
    }
    $State[$Key] = 'done'
    [void]$Ordered.Add($Key)
}

function Resolve-InstallPlan {
    <#
        Turns a list of requested catalog keys into an ordered install plan.

        Two jobs: reject anything not in the catalog (the allowlist gate), and
        honour each app's "after" list so nvm lands before Node and the JDK
        before the Android env scripts.
    #>
    param([Parameter(Mandatory = $true)] [string[]]$Keys)

    $requested = @()
    $unknown = @()
    foreach ($key in $Keys) {
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if ($requested -contains $key) { continue }
        if ($script:CatalogApps.ContainsKey($key)) {
            $requested += $key
        } else {
            $unknown += $key
        }
    }

    # Depth-first walk over "after" edges, restricted to keys actually
    # requested. Missing dependencies are not auto-added: the user picked a
    # specific set and we install exactly that set, just in a safe order.
    $ordered = New-Object System.Collections.ArrayList
    $state = @{}
    foreach ($key in $requested) {
        Add-OrderedApp -Key $key -Requested $requested -State $state -Ordered $ordered
    }

    $steps = @()
    foreach ($key in $ordered) {
        $app = $script:CatalogApps[$key]
        $kind = Get-Prop $app 'kind' 'winget'
        $steps += [pscustomobject]@{
            key         = $key
            name        = Get-Prop $app 'name' $key
            kind        = $kind
            id          = Get-Prop $app 'id'
            scope       = Get-Prop $app 'scope'
            source      = Get-Prop $app 'source' 'winget'
            override    = Get-Prop $app 'override'
            command     = Get-Prop $app 'command'
            url         = Get-Prop $app 'url'
            instructions = Get-Prop $app 'instructions'
            postInstall = @(ConvertTo-Array (Get-Prop $app 'postInstall'))
            reboot      = [bool](Get-Prop $app 'requiresRestart' $false)
        }
    }

    return [pscustomobject]@{
        steps   = $steps
        unknown = $unknown
    }
}
