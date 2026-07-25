<#
    HttpListener loop, router and static file server.

    The loop is synchronous, so every handler must return in milliseconds.
    Anything slow (installing packages, "winget export") is pushed to a
    separate process and surfaced through polled state files.
#>

$script:MimeTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.svg'  = 'image/svg+xml'
    '.png'  = 'image/png'
    '.ico'  = 'image/x-icon'
    '.woff2' = 'font/woff2'
}

function Write-HttpResponse {
    param(
        [Parameter(Mandatory = $true)] $Response,
        [int]$StatusCode = 200,
        [string]$ContentType = 'text/plain; charset=utf-8',
        # Untyped on purpose: PowerShell 5.1 silently drops large [byte[]]
        # arguments during parameter binding, which produced empty 200 responses
        # for every static file and a blank white page in the browser.
        $Bytes = $null,
        [string]$Body = $null
    )
    try {
        if ($PSBoundParameters.ContainsKey('Body')) {
            $payload = [System.Text.Encoding]::UTF8.GetBytes([string]$Body)
        } elseif ($null -ne $Bytes) {
            if ($Bytes -is [byte[]]) {
                $payload = $Bytes
            } else {
                $payload = [byte[]]@($Bytes)
            }
        } else {
            $payload = New-Object 'byte[]' 0
        }

        $Response.StatusCode = $StatusCode
        $Response.ContentType = $ContentType
        $Response.ContentLength64 = $payload.Length
        $Response.Headers['Cache-Control'] = 'no-store'
        $Response.Headers['X-Content-Type-Options'] = 'nosniff'
        if ($payload.Length -gt 0) {
            $Response.OutputStream.Write($payload, 0, $payload.Length)
        }
    } catch {
        # Client disconnected mid-write (browser navigated away). Nothing to do.
    } finally {
        try { $Response.OutputStream.Close() } catch { }
        try { $Response.Close() } catch { }
    }
}

function Write-JsonResponse {
    param(
        [Parameter(Mandatory = $true)] $Response,
        [Parameter(Mandatory = $true)] $Value,
        [int]$StatusCode = 200,
        [int]$Depth = 12
    )
    $json = $Value | ConvertTo-Json -Depth $Depth -Compress
    if ($null -eq $json) { $json = 'null' }
    Write-HttpResponse -Response $Response -StatusCode $StatusCode `
        -ContentType 'application/json; charset=utf-8' -Body $json
}

function Test-RequestAllowed {
    <#
        This API can trigger an elevated installer, so it is a privilege
        boundary. Three gates: loopback only, no cross-origin caller, and a
        session token that only the process that launched the browser knows.
    #>
    param(
        [Parameter(Mandatory = $true)] $Request,
        [Parameter(Mandatory = $true)] [string]$Token
    )

    if (-not $Request.IsLocal) { return $false }
    if (-not $Request.RemoteEndPoint.Address.ToString().StartsWith('127.')) {
        if ($Request.RemoteEndPoint.Address.ToString() -ne '::1') { return $false }
    }

    # Reject browser-initiated cross-origin calls; a page on another site must
    # not be able to drive the installer.
    $origin = $Request.Headers['Origin']
    if (-not [string]::IsNullOrWhiteSpace($origin)) {
        $expected = "http://localhost:$($script:Ctx.Port)"
        $expectedAlt = "http://127.0.0.1:$($script:Ctx.Port)"
        if ($origin -ne $expected -and $origin -ne $expectedAlt) { return $false }
    }

    $supplied = $Request.Headers['X-WinForge-Token']
    if ([string]::IsNullOrWhiteSpace($supplied)) {
        $supplied = $Request.QueryString['token']
    }
    if ([string]::IsNullOrWhiteSpace($supplied)) { return $false }

    return [System.StringComparer]::Ordinal.Equals($supplied, $Token)
}

function Send-StaticFile {
    param(
        [Parameter(Mandatory = $true)] $Response,
        [Parameter(Mandatory = $true)] [string]$WebRoot,
        [Parameter(Mandatory = $true)] [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath -eq '/') {
        $RelativePath = 'index.html'
    }
    $RelativePath = $RelativePath.TrimStart('/', '\')

    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $WebRoot $RelativePath))
    $rootFull = [System.IO.Path]::GetFullPath($WebRoot)

    # Directory traversal guard: the resolved path must stay under web/.
    if (-not $fullPath.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-HttpResponse -Response $Response -StatusCode 403 -Body 'Forbidden'
        return
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        Write-HttpResponse -Response $Response -StatusCode 404 -Body 'Not found'
        return
    }

    $extension = [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()
    $contentType = $script:MimeTypes[$extension]
    if ($null -eq $contentType) { $contentType = 'application/octet-stream' }

    $bytes = [System.IO.File]::ReadAllBytes($fullPath)
    Write-HttpResponse -Response $Response -StatusCode 200 -ContentType $contentType -Bytes $bytes
}

function Read-RequestBody {
    param([Parameter(Mandatory = $true)] $Request)
    if (-not $Request.HasEntityBody) { return $null }
    $reader = New-Object System.IO.StreamReader($Request.InputStream, [System.Text.Encoding]::UTF8)
    try {
        $raw = $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try {
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Start-WinForgeServer {
    param([Parameter(Mandatory = $true)] [hashtable]$Context)

    $script:Ctx = $Context

    $listener = New-Object System.Net.HttpListener
    foreach ($prefix in (Get-ServerPrefixes -Port $Context.Port)) {
        $listener.Prefixes.Add($prefix)
    }

    try {
        $listener.Start()
    } catch {
        throw "Could not listen on port $($Context.Port). Another WinForge may still be running, " +
              "or Windows is holding the port from a previous run. Wait a moment and try again, " +
              "or start with a different port: WinForge.cmd -Port 47120"
    }

    Initialize-Catalog -Context $Context
    Start-InstalledCacheRefresh -Context $Context | Out-Null

    Write-Host '  Server running. Waiting for requests...' -ForegroundColor DarkGray
    Write-Host ''

    try {
        while ($listener.IsListening) {
            # Not named $context: PowerShell variable names are case-insensitive
            # and it would collide with the [hashtable]$Context parameter.
            $httpContext = $null
            try {
                $httpContext = $listener.GetContext()
            } catch [System.Net.HttpListenerException] {
                break
            }
            if ($null -eq $httpContext) { continue }

            $request = $httpContext.Request
            $response = $httpContext.Response
            $path = $request.Url.AbsolutePath

            try {
                if ($path.StartsWith('/api/', [System.StringComparison]::OrdinalIgnoreCase)) {
                    if (-not (Test-RequestAllowed -Request $request -Token $Context.Token)) {
                        Write-JsonResponse -Response $response -StatusCode 401 `
                            -Value @{ error = 'Unauthorized. Reopen WinForge from the launcher.' }
                        continue
                    }
                    Invoke-ApiRoute -Context $Context -Request $request -Response $response -Path $path
                } else {
                    Send-StaticFile -Response $response -WebRoot $Context.WebRoot -RelativePath $path
                }
            } catch {
                $message = $_.Exception.Message
                Write-Host "  [error] $path -> $message" -ForegroundColor Red
                try {
                    Write-JsonResponse -Response $response -StatusCode 500 -Value @{ error = $message }
                } catch { }
            }
        }
    } finally {
        try { $listener.Stop() } catch { }
        try { $listener.Close() } catch { }
    }
}
