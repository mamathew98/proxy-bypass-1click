# Disables PAC and resets proxy to DIRECT (no proxy)
$ErrorActionPreference = "SilentlyContinue"

$TaskName = 'CompanyProxy PAC Server'
$inet = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
$conn = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections"

Set-ItemProperty -Path $inet -Name ProxyEnable -Type DWord -Value 0
try { Remove-ItemProperty -Path $inet -Name AutoConfigURL   -ErrorAction SilentlyContinue } catch {}
try { Remove-ItemProperty -Path $inet -Name ProxyServer     -ErrorAction SilentlyContinue } catch {}
try { Remove-ItemProperty -Path $inet -Name ProxyOverride   -ErrorAction SilentlyContinue } catch {}

function ClearPACFlag {
    param([byte[]]$data)
    # clear 0x04 (PAC)
    $data[8] = $data[8] -band 0xFB
    return $data
}

if (Test-Path $conn) {
    $props = Get-ItemProperty -Path $conn
    foreach ($name in @("DefaultConnectionSettings","SavedLegacySettings")) {
        if ($props.PSObject.Properties.Name -contains $name) {
            $data = [byte[]]$props.$name
            $new  = ClearPACFlag -data $data
            Set-ItemProperty -Path $conn -Name $name -Value $new
        }
    }
}

# Remove scheduled task + reset WinHTTP
try { schtasks /Delete /F /TN $TaskName >$null 2>&1 } catch {}
try { netsh winhttp reset proxy | Out-Null } catch {}

# Stop any running PacServer.ps1 process
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
  $_.CommandLine -and $_.CommandLine -match 'PacServer\.ps1'
} | ForEach-Object {
  try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Host "Proxy disabled."
