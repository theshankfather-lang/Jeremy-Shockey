function Start-DiscordPresence {
  param(
    [Parameter(Mandatory=$true)][string]$Token,
    [string]$ActivityName = "Fantasy Football",
    [string]$Status = "online"
  )
  $sb = {
    param($Token,$ActivityName,$Status)
    try { Add-Type -AssemblyName System.Net.WebSockets } catch {}
    $ws  = [System.Net.WebSockets.ClientWebSocket]::new()
    $uri = [Uri]"wss://gateway.discord.gg/?v=10&encoding=json"
    $ws.ConnectAsync($uri,[Threading.CancellationToken]::None).Wait()

    # Receive HELLO (op 10)
    $buf = New-Object byte[] 8192
    $res = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf),[Threading.CancellationToken]::None).Result
    $txt = [Text.Encoding]::UTF8.GetString($buf,0,$res.Count)
    $hello = $null; try { $hello = $txt | ConvertFrom-Json } catch {}
    $interval = if ($hello -and $hello.d -and $hello.d.heartbeat_interval) { [int]$hello.d.heartbeat_interval } else { 41250 }

    # IDENTIFY (op 2) with presence (no privileged intents)
    $identify = @{
      op = 2
      d  = @{
        token      = $Token
        intents    = 0
        properties = @{ os="linux"; browser="powershell"; device="powershell" }
        presence   = @{
          status     = $Status
          activities = @(@{ name = $ActivityName; type = 0 })
          since      = $null
          afk        = $false
        }
      }
    } | ConvertTo-Json -Depth 8
    $idBytes = [Text.Encoding]::UTF8.GetBytes($identify)
    [void]$ws.SendAsync([ArraySegment[byte]]::new($idBytes),[System.Net.WebSockets.WebSocketMessageType]::Text,$true,[Threading.CancellationToken]::None).Wait()

    # Heartbeat (op 1)
    $last = [DateTime]::UtcNow; $seq = $null
    while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
      if (([DateTime]::UtcNow - $last).TotalMilliseconds -ge $interval) {
        $hb = @{ op = 1; d = $seq } | ConvertTo-Json
        $hbBytes = [Text.Encoding]::UTF8.GetBytes($hb)
        [void]$ws.SendAsync([ArraySegment[byte]]::new($hbBytes),[System.Net.WebSockets.WebSocketMessageType]::Text,$true,[Threading.CancellationToken]::None).Wait()
        $last = [DateTime]::UtcNow
      }
      Start-Sleep -Milliseconds 200
    }
  } # end scriptblock
  Try { Get-Job -Name "discord-presence" -ErrorAction Stop | Remove-Job -Force } Catch {}
  Start-Job -Name "discord-presence" -ScriptBlock $sb -ArgumentList $Token,$ActivityName,$Status | Out-Null
  Write-Host "Gateway presence job started (status: $Status, activity: $ActivityName)." -ForegroundColor Green
}

catch {}
    $ws  = [System.Net.WebSockets.ClientWebSocket]::new()
    $uri = [Uri]"wss://gateway.discord.gg/?v=10&encoding=json"
    $ws.ConnectAsync($uri,[Threading.CancellationToken]::None).Wait()

    # Receive HELLO (op 10)
    $buf = New-Object byte[] 8192
    $res = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf),[Threading.CancellationToken]::None).Result
    $txt = [Text.Encoding]::UTF8.GetString($buf,0,$res.Count)
    $hello = $null; try { $hello = $txt | ConvertFrom-Json } catch {}
    $interval = if ($hello -and $hello.d -and $hello.d.heartbeat_interval) { [int]$hello.d.heartbeat_interval } else { 41250 }

    # IDENTIFY (op 2) with presence (no privileged intents)
    $identify = @{
      op = 2
      d  = @{
        token      = $Token
        intents    = 0
        properties = @{ os="linux"; browser="powershell"; device="powershell" }
        presence   = @{
          status     = $Status
          activities = @(@{ name = $ActivityName; type = 0 })
          since      = $null
          afk        = $false
        }
      }
    } | ConvertTo-Json -Depth 8
    $idBytes = [Text.Encoding]::UTF8.GetBytes($identify)
    [void]$ws.SendAsync([ArraySegment[byte]]::new($idBytes),[System.Net.WebSockets.WebSocketMessageType]::Text,$true,[Threading.CancellationToken]::None).Wait()

    # Heartbeat loop (op 1)
    $last = [DateTime]::UtcNow; $seq = $null
    while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
      if (([DateTime]::UtcNow - $last).TotalMilliseconds -ge $interval) {
        $hb = @{ op = 1; d = $seq } | ConvertTo-Json
        $hbBytes = [Text.Encoding]::UTF8.GetBytes($hb)
        [void]$ws.SendAsync([ArraySegment[byte]]::new($hbBytes),[System.Net.WebSockets.WebSocketMessageType]::Text,$true,[Threading.CancellationToken]::None).Wait()
        $last = [DateTime]::UtcNow
      }
      Start-Sleep -Milliseconds 200
    }
  }
  Try { Get-Job -Name "discord-presence" -ErrorAction Stop | Remove-Job -Force } Catch {}
  Start-Job -Name "discord-presence" -ScriptBlock $sb -ArgumentList $Token,$ActivityName,$Status | Out-Null
  Write-Host "Gateway presence job started (status: $Status, activity: $ActivityName)." -ForegroundColor Green
}
# Jeremy-Shockey baseline (sanity script)
# - Loads minimal env
# - Robust Get-NowET (works even if tz database is missing)
# - Sends a boot test post to CHAN_WEEKLY_MATCHUPS
# - Heartbeat loop (never null)

Write-Host ("BUILD STAMP: {0}" -f (Get-Date -Format s)) -ForegroundColor Magenta

# ===== ENV =====
$RequiredEnv = @('DISCORD_TOKEN','GUILD_ID','CHAN_WEEKLY_MATCHUPS')
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

# ===== TIME HELPERS (ET) =====
function Get-NowET {
  # Try Windows TZ, then IANA. If both fail (e.g., tzdata missing), approximate ET from UTC.
  try {
    $tz = $null
    try { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time") } catch {}
    if (-not $tz) { try { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("America/New_York") } catch {} }
    if ($tz) { return [System.TimeZoneInfo]::ConvertTime([DateTime]::UtcNow, $tz) }

    # Fallback: simple US DST rule (second Sun in Mar 02:00 through first Sun in Nov 02:00)
    $utc  = [DateTime]::UtcNow
    $year = $utc.Year

    function Get-NthWeekdayOfMonth([int]$y,[int]$m,[System.DayOfWeek]$dow,[int]$nth) {
      $d = Get-Date -Year $y -Month $m -Day 1 -Hour 2 -Minute 0 -Second 0 -Millisecond 0
      $offset = (([int]$dow - [int]$d.DayOfWeek + 7) % 7)
      $first  = $d.AddDays($offset)
      return $first.AddDays(7*($nth-1))
    }
    function Get-FirstWeekdayOfMonth([int]$y,[int]$m,[System.DayOfWeek]$dow) {
      Get-NthWeekdayOfMonth -y $y -m $m -dow $dow -nth 1
    }

    $dstStart   = Get-NthWeekdayOfMonth -y $year -m 3  -dow ([System.DayOfWeek]::Sunday) -nth 2
    $dstEnd     = Get-FirstWeekdayOfMonth -y $year -m 11 -dow ([System.DayOfWeek]::Sunday)
    $offsetHours = if ($utc -ge $dstStart -and $utc -lt $dstEnd) { -4 } else { -5 }
    return $utc.AddHours($offsetHours)
  } catch {
    return [DateTime]::UtcNow
  }
}

# ===== DISCORD =====
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

# ===== BOOT TEST =====
try {
  $bootMsg = ("Jeremy Shockey online at {0} (ET). Baseline test post." -f ((Get-NowET).ToString('yyyy-MM-dd HH:mm:ss')))
  $res = Send-DiscordMessage -ChannelId $CHAN_WEEKLY_MATCHUPS -Content $bootMsg
  if ($res) { Write-Host "Boot test posted to channel $CHAN_WEEKLY_MATCHUPS" -ForegroundColor Green }
  else { Write-Host "Boot test FAILED to post (check token/permissions/channel id)" -ForegroundColor Red }
} catch {
  Write-Host ("Boot test error: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

# ===== HEARTBEAT LOOP =====
$nextHeartbeat = ((Get-NowET) ?? (Get-Date)).AddMinutes(5)
Start-DiscordPresence -Token $DISCORD_TOKEN -ActivityName "ESPN Fantasy" -Status "online"
Write-Host "Jeremy Shockey baseline loop started." -ForegroundColor Cyan
while ($true) {
  $now = (Get-NowET)
  if (-not $nextHeartbeat) { $nextHeartbeat = ((Get-Date)).AddMinutes(5) }
  if ($now -ge $nextHeartbeat) {
    Write-Host ("Heartbeat: {0}" -f $now.ToString('s')) -ForegroundColor DarkCyan
    $nextHeartbeat = $nextHeartbeat.AddMinutes(5)
  }
  Start-Sleep -Seconds 1
}
# ===== DISCORD GATEWAY PRESENCE (online status) =====
 catch {}
    $ws  = [System.Net.WebSockets.ClientWebSocket]::new()
    $uri = [Uri]"wss://gateway.discord.gg/?v=10&encoding=json"

    # Connect to gateway
    $ws.ConnectAsync($uri,[Threading.CancellationToken]::None).Wait()

    # Receive HELLO (op 10)
    $buf = New-Object byte[] 8192
    $res = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf),[Threading.CancellationToken]::None).Result
    $txt = [Text.Encoding]::UTF8.GetString($buf,0,$res.Count)
    $hello = $null
    try { $hello = $txt | ConvertFrom-Json } catch {}
    $interval = if ($hello -and $hello.d -and $hello.d.heartbeat_interval) { [int]$hello.d.heartbeat_interval } else { 41250 } # ms

    # IDENTIFY (op 2) with presence
    $identify = @{
      op = 2
      d  = @{
        token      = $Token
        intents    = 0
        properties = @{ os="windows"; browser="powershell"; device="powershell" }
        presence   = @{
          status     = $Status
          activities = @(@{ name = $ActivityName; type = 0 })
          since      = $null
          afk        = $false
        }
      }
    } | ConvertTo-Json -Depth 8
    $idBytes = [Text.Encoding]::UTF8.GetBytes($identify)
    [void]$ws.SendAsync([ArraySegment[byte]]::new($idBytes),[System.Net.WebSockets.WebSocketMessageType]::Text,$true,[Threading.CancellationToken]::None).Wait()

    # Heartbeat loop (op 1). We don't need to read events for presence to remain online.
    $last = [DateTime]::UtcNow
    $seq  = $null
    while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
      if (([DateTime]::UtcNow - $last).TotalMilliseconds -ge $interval) {
        $hb = @{ op = 1; d = $seq } | ConvertTo-Json
        $hbBytes = [Text.Encoding]::UTF8.GetBytes($hb)
        [void]$ws.SendAsync([ArraySegment[byte]]::new($hbBytes),[System.Net.WebSockets.WebSocketMessageType]::Text,$true,[Threading.CancellationToken]::None).Wait()
        $last = [DateTime]::UtcNow
      }
      Start-Sleep -Milliseconds 200
    }
  }
  Try { Get-Job -Name "discord-presence" -ErrorAction Stop | Remove-Job -Force } Catch {}
  Start-Job -Name "discord-presence" -ScriptBlock $sb -ArgumentList $Token,$ActivityName,$Status | Out-Null
  Write-Host "Gateway presence job started (status: $Status, activity: $ActivityName)." -ForegroundColor Green
}




