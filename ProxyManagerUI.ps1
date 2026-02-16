# ProxyManagerUI.ps1
# Professional UI to manage Proxy Host/Port + PAC bypass CIDR list (add/remove/edit)
# Requires: proxy.pac (template) + PacServer.ps1 + SetupProxy.ps1 + DisableProxy.ps1 in same folder.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"

# ====== SETTINGS ======
$TaskName  = 'CompanyProxy PAC Server'
$BaseDir   = Join-Path $env:ProgramData 'CompanyProxy'
$SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$TemplatePac = Join-Path $SourceDir 'proxy.pac'            # template you ship
$DstPac      = Join-Path $BaseDir  'proxy.pac'             # actual used by server
$PacServerPs = Join-Path $SourceDir 'PacServer.ps1'
$SetupProxy  = Join-Path $SourceDir 'SetupProxy.ps1'
$DisablePs   = Join-Path $SourceDir 'DisableProxy.ps1'

# ====== ADMIN HELPERS ======
function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Relaunch-ElevatedIfNeeded {
  if (Test-IsAdmin) { return $true }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
  $psi.Verb = 'runas'
  try {
    [Diagnostics.Process]::Start($psi) | Out-Null
    return $false
  } catch {
    [System.Windows.Forms.MessageBox]::Show(
      "Admin rights are required for scheduled task/proxy settings.",
      "Elevation cancelled",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
    return $false
  }
}

# ====== IP/CIDR HELPERS ======
function IPv4-ToUInt32([string]$ip) {
  $a = [System.Net.IPAddress]::Parse($ip).GetAddressBytes()
  if ($a.Length -ne 4) { throw "Only IPv4 supported: $ip" }
  [uint32]($a[0] -shl 24 -bor $a[1] -shl 16 -bor $a[2] -shl 8 -bor $a[3])
}
function UInt32-ToIPv4([uint32]$u) {
  $b0 = ($u -shr 24) -band 0xFF
  $b1 = ($u -shr 16) -band 0xFF
  $b2 = ($u -shr 8)  -band 0xFF
  $b3 = $u -band 0xFF
  "$b0.$b1.$b2.$b3"
}

function Mask-ToPrefix([string]$mask) {
  $m = IPv4-ToUInt32 $mask
  $count = 0
  for ($i=31; $i -ge 0; $i--) {
    if (($m -band (1u -shl $i)) -ne 0) { $count++ } else { break }
  }
  # Validate contiguous ones then zeros
  $expected = if ($count -eq 0) { 0u } else { (0xFFFFFFFFu -shl (32-$count)) }
  if ($m -ne $expected) { throw "Non-contiguous netmask not supported: $mask" }
  $count
}

function Prefix-ToMask([int]$prefix) {
  if ($prefix -lt 0 -or $prefix -gt 32) { throw "Prefix must be 0..32" }
  $m = if ($prefix -eq 0) { 0u } else { (0xFFFFFFFFu -shl (32-$prefix)) }
  UInt32-ToIPv4 $m
}

function NetMask-ToCIDR([string]$net, [string]$mask) {
  $p = Mask-ToPrefix $mask
  "$net/$p"
}

function CIDR-ToNetMask([string]$cidr) {
  $cidr = $cidr.Trim()
  if ($cidr -notmatch '^(\d{1,3}(\.\d{1,3}){3})\/(\d|[12]\d|3[0-2])$') {
    throw "Invalid CIDR: $cidr"
  }
  $ip = $Matches[1]
  $prefix = [int]$Matches[3]
  # validate octets
  $oct = $ip.Split('.')
  foreach ($o in $oct) { if ([int]$o -lt 0 -or [int]$o -gt 255) { throw "Invalid IP in CIDR: $cidr" } }

  $mask = Prefix-ToMask $prefix
  @($ip, $mask)
}

# ====== PAC PARSING/BUILDING ======
function Read-PacTemplateText {
  if (!(Test-Path $TemplatePac)) { throw "Template proxy.pac not found: $TemplatePac" }
  Get-Content -Raw -Encoding UTF8 $TemplatePac
}

function Extract-BypassPairsFromPac([string]$pacText) {
  # Extract the content inside: var bypass = [ ... ];
  $m = [regex]::Match($pacText, 'var\s+bypass\s*=\s*\[(?<body>[\s\S]*?)\]\s*;', 'IgnoreCase')
  if (!$m.Success) { throw "Could not find 'var bypass = [ ... ];' in proxy.pac" }
  $body = $m.Groups['body'].Value

  # find ["net","mask"] pairs
  $pairs = New-Object System.Collections.Generic.List[object]
  $rx = New-Object regex('\[\s*"(?<net>\d{1,3}(?:\.\d{1,3}){3})"\s*,\s*"(?<mask>\d{1,3}(?:\.\d{1,3}){3})"\s*\]', 'IgnoreCase')
  foreach ($mm in $rx.Matches($body)) {
    $net  = $mm.Groups['net'].Value
    $mask = $mm.Groups['mask'].Value
    $pairs.Add([pscustomobject]@{ Net=$net; Mask=$mask; CIDR=(NetMask-ToCIDR $net $mask) })
  }
  $pairs
}

function Replace-BypassPairsInPac([string]$pacText, [object[]]$pairs) {
  # Build JS array body with no trailing comma (older PAC engines can be picky)
  $lines = New-Object System.Collections.Generic.List[string]
  for ($i=0; $i -lt $pairs.Count; $i++) {
    $net  = $pairs[$i].Net
    $mask = $pairs[$i].Mask
    $comma = if ($i -lt $pairs.Count-1) { "," } else { "" }
    $lines.Add("    [""$net"", ""$mask""]$comma")
  }
  $newBody = "`n" + ($lines -join "`n") + "`n  "

  # Replace original bypass body
  $out = [regex]::Replace(
    $pacText,
    '(var\s+bypass\s*=\s*\[)([\s\S]*?)(\]\s*;)',
    { param($m) $m.Groups[1].Value + $newBody + $m.Groups[3].Value },
    'IgnoreCase'
  )
  $out
}

function Replace-ProxyInPac([string]$pacText, [string]$proxyHost, [int]$proxyPort) {
  # Replace occurrences of PROXY a.b.c.d:port; with PROXY proxyHost:proxyPort;
  [regex]::Replace(
    $pacText,
    'PROXY\s+\d{1,3}(?:\.\d{1,3}){3}:\d+\s*;',
    "PROXY $proxyHost`:$proxyPort;",
    [Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
}

# ====== APPLY/ENABLE/DISABLE ======
function Ensure-BaseDir {
  if (!(Test-Path $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null }
}

function Copy-SupportFilesToBase {
  Ensure-BaseDir
  foreach ($f in 'PacServer.ps1','SetupProxy.ps1','DisableProxy.ps1') {
    $src = Join-Path $SourceDir $f
    if (!(Test-Path $src)) { throw "Missing required file: $src" }
    Copy-Item -Force $src (Join-Path $BaseDir $f)
  }
}

function Save-ActualPac([string]$proxyHost, [int]$proxyPort, [object[]]$pairs) {
  Ensure-BaseDir
  $text = Read-PacTemplateText
  $text = Replace-BypassPairsInPac -pacText $text -pairs $pairs
  $text = Replace-ProxyInPac -pacText $text -proxyHost $proxyHost -proxyPort $proxyPort
  Set-Content -Path $DstPac -Value $text -Encoding UTF8
}

function Start-OrUpdatePacServer([int]$pacPort) {
  $pacServerInBase = Join-Path $BaseDir 'PacServer.ps1'
  if (!(Test-Path $pacServerInBase)) { throw "PacServer.ps1 not found in $BaseDir (copy failed?)" }

  $tr = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$pacServerInBase`" -Port $pacPort"
  & schtasks /Create /F /SC ONLOGON /TN $TaskName /TR $tr | Out-Null

  # start now (best effort; may already be running)
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$pacServerInBase`" -Port $pacPort" | Out-Null
}

function Stop-PacServerProcesses {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
    $_.CommandLine -and $_.CommandLine -match 'PacServer\.ps1'
  } | ForEach-Object {
    try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
  }
}

function Apply-SystemProxy([int]$pacPort) {
  $setupInBase = Join-Path $BaseDir 'SetupProxy.ps1'
  if (!(Test-Path $setupInBase)) { throw "SetupProxy.ps1 not found in $BaseDir (copy failed?)" }
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setupInBase -Port $pacPort | Out-Null
}

function Disable-AllProxy {
  $disableInBase = Join-Path $BaseDir 'DisableProxy.ps1'
  if (Test-Path $disableInBase) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $disableInBase | Out-Null
  } else {
    try { schtasks /Delete /F /TN $TaskName | Out-Null } catch {}
    try { netsh winhttp reset proxy | Out-Null } catch {}
  }
  Stop-PacServerProcesses
}

# ====== UI ======
if (!(Relaunch-ElevatedIfNeeded)) { exit }

# Load initial values from template (proxy host/port from first PROXY occurrence)
$templateText = Read-PacTemplateText

$proxyHostDefault = '192.168.0.202'
$proxyPortDefault = 64524
$mm = [regex]::Match($templateText, 'PROXY\s+(?<h>\d{1,3}(?:\.\d{1,3}){3}):(?<p>\d+)\s*;', 'IgnoreCase')
if ($mm.Success) {
  $proxyHostDefault = $mm.Groups['h'].Value
  $proxyPortDefault = [int]$mm.Groups['p'].Value
}

$pairs = Extract-BypassPairsFromPac $templateText

# Form
$form = New-Object System.Windows.Forms.Form
$form.Text = "Company Proxy Manager"
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(860, 560)
$form.MinimumSize = New-Object System.Drawing.Size(860, 560)

# Top panel for proxy settings
$panelTop = New-Object System.Windows.Forms.Panel
$panelTop.Dock = 'Top'
$panelTop.Height = 80

$lblHost = New-Object System.Windows.Forms.Label
$lblHost.Text = "Proxy Host/IP:"
$lblHost.Location = New-Object System.Drawing.Point(16, 16)
$lblHost.AutoSize = $true

$txtHost = New-Object System.Windows.Forms.TextBox
$txtHost.Location = New-Object System.Drawing.Point(120, 12)
$txtHost.Width = 180
$txtHost.Text = $proxyHostDefault

$lblPort = New-Object System.Windows.Forms.Label
$lblPort.Text = "Proxy Port:"
$lblPort.Location = New-Object System.Drawing.Point(320, 16)
$lblPort.AutoSize = $true

$txtPort = New-Object System.Windows.Forms.TextBox
$txtPort.Location = New-Object System.Drawing.Point(395, 12)
$txtPort.Width = 80
$txtPort.Text = "$proxyPortDefault"

$lblPacPort = New-Object System.Windows.Forms.Label
$lblPacPort.Text = "PAC Server Port:"
$lblPacPort.Location = New-Object System.Drawing.Point(500, 16)
$lblPacPort.AutoSize = $true

$txtPacPort = New-Object System.Windows.Forms.TextBox
$txtPacPort.Location = New-Object System.Drawing.Point(610, 12)
$txtPacPort.Width = 80
$txtPacPort.Text = "8787"

$btnEnable = New-Object System.Windows.Forms.Button
$btnEnable.Text = "Enable / Apply"
$btnEnable.Location = New-Object System.Drawing.Point(120, 44)
$btnEnable.Size = New-Object System.Drawing.Size(140, 28)

$btnDisable = New-Object System.Windows.Forms.Button
$btnDisable.Text = "Disable"
$btnDisable.Location = New-Object System.Drawing.Point(270, 44)
$btnDisable.Size = New-Object System.Drawing.Size(100, 28)

$btnSavePacOnly = New-Object System.Windows.Forms.Button
$btnSavePacOnly.Text = "Save PAC only"
$btnSavePacOnly.Location = New-Object System.Drawing.Point(380, 44)
$btnSavePacOnly.Size = New-Object System.Drawing.Size(120, 28)

$panelTop.Controls.AddRange(@(
  $lblHost,$txtHost,$lblPort,$txtPort,$lblPacPort,$txtPacPort,
  $btnEnable,$btnDisable,$btnSavePacOnly
))

# Grid
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AutoSizeColumnsMode = 'Fill'
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $true
$grid.RowHeadersVisible = $false
$grid.EditMode = 'EditOnKeystrokeOrF2'

# Data table for binding
$table = New-Object System.Data.DataTable
[void]$table.Columns.Add("CIDR",[string])

foreach ($p in $pairs) {
  $r = $table.NewRow()
  $r["CIDR"] = $p.CIDR
  $table.Rows.Add($r) | Out-Null
}
$grid.DataSource = $table

# Bottom panel for actions on bypass list
$panelBottom = New-Object System.Windows.Forms.Panel
$panelBottom.Dock = 'Bottom'
$panelBottom.Height = 60

$btnAdd = New-Object System.Windows.Forms.Button
$btnAdd.Text = "Add"
$btnAdd.Location = New-Object System.Drawing.Point(16, 14)
$btnAdd.Size = New-Object System.Drawing.Size(90, 30)

$btnEdit = New-Object System.Windows.Forms.Button
$btnEdit.Text = "Edit"
$btnEdit.Location = New-Object System.Drawing.Point(112, 14)
$btnEdit.Size = New-Object System.Drawing.Size(90, 30)

$btnRemove = New-Object System.Windows.Forms.Button
$btnRemove.Text = "Remove"
$btnRemove.Location = New-Object System.Drawing.Point(208, 14)
$btnRemove.Size = New-Object System.Drawing.Size(90, 30)

$btnImport = New-Object System.Windows.Forms.Button
$btnImport.Text = "Import CIDR list…"
$btnImport.Location = New-Object System.Drawing.Point(320, 14)
$btnImport.Size = New-Object System.Drawing.Size(140, 30)

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = "Export CIDR list…"
$btnExport.Location = New-Object System.Drawing.Point(470, 14)
$btnExport.Size = New-Object System.Drawing.Size(140, 30)

$status = New-Object System.Windows.Forms.Label
$status.Text = "Ready."
$status.AutoSize = $false
$status.TextAlign = 'MiddleRight'
$status.Dock = 'Right'
$status.Width = 220

$panelBottom.Controls.AddRange(@($btnAdd,$btnEdit,$btnRemove,$btnImport,$btnExport,$status))

$form.Controls.Add($grid)
$form.Controls.Add($panelBottom)
$form.Controls.Add($panelTop)

# ====== DIALOG HELPERS ======
function Prompt-CIDR([string]$title, [string]$initial = "") {
  $dlg = New-Object System.Windows.Forms.Form
  $dlg.Text = $title
  $dlg.StartPosition = 'CenterParent'
  $dlg.Size = New-Object System.Drawing.Size(380, 150)
  $dlg.FormBorderStyle = 'FixedDialog'
  $dlg.MaximizeBox = $false
  $dlg.MinimizeBox = $false

  $lbl = New-Object System.Windows.Forms.Label
  $lbl.Text = "CIDR (e.g. 37.156.0.0/16):"
  $lbl.Location = New-Object System.Drawing.Point(12, 15)
  $lbl.AutoSize = $true

  $txt = New-Object System.Windows.Forms.TextBox
  $txt.Location = New-Object System.Drawing.Point(15, 40)
  $txt.Width = 340
  $txt.Text = $initial

  $ok = New-Object System.Windows.Forms.Button
  $ok.Text = "OK"
  $ok.Location = New-Object System.Drawing.Point(195, 75)
  $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK

  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = "Cancel"
  $cancel.Location = New-Object System.Drawing.Point(280, 75)
  $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

  $dlg.AcceptButton = $ok
  $dlg.CancelButton = $cancel
  $dlg.Controls.AddRange(@($lbl,$txt,$ok,$cancel))

  $res = $dlg.ShowDialog($form)
  if ($res -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
  $txt.Text.Trim()
}

function Validate-TopInputs {
  $h = $txtHost.Text.Trim()
  $p = $txtPort.Text.Trim()
  $pp = $txtPacPort.Text.Trim()

  if ([string]::IsNullOrWhiteSpace($h)) { throw "Proxy host is required." }
  if ($p -notmatch '^\d+$') { throw "Proxy port must be numeric." }
  if ($pp -notmatch '^\d+$') { throw "PAC server port must be numeric." }

  $pInt = [int]$p
  $ppInt = [int]$pp
  if ($pInt -lt 1 -or $pInt -gt 65535) { throw "Proxy port must be 1..65535." }
  if ($ppInt -lt 1 -or $ppInt -gt 65535) { throw "PAC port must be 1..65535." }

  @($h,$pInt,$ppInt)
}

function Get-PairsFromGrid {
  # Convert CIDR rows to Net/Mask pairs for PAC
  $list = New-Object System.Collections.Generic.List[object]
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'

  foreach ($row in $table.Rows) {
    $cidr = ([string]$row["CIDR"]).Trim()
    if ([string]::IsNullOrWhiteSpace($cidr)) { continue }

    # Validate + convert
    $nm = CIDR-ToNetMask $cidr
    $net = $nm[0]; $mask = $nm[1]

    # normalize key (avoid duplicates)
    $key = "$net|$mask"
    if ($seen.Add($key)) {
      $list.Add([pscustomobject]@{ Net=$net; Mask=$mask })
    }
  }
  $list.ToArray()
}

# ====== BUTTON EVENTS ======
$btnAdd.Add_Click({
  try {
    $cidr = Prompt-CIDR -title "Add bypass range"
    if ($null -eq $cidr) { return }
    # validate
    [void](CIDR-ToNetMask $cidr)

    $r = $table.NewRow()
    $r["CIDR"] = $cidr
    $table.Rows.Add($r) | Out-Null
    $status.Text = "Added."
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Invalid CIDR", "OK", "Error") | Out-Null
  }
})

$btnEdit.Add_Click({
  try {
    if ($grid.SelectedRows.Count -ne 1) {
      [System.Windows.Forms.MessageBox]::Show("Select exactly one row to edit.", "Edit", "OK", "Information") | Out-Null
      return
    }
    $idx = $grid.SelectedRows[0].Index
    $current = [string]$table.Rows[$idx]["CIDR"]
    $cidr = Prompt-CIDR -title "Edit bypass range" -initial $current
    if ($null -eq $cidr) { return }
    [void](CIDR-ToNetMask $cidr)
    $table.Rows[$idx]["CIDR"] = $cidr
    $status.Text = "Edited."
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Invalid CIDR", "OK", "Error") | Out-Null
  }
})

$btnRemove.Add_Click({
  if ($grid.SelectedRows.Count -lt 1) { return }
  $res = [System.Windows.Forms.MessageBox]::Show(
    "Remove selected row(s)?",
    "Remove",
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
  )
  if ($res -ne [System.Windows.Forms.DialogResult]::Yes) { return }

  # Remove from highest index down
  $idxs = @()
  foreach ($r in $grid.SelectedRows) { $idxs += $r.Index }
  $idxs = $idxs | Sort-Object -Descending
  foreach ($i in $idxs) { $table.Rows.RemoveAt($i) }
  $status.Text = "Removed."
})

$btnImport.Add_Click({
  $ofd = New-Object System.Windows.Forms.OpenFileDialog
  $ofd.Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*"
  $ofd.Title  = "Import CIDR list (one per line)"
  if ($ofd.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

  try {
    $lines = Get-Content -Path $ofd.FileName -ErrorAction Stop
    $added = 0
    foreach ($line in $lines) {
      $cidr = ($line -split '#')[0].Trim()
      if ([string]::IsNullOrWhiteSpace($cidr)) { continue }
      [void](CIDR-ToNetMask $cidr)

      $r = $table.NewRow()
      $r["CIDR"] = $cidr
      $table.Rows.Add($r) | Out-Null
      $added++
    }
    $status.Text = "Imported $added."
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Import failed", "OK", "Error") | Out-Null
  }
})

$btnExport.Add_Click({
  $sfd = New-Object System.Windows.Forms.SaveFileDialog
  $sfd.Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*"
  $sfd.Title  = "Export CIDR list"
  $sfd.FileName = "bypass-cidr.txt"
  if ($sfd.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

  try {
    $cidrs = @()
    foreach ($row in $table.Rows) {
      $c = ([string]$row["CIDR"]).Trim()
      if (![string]::IsNullOrWhiteSpace($c)) { $cidrs += $c }
    }
    Set-Content -Path $sfd.FileName -Value $cidrs -Encoding UTF8
    $status.Text = "Exported."
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Export failed", "OK", "Error") | Out-Null
  }
})

$btnSavePacOnly.Add_Click({
  try {
    $vals = Validate-TopInputs
    $h = $vals[0]; $p = $vals[1]

    $pairsOut = Get-PairsFromGrid
    Copy-SupportFilesToBase
    Save-ActualPac -proxyHost $h -proxyPort $p -pairs $pairsOut

    $status.Text = "PAC saved to $DstPac"
    [System.Windows.Forms.MessageBox]::Show("Saved PAC to:`n$DstPac", "Saved", "OK", "Information") | Out-Null
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Save failed", "OK", "Error") | Out-Null
  }
})

$btnEnable.Add_Click({
  try {
    $vals = Validate-TopInputs
    $h = $vals[0]; $p = $vals[1]; $pacPort = $vals[2]

    $pairsOut = Get-PairsFromGrid
    Copy-SupportFilesToBase
    Save-ActualPac -proxyHost $h -proxyPort $p -pairs $pairsOut

    # restart server (best effort)
    Stop-PacServerProcesses
    Start-OrUpdatePacServer -pacPort $pacPort
    Apply-SystemProxy -pacPort $pacPort

    $status.Text = "Enabled (PAC localhost:$pacPort)"
    [System.Windows.Forms.MessageBox]::Show(
      "Enabled.`nPAC URL: http://127.0.0.1:$pacPort/proxy.pac",
      "Enabled",
      "OK",
      "Information"
    ) | Out-Null
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Enable failed", "OK", "Error") | Out-Null
  }
})

$btnDisable.Add_Click({
  try {
    Disable-AllProxy
    $status.Text = "Disabled."
    [System.Windows.Forms.MessageBox]::Show("Proxy disabled.", "Disabled", "OK", "Information") | Out-Null
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Disable failed", "OK", "Error") | Out-Null
  }
})

# Show
[void]$form.ShowDialog()
