<#
    API route handlers.

    Every handler must return quickly: the listener loop is synchronous, so a
    slow handler blocks the whole UI. Anything expensive is delegated to a
    detached process and observed through state files.
#>

function Get-QueryIntArray {
    <#
        Parses "0,3,7" into an int array, ignoring anything non-numeric rather
        than throwing on a malformed query string.
    #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    $result = @()
    foreach ($part in $Value.Split(',')) {
        $parsed = 0
        if ([int]::TryParse($part.Trim(), [ref]$parsed)) { $result += $parsed }
    }
    return $result
}

function Invoke-ApiRoute {
    param(
        [Parameter(Mandatory = $true)] [hashtable]$Context,
        [Parameter(Mandatory = $true)] $Request,
        [Parameter(Mandatory = $true)] $Response,
        [Parameter(Mandatory = $true)] [string]$Path
    )

    $method = $Request.HttpMethod
    $route = $Path.TrimEnd('/').ToLowerInvariant()

    switch -Regex ($route) {

        '^/api/catalog$' {
            if ($method -ne 'GET') { Write-JsonResponse -Response $Response -StatusCode 405 -Value @{ error = 'Use GET' }; return }
            Write-JsonResponse -Response $Response -Value ([pscustomobject]@{
                categories = @(Get-CatalogCategories)
                presets    = @(Get-CatalogPresets)
                apps       = @(Get-CatalogApps)
                elevated   = $Context.Elevated
                wingetFound = ($null -ne (Get-Command 'winget' -ErrorAction SilentlyContinue))
            })
            return
        }

        '^/api/installed$' {
            if ($method -ne 'GET') { Write-JsonResponse -Response $Response -StatusCode 405 -Value @{ error = 'Use GET' }; return }
            $refresh = ($Request.QueryString['refresh'] -eq '1')
            if ($refresh) {
                Start-InstalledCacheRefresh -Context $Context -Force | Out-Null
            } else {
                Start-InstalledCacheRefresh -Context $Context | Out-Null
            }
            Write-JsonResponse -Response $Response -Value (Get-InstalledState -Context $Context)
            return
        }

        '^/api/install$' {
            if ($method -ne 'POST') { Write-JsonResponse -Response $Response -StatusCode 405 -Value @{ error = 'Use POST' }; return }

            $body = Read-RequestBody -Request $Request
            if ($null -eq $body) {
                Write-JsonResponse -Response $Response -StatusCode 400 -Value @{ error = 'Expected a JSON body.' }
                return
            }

            $keys = @()
            foreach ($key in (ConvertTo-Array (Get-Prop $body 'apps'))) {
                if ($key -is [string]) { $keys += $key }
            }
            if ($keys.Count -eq 0) {
                Write-JsonResponse -Response $Response -StatusCode 400 -Value @{ error = 'Select at least one app.' }
                return
            }
            if ($keys.Count -gt 200) {
                Write-JsonResponse -Response $Response -StatusCode 400 -Value @{ error = 'Too many apps in one batch.' }
                return
            }

            # The allowlist gate. Resolve-InstallPlan only emits steps built
            # from catalog entries, so nothing the caller typed reaches a
            # command line.
            $plan = Resolve-InstallPlan -Keys $keys
            if ($plan.steps.Count -eq 0) {
                Write-JsonResponse -Response $Response -StatusCode 400 `
                    -Value @{ error = 'None of the requested apps are in the catalog.'; unknown = @($plan.unknown) }
                return
            }

            $options = Get-SanitizedOptions -Raw (Get-Prop $body 'options')
            $job = New-InstallJob -Context $Context -Plan $plan -Options $options

            if (-not $job.started) {
                Write-JsonResponse -Response $Response -StatusCode 403 -Value @{
                    error = 'Administrator approval was declined, so nothing was installed.'
                    detail = $job.error
                    jobId = $job.jobId
                }
                return
            }

            Write-JsonResponse -Response $Response -Value ([pscustomobject]@{
                jobId          = $job.jobId
                needsElevation = [bool]$job.needsElevation
                steps          = @($plan.steps | ForEach-Object { [pscustomobject]@{ key = $_.key; name = $_.name; kind = $_.kind } })
                unknown        = @($plan.unknown)
            })
            return
        }

        '^/api/job/[^/]+$' {
            if ($method -ne 'GET') { Write-JsonResponse -Response $Response -StatusCode 405 -Value @{ error = 'Use GET' }; return }
            $jobId = $route.Substring($route.LastIndexOf('/') + 1)
            $tail = Get-QueryIntArray -Value $Request.QueryString['tail']
            $since = Get-QueryIntArray -Value $Request.QueryString['since']

            $state = Get-JobState -Context $Context -JobId $jobId -TailSteps $tail -SinceOffsets $since
            if ($null -eq $state) {
                Write-JsonResponse -Response $Response -StatusCode 404 -Value @{ error = 'Unknown job.' }
                return
            }
            Write-JsonResponse -Response $Response -Value $state
            return
        }

        '^/api/open$' {
            # Opens a vendor download page for a "manual" catalog entry. The url
            # is read from the catalog, never from the request, so this cannot
            # be turned into an arbitrary shell execution.
            if ($method -ne 'POST') { Write-JsonResponse -Response $Response -StatusCode 405 -Value @{ error = 'Use POST' }; return }
            $body = Read-RequestBody -Request $Request
            $key = Get-Prop $body 'app'
            $app = Get-CatalogApp -Key ([string]$key)
            if ($null -eq $app) {
                Write-JsonResponse -Response $Response -StatusCode 404 -Value @{ error = 'Unknown app.' }
                return
            }
            $url = Get-Prop $app 'url'
            if ([string]::IsNullOrWhiteSpace($url) -or $url -notmatch '^https://') {
                Write-JsonResponse -Response $Response -StatusCode 400 -Value @{ error = 'That app has no download page.' }
                return
            }
            Start-Process $url | Out-Null
            Write-JsonResponse -Response $Response -Value @{ opened = $url }
            return
        }

        default {
            Write-JsonResponse -Response $Response -StatusCode 404 -Value @{ error = "No route for $Path" }
            return
        }
    }
}

function Get-SanitizedOptions {
    <#
        Post-install scripts receive user input (a Git identity, extension ids).
        Everything is length-capped and pattern-checked here so a script never
        has to trust what it is handed.
    #>
    param($Raw)

    $gitName = [string](Get-Prop $Raw 'gitName' '')
    $gitEmail = [string](Get-Prop $Raw 'gitEmail' '')

    if ($gitName.Length -gt 100) { $gitName = $gitName.Substring(0, 100) }
    if ($gitEmail.Length -gt 200) { $gitEmail = $gitEmail.Substring(0, 200) }
    if ($gitEmail -ne '' -and $gitEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { $gitEmail = '' }
    # Strip characters that have meaning to a shell even though these values are
    # passed as argv rather than through a command string.
    $gitName = ($gitName -replace '[`"$;&|<>\r\n]', '').Trim()

    $vscodeExtensions = @()
    foreach ($extension in (ConvertTo-Array (Get-Prop $Raw 'vscodeExtensions'))) {
        if ($extension -is [string] -and $extension -match '^[A-Za-z0-9][A-Za-z0-9\-]*\.[A-Za-z0-9][A-Za-z0-9\-\.]*$') {
            $vscodeExtensions += $extension
        }
    }

    $cursorExtensions = @()
    foreach ($extension in (ConvertTo-Array (Get-Prop $Raw 'cursorExtensions'))) {
        if ($extension -is [string] -and $extension -match '^[A-Za-z0-9][A-Za-z0-9\-]*\.[A-Za-z0-9][A-Za-z0-9\-\.]*$') {
            $cursorExtensions += $extension
        }
    }

    return [pscustomobject]@{
        gitName          = $gitName
        gitEmail         = $gitEmail
        vscodeExtensions = @($vscodeExtensions | Select-Object -First 50)
        cursorExtensions = @($cursorExtensions | Select-Object -First 50)
    }
}
