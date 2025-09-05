# Minimal-Probe.ps1 — posts one message, then exits
# Requires: DISCORD_TOKEN, PROBE_CHANNEL_ID (e.g., bot-open id 1413610856217972766)

$ErrorActionPreference = 'Stop'

function Mask($s){
  if (-not $s) { return '(empty)' }
  $s = $s.Trim()
  if ($s.Length -lt 12) { return '(short)' }
  return '{0}…{1}' -f $s.Substring(0,6), $s.Substring($s.Length-6)
}

$tokRaw = $env:DISCORD_TOKEN
$chan   = $env:PROBE_CHANNEL_ID

Write-Host ("ENV DISCORD_TOKEN len={0} mask={1}" -f ($tokRaw ? $tokRaw.Trim().Length : 0), (Mask $tokRaw))
Write-Host ("ENV PROBE_CHANNEL_ID = {0}" -f ($chan ? $chan.Trim() : '(empty)'))

if (-not $tokRaw) { throw "DISCORD_TOKEN is empty in container" }
if (-not $chan)   { throw "PROBE_CHANNEL_ID is empty in container" }

$tok = $tokRaw.Trim()
$h = @{
  Authorization  = "Bot $tok"
  "Content-Type" = "application/json"
  "User-Agent"   = "JS-Probe/1.0"
}

# Who am I?
$me = Invoke-RestMethod "https://discord.com/api/v10/users/@me" -Headers $h -Method GET
Write-Host ("users/@me → {0} (ID: {1})" -f $me.username, $me.id)

# Channel GET
$cinfo = Invoke-RestMethod ("https://discord.com/api/v10/channels/{0}" -f $chan) -Headers $h -Method GET
Write-Host ("Channel GET → {0} (id {1}, type {2})" -f $cinfo.name, $cinfo.id, $cinfo.type)

# POST
$body = @{
  content = ":satellite: probe post $(Get-Date -Format s)"
} | ConvertTo-Json
$res = Invoke-RestMethod ("https://discord.com/api/v10/channels/{0}/messages" -f $chan) -Headers $h -Method POST -Body $body
Write-Host ("POST OK → message id {0}" -f $res.id)

exit 0
