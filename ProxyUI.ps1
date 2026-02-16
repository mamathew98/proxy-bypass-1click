# ProxyUI.ps1 - simple WinForms UI to configure PAC proxy + enable/disable
# Put this next to proxy.pac, PacServer.ps1, SetupProxy.ps1, DisableProxy.ps1 (or adjust $SourceDir)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$TaskName = 'CompanyProxy PAC Server'
$Base     = Join-Path $env:ProgramData 'CompanyProxy'
$SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Elevated {
  param([string]$ArgLine)
  if (Test-IsAdmin) { return $true }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $ArgLine"
  $psi.Verb = 'runas'
  try {
    [Diagnostics.Process]::Start($psi) | Out-Null
    return $false  # current (non-elevated) instance should exit
  } catch {
    [System.Windows.Forms.MessageBox]::Show('Admin rights are required to create the logon task / set system proxy.', 'Elevation cancelled', 'OK', 'Warning') | Out-Null
    return $false
  }
}

function Write-PacFile {
  param(
    [Parameter(Mandatory)] [string]$ProxyHost,
    [Parameter(Mandatory)] [int]$ProxyPort
  )

  $srcPac = Join-Path $SourceDir 'proxy.pac'
  if (!(Test-Path $srcPac)) { throw "proxy.pac not found in $SourceDir" }

  $text = Get-Content -Raw -Encoding UTF8 $srcPac

  # Replace ALL occurrences of "PROXY x.x.x.x:port;" with the chosen proxy
  $newText = [regex]::Replace(
    $text,
    'PROXY\s+\d{1,3}(?:\.\d{1,3}){3}:\d+\s*;',
    "PROXY $ProxyHost`:$ProxyPort;",
    [Text.RegularExpressions.RegexOptions]::IgnoreCase
  )

  if (!(Test-Path $Base)) { New-Item -ItemType Directory -Path $Base -Force | Out-Null }
  $dstPac = Join-Path $Base 'proxy.pac'
  Set-Content -Path $dstPac -Value $newText -Encoding UTF8
}

function Copy-SupportFiles {
  if (!(Test-Path $Base)) { New-Item -ItemType Directory -Path $Base -Force | Out-Null }
  foreach ($f in 'PacServer.ps1','SetupProxy.ps1','DisableProxy.ps1') {
    $src = Join-Path $SourceDir $f
    if (!(Test-Path $src)) { throw "$f not found in $SourceDir" }
    Copy-Item -Force $src (Join-Path $Base $f)
  }
}

function Start-PacServerTask {
  param([int]$PacPort)

  $pacServer = Join-Path $Base 'PacServer.ps1'
  $tr = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$pacServer`" -Port $PacPort"

  # Create/update the task
  & schtasks /Create /F /SC ONLOGON /TN $TaskName /TR $tr | Out-Null

  # Start it now
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$pacServer`" -Port $PacPort"
}

function Enable-ProxyPac {
  param([string]$ProxyHost,[int]$ProxyPort,[int]$PacPort)

  Copy-SupportFiles
  Write-PacFile -ProxyHost $ProxyHost -ProxyPort $ProxyPort
  Start-PacServerTask -PacPort $PacPort

  $setup = Join-Path $Base 'SetupProxy.ps1'
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Port $PacPort | Out-Null
}

function Stop-PacServerProcesses {
  # Best-effort stop of any running PacServer.ps1 instance for this user
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
    $_.CommandLine -and $_.CommandLine -match 'PacServer\.ps1'
  } | ForEach-Object {
    try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
  }
}

function Disable-ProxyPac {
  $disable = Join-Path $Base 'DisableProxy.ps1'
  if (Test-Path $disable) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $disable | Out-Null
  } else {
    # fallback: at least clear the scheduled task + stop server
    try { schtasks /Delete /F /TN $TaskName | Out-Null } catch {}
    try { netsh winhttp reset proxy | Out-Null } catch {}
  }
  Stop-PacServerProcesses
}

# Optional CLI mode so you can create shortcuts like: ProxyUI.ps1 -Enable -ProxyHost 1.2.3.4 -ProxyPort 8080
# Manual parsing avoids PowerShell positional-binding oddities when launched from a batch file
$ProxyHost = $null
$ProxyPort = $null
$PacPort = 8787
$Enable = $false
$Disable = $false

for ($i = 0; $i -lt $args.Count; $i++) {
  $a = $args[$i]
  switch -Regex ($a) {
    '^-(?i)enable$'   { $Enable = $true; continue }
    '^-(?i)disable$'  { $Disable = $true; continue }
    '^-(?i)proxyhost$' { if ($i+1 -lt $args.Count) { $i++; $ProxyHost = $args[$i] } continue }
    '^-(?i)proxyport$' { if ($i+1 -lt $args.Count) { $i++; $ProxyPort = [int]$args[$i] } continue }
    '^-(?i)pacport$'   { if ($i+1 -lt $args.Count) { $i++; $PacPort = [int]$args[$i] } continue }
    '^[0-9]+$' {
      if (-not $ProxyPort) { $ProxyPort = [int]$a; continue }
      if (-not $PacPort)   { $PacPort   = [int]$a; continue }
    }
  }
}

if ($Enable) {
  if (!(Ensure-Elevated "-Enable -ProxyHost `"$ProxyHost`" -ProxyPort $ProxyPort -PacPort $PacPort")) { exit }
  Enable-ProxyPac -ProxyHost $ProxyHost -ProxyPort $ProxyPort -PacPort $PacPort
  exit
}
if ($Disable) {
  if (!(Ensure-Elevated '-Disable')) { exit }
  Disable-ProxyPac
  exit
}

# --- UI ---
$form = New-Object Windows.Forms.Form
$form.Text = 'Company Proxy (PAC)'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size(420, 240)
$form.MaximizeBox = $false
$form.FormBorderStyle = 'FixedDialog'

$lbl1 = New-Object Windows.Forms.Label
$lbl1.Text = 'Proxy IP / Host:'
$lbl1.Location = New-Object Drawing.Point(20, 20)
$lbl1.AutoSize = $true

$txtHost = New-Object Windows.Forms.TextBox
$txtHost.Location = New-Object Drawing.Point(140, 16)
$txtHost.Size = New-Object Drawing.Size(240, 22)
$txtHost.Text = '192.168.0.202'

$lbl2 = New-Object Windows.Forms.Label
$lbl2.Text = 'Proxy Port:'
$lbl2.Location = New-Object Drawing.Point(20, 55)
$lbl2.AutoSize = $true

$txtPort = New-Object Windows.Forms.TextBox
$txtPort.Location = New-Object Drawing.Point(140, 51)
$txtPort.Size = New-Object Drawing.Size(90, 22)
$txtPort.Text = '64524'

$lbl3 = New-Object Windows.Forms.Label
$lbl3.Text = 'PAC server port:'
$lbl3.Location = New-Object Drawing.Point(20, 90)
$lbl3.AutoSize = $true

$txtPacPort = New-Object Windows.Forms.TextBox
$txtPacPort.Location = New-Object Drawing.Point(140, 86)
$txtPacPort.Size = New-Object Drawing.Size(90, 22)
$txtPacPort.Text = '8787'

$btnEnable = New-Object Windows.Forms.Button
$btnEnable.Text = 'Enable'
$btnEnable.Location = New-Object Drawing.Point(20, 130)
$btnEnable.Size = New-Object Drawing.Size(110, 30)

$btnDisable = New-Object Windows.Forms.Button
$btnDisable.Text = 'Disable'
$btnDisable.Location = New-Object Drawing.Point(140, 130)
$btnDisable.Size = New-Object Drawing.Size(110, 30)

$status = New-Object Windows.Forms.Label
$status.Text = 'Ready.'
$status.Location = New-Object Drawing.Point(20, 175)
$status.Size = New-Object Drawing.Size(360, 30)

function Validate-Inputs {
  $h = $txtHost.Text.Trim()
  $p = $txtPort.Text.Trim()
  $pp = $txtPacPort.Text.Trim()

  if ([string]::IsNullOrWhiteSpace($h)) { throw 'Proxy host is required.' }
  if ($p -notmatch '^\d+$') { throw 'Proxy port must be a number.' }
  if ($pp -notmatch '^\d+$') { throw 'PAC port must be a number.' }

  $pInt  = [int]$p
  $ppInt = [int]$pp
  if ($pInt -lt 1 -or $pInt -gt 65535) { throw 'Proxy port must be 1..65535.' }
  if ($ppInt -lt 1 -or $ppInt -gt 65535) { throw 'PAC port must be 1..65535.' }

  return @($h,$pInt,$ppInt)
}

$btnEnable.Add_Click({
  try {
    $vals = Validate-Inputs
    $h = $vals[0]; $p = $vals[1]; $pp = $vals[2]

    # Relaunch elevated to do the real work
    $arg = "-Enable -ProxyHost `"$h`" -ProxyPort $p -PacPort $pp"
    if (!(Ensure-Elevated $arg)) { $form.Close(); return }

    $status.Text = "Enabled (proxy ${h}:${p} via PAC localhost:${pp})."
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
  }
})

$btnDisable.Add_Click({
  try {
    if (!(Ensure-Elevated '-Disable')) { $form.Close(); return }
    $status.Text = 'Disabled.'
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
  }
})

$form.Controls.AddRange(@($lbl1,$txtHost,$lbl2,$txtPort,$lbl3,$txtPacPort,$btnEnable,$btnDisable,$status))
[void]$form.ShowDialog()
