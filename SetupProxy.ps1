# Sets Windows proxy to use local PAC served on localhost and disables manual proxy + auto-detect.
param([int]$Port = 8787)

$ErrorActionPreference = "Stop"
$pacUrl = "http://127.0.0.1:$Port/proxy.pac?x=1"

$inet = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
$conn = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections"

if (!(Test-Path $inet)) { New-Item -Path $inet -Force | Out-Null }

# Set PAC URL, disable manual proxy
Set-ItemProperty -Path $inet -Name AutoConfigURL -Type String -Value $pacUrl
Set-ItemProperty -Path $inet -Name ProxyEnable   -Type DWord  -Value 0

# Remove any old manual proxy values
try { Remove-ItemProperty -Path $inet -Name ProxyServer   -ErrorAction SilentlyContinue } catch {}
try { Remove-ItemProperty -Path $inet -Name ProxyOverride -ErrorAction SilentlyContinue } catch {}

function Set-ConnectionFlags {
    param([byte[]]$data)

    # Flags byte at index 8 in DefaultConnectionSettings blob.
    # 0x02 = Manual proxy enabled
    # 0x04 = Use AutoConfig URL (PAC)
    # 0x08 = Auto-detect (WPAD)
    $flags = $data[8]

    # Disable manual proxy + auto-detect, enable PAC
    $flags = $flags -band 0xFD      # clear 0x02
    $flags = $flags -band 0xF7      # clear 0x08
    $flags = $flags -bor  0x04      # set   0x04

    $data[8] = $flags
    return $data
}

# Update both connection blobs if present
if (Test-Path $conn) {
    $props = Get-ItemProperty -Path $conn
    foreach ($name in @("DefaultConnectionSettings","SavedLegacySettings")) {
        if ($props.PSObject.Properties.Name -contains $name) {
            $data = [byte[]]$props.$name
            $new  = Set-ConnectionFlags -data $data
            Set-ItemProperty -Path $conn -Name $name -Value $new
        }
    }
}

# Ask WinINET clients to refresh settings
try {
  $sig = @"
using System;
using System.Runtime.InteropServices;
public class WinInet {
  [DllImport("wininet.dll", SetLastError=true)]
  public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
}
"@
  Add-Type $sig -ErrorAction SilentlyContinue | Out-Null
  # INTERNET_OPTION_SETTINGS_CHANGED = 39, INTERNET_OPTION_REFRESH = 37
  [WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
  [WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
} catch {}

# If elevated, import into WinHTTP (some apps/services use WinHTTP)
try { netsh winhttp import proxy source=ie | Out-Null } catch {}

Write-Host "Proxy PAC configured: $pacUrl"
Write-Host "Manual proxy disabled, auto-detect disabled."
