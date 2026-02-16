# Local PAC web server: http://127.0.0.1:<Port>/proxy.pac
param([int]$Port = 8787)

$ErrorActionPreference = "SilentlyContinue"

$basePath = Join-Path $env:ProgramData "CompanyProxy"
$pacPath  = Join-Path $basePath "proxy.pac"
if (!(Test-Path $pacPath)) { exit 0 }

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response

        if ($req.Url.AbsolutePath -ne "/proxy.pac") {
            $res.StatusCode = 404
            $res.Close()
            continue
        }

        $bytes = [System.Text.Encoding]::UTF8.GetBytes((Get-Content -Raw -Encoding UTF8 $pacPath))
        $res.ContentType = "application/x-ns-proxy-autoconfig"
        $res.ContentEncoding = [System.Text.Encoding]::UTF8
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.Close()
    }
} finally {
    try { $listener.Stop() } catch {}
    try { $listener.Close() } catch {}
}
