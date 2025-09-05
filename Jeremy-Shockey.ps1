# Jeremy-Shockey (baseline sanity script)
# - Loads env vars
# - Sends a boot test message to CHAN_WEEKLY_MATCHUPS
# - Enters a lightweight loop
# ASCII-only to avoid encoding surprises

Write-Host ("BUILD STAMP: {0}" -f (Get-Date -Format s)) -ForegroundColor Magenta

# ========= ENV =========
$RequiredEnv = @(
  'DISCORD_TOKEN','GUILD_ID','CHAN_WEEKLY_MATCHUPS'
)
$missing = @()
foreach ($k in $RequiredEnv) {
  $v = [System.Environment]::GetEnvironmentVariable($k)
  if ([string]::IsNullOrWhiteSpace($v)) { $missing += $k }
}
if ($missing.Count -gt 0) {
  Write-Host ("Missing env vars: {0}" -f ($missing -join ', ')) -ForegroundColor Red
  exit 1
}

$DISCORD_TOKEN        = $env:DISCORD_TOKEN
$GUILD_ID             = $env:GUILD_ID
$CHAN_WEEKLY_MATCHUPS = $env:CHAN_WEEKLY_MATCHUPS

# ========= TIME HELPERS (ET) =========
function Get-NowET {
  # Try Windows TZ first, then IANA. If both fail (e.g., tzdata missing),
  # fall back to UTC and approximate US Eastern using a simple DST rule.
  try {
    $tz = $null
    try { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById(''Eastern Standard Time'') } catch {}
    if (-not $tz) { try { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById(''America/New_York'') } catch {} }
    if ($tz) {
      return [System.TimeZoneInfo]::ConvertTime([DateTime]::UtcNow, $tz)
    }

    # Fallback: approximate ET from UTC with a basic US DST rule.
    # Second Sunday in March @ 02:00 to first Sunday in November @ 02:00 is DST (UTC-4), else UTC-5.
    $utc = [DateTime]::UtcNow
    $year = $utc.Year

    function Get-NthWeekdayOfMonth([int]$y,[int]$m,[System.DayOfWeek]$dow,[int]$nth) {
      $d = Get-Date -Year $y -Month $m -Day 1 -Hour 2 -Minute 0 -Second 0 -Millisecond 0
      $offset = (($dow - $d.DayOfWeek + 7) % 7)
      $first = $d.AddDays($offset)
      return $first.AddDays(7*($nth-1))
    }
    function Get-FirstWeekdayOfMonth([int]$y,[int]$m,[System.DayOfWeek]$dow) {
      Get-NthWeekdayOfMonth -y $y -m $m -dow $dow -nth 1
    }

    $dstStart = Get-NthWeekdayOfMonth -y $year -m 3 -dow ([System.DayOfWeek]::Sunday) -nth 2  # Mar, 2nd Sunday 02:00
    $dstEnd   = Get-FirstWeekdayOfMonth -y $year -m 11 -dow ([System.DayOfWeek]::Sunday)      # Nov, 1st Sunday 02:00

    # If utc is outside [dstStart..dstEnd), use UTC-5; otherwise UTC-4
    $offsetHours = if ($utc -ge $dstStart -and $utc -lt $dstEnd) { -4 } else { -5 }
    return $utc.AddHours($offsetHours)
  } catch {
    # Last-resort: just return UTC so it never breaks
    return [DateTime]::UtcNow
  }
}
  catch { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById('America/New_York') }
  [System.TimeZoneInfo]::ConvertTime([DateTime]::UtcNow, $tz)
}
function Next-Weekly {
  param(
    [Parameter(Mandatory=$true)][object]$dayOfWeek,
    [Parameter(Mandatory=$true)][int]$hour,
    [Parameter(Mandatory=$true)][int]$minute
  )
  $now = Get-NowET
  $target = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour $hour -Minute $minute -Second 0

  if ($dayOfWeek -is [System.DayOfWeek]) { $dow = [System.DayOfWeek]$dayOfWeek }
  else {
    try { $dow = [System.Enum]::Parse([System.DayOfWeek], $dayOfWeek.ToString(), $true) }
    catch { $dow = $now.DayOfWeek }
  }

  while (($target.DayOfWeek -ne $dow) -or ($target -le $now)) { $target = $target.AddDays(1) }
  return $target
}

# ========= DISCORD =========
$DiscordApi = 'https://discord.com/api/v10'
function Invoke-Discord {
  param(
    [ValidateSet('GET','POST','PATCH')][string]$Method,
    [string]$Path,
    [object]$Body = $null
  )
  $headers = @{ 'Authorization' = "Bot $DISCORD_TOKEN"; 'Content-Type' = 'application/json' }
  $uri = "$DiscordApi$Path"
  try {
    if ($Body) { $json = $Body | ConvertTo-Json -Depth 6; $res = Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -Body $json }
    else { $res = Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers }
    Start-Sleep -Milliseconds 900
    return $res
  } catch {
    Write-Host ("Discord {0} {1} failed: {2}" -f $Method,$Path,$_.Exception.Message) -ForegroundColor Yellow
    return $null
  }
}
function Send-DiscordMessage { param([string]$ChannelId,[string]$Content) Invoke-Discord -Method 'POST' -Path "/channels/$ChannelId/messages" -Body @{ content=$Content } }

# ========= BOOT TEST =========
try {
  $bootMsg = ("Jeremy Shockey online at {0} (ET). Baseline test post." -f ((Get-NowET).ToString('yyyy-MM-dd HH:mm:ss')))
  $res = Send-DiscordMessage -ChannelId $CHAN_WEEKLY_MATCHUPS -Content $bootMsg
  if ($res) { Write-Host "Boot test posted to channel $CHAN_WEEKLY_MATCHUPS" -ForegroundColor Green }
  else { Write-Host "Boot test FAILED to post (check token/permissions/channel id)" -ForegroundColor Red }
} catch {
  Write-Host ("Boot test error: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

# ========= LIGHT MAIN LOOP =========
$nextHeartbeat = (Get-NowET).AddMinutes(5)
Write-Host "Jeremy Shockey baseline loop started." -ForegroundColor Cyan
while ($true) {
  $now = Get-NowET
  if ($now -ge $nextHeartbeat) {
    Write-Host ("Heartbeat: {0}" -f $now.ToString('s')) -ForegroundColor DarkCyan
    $nextHeartbeat = $nextHeartbeat.AddMinutes(5)
  }
  Start-Sleep -Seconds 1
}

