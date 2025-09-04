<#
Jeremy-Shockey.ps1 — Discord Fantasy Football Bot (ESPN)

Features:
- Weekly Matchups (Wed 10:00 ET): Position Edges + Key Players + Change Log. Edits same post on lineup changes.
- Power Rankings (Tue 10:00 ET): Hybrid actuals+projections (SoS-adjusted) + Playoff Odds (top 6; regular season W1–W14).
- Transactions stream (near real-time).
- Set Lineup Reminder (Sun 10:00 ET).
- Stats & Records summary after championship final; stores last 10 seasons.

PowerShell 7.x; ASCII-only output to avoid encoding issues.
#>

Write-Host ("BUILD STAMP: {0}" -f (Get-Date -Format s)) -ForegroundColor Magenta

#############################
# Required Environment Vars #
#############################
$RequiredEnv = @(
  'DISCORD_TOKEN','SWID','ESPN_S2',
  'LEAGUE_ID','YEAR','GUILD_ID',
  'CHAN_WEEKLY_MATCHUPS','CHAN_POWER_RANKINGS','CHAN_TRANSACTIONS',
  'CHAN_SET_LINEUP','CHAN_STATS_RECORDS'
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

# locals
$DISCORD_TOKEN        = $env:DISCORD_TOKEN
$SWID                 = $env:SWID
$ESPN_S2              = $env:ESPN_S2
$LEAGUE_ID            = $env:LEAGUE_ID
$YEAR                 = [int]$env:YEAR
$GUILD_ID             = $env:GUILD_ID
$CHAN_WEEKLY_MATCHUPS = $env:CHAN_WEEKLY_MATCHUPS
$CHAN_POWER_RANKINGS  = $env:CHAN_POWER_RANKINGS
$CHAN_TRANSACTIONS    = $env:CHAN_TRANSACTIONS
$CHAN_SET_LINEUP      = $env:CHAN_SET_LINEUP
$CHAN_STATS_RECORDS   = $env:CHAN_STATS_RECORDS

########################
# Schedules / Settings #
########################
$Poll_Lineups_Seconds      = 120
$Poll_Transactions_Seconds = 45
$Poll_Boxscores_Minutes    = 30
$Poll_Records_Minutes      = 60

$PLAYOFF_TEAMS   = 6
$REG_SEASON_LAST = 14
$SIMS            = 4000
$K_LOGIT         = 0.065
$SIGMA_POINTS    = 12.0

###########
# Storage #
###########
$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$StateDir = Join-Path $scriptRoot 'state'
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

$F_MatchupsMsg    = Join-Path $StateDir 'weekly_matchups_message.json'
$F_RankingsMsg    = Join-Path $StateDir 'power_rankings_message.json'
$F_LastRosters    = Join-Path $StateDir 'last_rosters.json'
$F_LastTx         = Join-Path $StateDir 'last_transactions.json'
$F_BoxWeekly      = Join-Path $StateDir 'weekly_boxscores.json'
$F_RecordsHistory = Join-Path $StateDir 'records_history.json'
$F_RecordsMsg     = Join-Path $StateDir 'stats_records_message.json'

###############
# Time (ET)   #
###############
function Get-NowET {
  try { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time') }
  catch { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById('America/New_York') }
  [System.TimeZoneInfo]::ConvertTime([DateTime]::UtcNow, $tz)
}
function Next-Weekly($dayOfWeek, $hour, $minute) {
  $now = Get-NowET
  $target = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour $hour -Minute $minute -Second 0
  while ($target.DayOfWeek -ne $dayOfWeek -or $target -le $now) { $target = $target.AddDays(1) }
  $target
}

#################
# Discord API   #
#################
$DiscordApi = 'https://discord.com/api/v10'
function Invoke-Discord {
  param([ValidateSet('GET','POST','PATCH')][string]$Method,[string]$Path,[object]$Body=$null)
  $headers = @{ 'Authorization'="Bot $DISCORD_TOKEN"; 'Content-Type'='application/json' }
  $uri = "$DiscordApi$Path"
  try {
    if ($Body) {
      $json = $Body | ConvertTo-Json -Depth 8
      $res = Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -Body $json
    } else {
      $res = Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
    }
    Start-Sleep -Milliseconds 900
    return $res
  } catch { Write-Host ("Discord {0} {1} failed: {2}" -f $Method,$Path,$_.Exception.Message) -ForegroundColor Yellow; return $null }
}
function Send-DiscordMessage { param([string]$ChannelId,[string]$Content) Invoke-Discord -Method 'POST' -Path "/channels/$ChannelId/messages" -Body @{ content=$Content } }
function Edit-DiscordMessage { param([string]$ChannelId,[string]$MessageId,[string]$Content) Invoke-Discord -Method 'PATCH' -Path "/channels/$ChannelId/messages/$MessageId" -Body @{ content=$Content } }

############
# ESPN API #
############
function Invoke-ESPN { param([string]$Views='mSettings,mTeam,mRoster,mMatchupScore,mPendingTransactions')
  $base="https://lm-api-reads.fantasy.espn.com/apis/v3/games/ffl/seasons/$YEAR/segments/0/leagues/$LEAGUE_ID"
  $cookie="espn_s2=$ESPN_S2; SWID=$SWID"
  $url="$base?view=$($Views -split ',' -join '&view=')"
  try { Invoke-RestMethod -Method GET -Uri $url -Headers @{ 'Cookie'=$cookie } -TimeoutSec 30 }
  catch { Write-Host ("ESPN call failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow; return $null }
}
function Get-CurrentWeek { $d=Invoke-ESPN -Views 'mSettings'; if (-not $d){return 1}; try{ [int]$d.status.currentMatchupPeriod }catch{1} }

function Get-TeamsMap {
  $d=Invoke-ESPN -Views 'mTeam'
  $teams=@{}
  foreach ($t in $d.teams) {
    $nm = if ($t.location -or $t.nickname) { "$($t.location) $($t.nickname)" } else { "Team $($t.id)" }
    $rec = if ($t.record -and $t.record.overall) { "$($t.record.overall.wins)-$($t.record.overall.losses)" } else { "" }
    $pf = if ($t.record -and $t.record.overall) { [double]$t.record.overall.pointsFor } else { 0.0 }
    $teams[$t.id] = @{ name=$nm; abbrev=$t.abbrev; record=$rec; pointsFor=$pf }
  }
  $teams
}
function Get-Matchups { param([int]$Week)
  $d=Invoke-ESPN -Views 'mMatchupScore,mTeam'
  $out=@()
  foreach ($m in $d.schedule) {
    if ($m.matchupPeriodId -ne $Week) { continue }
    $out += [pscustomobject]@{
      homeId   = $m.home.teamId
      awayId   = $m.away.teamId
      homeProj = [double]$m.home.totalPointsProjected
      awayProj = [double]$m.away.totalPointsProjected
      homePts  = [double]$m.home.totalPoints
      awayPts  = [double]$m.away.totalPoints
      status   = $m.status
    }
  }
  $out
}
function Get-StartersByTeam {
  $d=Invoke-ESPN -Views 'mRoster,mTeam'
  $map=@{}
  foreach ($t in $d.teams) {
    $starters=@()
    foreach ($e in $t.roster.entries) {
      if ($e.lineupSlotId -lt 20) {
        $p=$e.playerPoolEntry.player
        $starters += @{
          playerId     = $p.id
          playerName   = ($p.fullName ?? $p.name)
          lineupSlotId = $e.lineupSlotId
          defaultPosId = $p.defaultPositionId
        }
      }
    }
    $map[$t.id]=$starters
  }
  $map
}
function Get-ProjectedStartersByTeam { param([int]$Week)
  $d=Invoke-ESPN -Views 'mRoster,mTeam'
  $ProjSource=1
  $byTeam=@{}
  foreach ($t in $d.teams) {
    $starters=@()
    foreach ($e in $t.roster.entries) {
      if ($e.lineupSlotId -ge 20) { continue }
      $p=$e.playerPoolEntry.player
      $proj=0.0
      if ($p.stats) {
        foreach ($s in $p.stats) {
          if ($s.scoringPeriodId -eq $Week -and $s.statSourceId -eq $ProjSource -and $s.appliedTotal -ne $null) { $proj=[double]$s.appliedTotal; break }
        }
      }
      $starters += @{
        playerId     = $p.id
        playerName   = ($p.fullName ?? $p.name)
        lineupSlotId = $e.lineupSlotId
        proj         = $proj
      }
    }
    $byTeam[$t.id]=$starters
  }
  $byTeam
}
function Get-LineupSlotName([int]$slotId) {
  switch ($slotId) {
    0{'QB'}2{'RB'}3{'RB/WR'}4{'WR'}5{'WR/TE'}6{'TE'}7{'OP'}16{'D/ST'}17{'K'}22{'FLEX'} default {"SLOT$slotId"}
  }
}
function Map-SlotToBucket([string]$slotName) {
  switch ($slotName) { 'RB/WR'{'FLEX'} 'WR/TE'{'FLEX'} 'OP'{'FLEX'} default{$slotName} }
}

##############################
# Position Edges / Key Plays #
##############################
function Summarize-PositionEdges { param($projStartersByTeam,$homeId,$awayId)
  $bucketOrder=@('QB','RB','WR','TE','FLEX','K','D/ST')
  $home=@{}; $away=@{}; foreach ($b in $bucketOrder) { $home[$b]=0.0; $away[$b]=0.0 }
  foreach ($s in $projStartersByTeam[$homeId]) { $b=Map-SlotToBucket (Get-LineupSlotName $s.lineupSlotId); if ($b -in $bucketOrder){ $home[$b]+=$s.proj } }
  foreach ($s in $projStartersByTeam[$awayId]) { $b=Map-SlotToBucket (Get-LineupSlotName $s.lineupSlotId); if ($b -in $bucketOrder){ $away[$b]+=$s.proj } }
  $edges=@(); foreach ($b in $bucketOrder){ $edges += [pscustomobject]@{ bucket=$b; delta=[math]::Round(($home[$b]-$away[$b]),1); home=[math]::Round($home[$b],1); away=[math]::Round($away[$b],1) } }
  $edges
}
function Get-KeyPlayers { param($projStartersByTeam,$teamId,[int]$take=2)
  $projStartersByTeam[$teamId] | Sort-Object -Property @{Expression='proj';Descending=$true} | Select-Object -First $take
}

#########
# Utils #
#########
function Hash-Text($text) {
  $bytes=[System.Text.Encoding]::UTF8.GetBytes($text)
  $sha=[System.Security.Cryptography.SHA256]::Create()
  $hash=$sha.ComputeHash($bytes)
  ([System.BitConverter]::ToString($hash) -replace '-','').ToLower()
}

#####################################
# Weekly Top Players (boxscore scan)#
#####################################
function Load-WeeklyBox(){ if (Test-Path $F_BoxWeekly){ Get-Content $F_BoxWeekly | ConvertFrom-Json } else { @{} } }
function Save-WeeklyBox($obj){ $obj | ConvertTo-Json -Depth 6 | Set-Content $F_BoxWeekly }
function Update-WeeklyTopPlayers { param([int]$WeekMax=14)
  $data=Invoke-ESPN -Views 'mRoster,mTeam'
  if (-not $data){ return }
  $mapTeam=@{}; foreach($t in $data.teams){ $mapTeam[$t.id]= if($t.location -or $t.nickname){"$($t.location) $($t.nickname)"}else{"Team $($t.id)"} }
  $year=$YEAR; $box=Load-WeeklyBox; if (-not $box.ContainsKey("$year")){ $box["$year"]=@{} }
  for ($w=1; $w -le $WeekMax; $w++){
    $best=$null
    foreach ($t in $data.teams){
      foreach ($e in $t.roster.entries){
        $p=$e.playerPoolEntry.player
        if (-not $p.stats){ continue }
        foreach ($s in $p.stats){
          if ($s.scoringPeriodId -ne $w -or $s.statSourceId -ne 0 -or $null -eq $s.appliedTotal){ continue }
          $pts=[double]$s.appliedTotal
          if (-not $best -or $pts -gt $best.pts){ $best=@{ player=($p.fullName ?? $p.name); team=$mapTeam[$t.id]; pts=[math]::Round($pts,1); week=$w } }
        }
      }
    }
    if ($best){ $box["$year"]["$w"]=$best }
  }
  Save-WeeklyBox -obj $box
}

#########################################
# Hybrid Points / SoS / Power Rankings  #
#########################################
function Get-WeekHybridPointsMap { param([int]$Week)
  $d=Invoke-ESPN -Views 'mMatchupScore,mTeam'
  $teams=@{}; foreach ($t in $d.teams){ $teams[$t.id]=@{ name= if($t.location -or $t.nickname){"$($t.location) $($t.nickname)"}else{"Team $($t.id)"} } }
  $perTeam=@{}; foreach ($tid in $teams.Keys){ $perTeam[$tid]=@{} }
  foreach ($m in $d.schedule){
    if ($m.matchupPeriodId -ne $Week){ continue }
    $home=@{ actual=[double]$m.home.totalPoints; proj=[double]$m.home.totalPointsProjected }
    $away=@{ actual=[double]$m.away.totalPoints; proj=[double]$m.away.totalPointsProjected }
    $isFinal = ($m.status -eq 'final') -or ($home.actual -gt 0 -or $away.actual -gt 0)
    $perTeam[$m.home.teamId][$Week]=@{ final=$isFinal; points= (if($isFinal){$home.actual}else{$home.proj}) }
    $perTeam[$m.away.teamId][$Week]=@{ final=$isFinal; points= (if($isFinal){$away.actual}else{$away.proj}) }
  }
  @{ Teams=$teams; Weeks=$perTeam }
}
function Get-CumulativeHybridPointsThroughWeek { param([int]$CurrentWeek)
  $d=Invoke-ESPN -Views 'mMatchupScore,mTeam'
  $teams=@{}; foreach ($t in $d.teams){ $teams[$t.id]=@{ name= if($t.location -or $t.nickname){"$($t.location) $($t.nickname)"}else{"Team $($t.id)"}; record= if($t.record.overall){"$($t.record.overall.wins)-$($t.record.overall.losses)"}else{""} } }
  $opps=@{}; foreach ($tid in $teams.Keys){ $opps[$tid]=@() }
  $cum=@{};  foreach ($tid in $teams.Keys){ $cum[$tid]=0.0 }
  for ($w=1; $w -le $CurrentWeek; $w++){
    $hyb=Get-WeekHybridPointsMap -Week $w
    foreach ($m in $d.schedule){ if ($m.matchupPeriodId -ne $w){ continue } $h=$m.home.teamId; $a=$m.away.teamId; $opps[$h]+=$a; $opps[$a]+=$h }
    foreach ($tid in $teams.Keys){
      if ($hyb.Weeks.ContainsKey($tid) -and $hyb.Weeks[$tid].ContainsKey($w)){ $cum[$tid]+=[double]$hyb.Weeks[$tid][$w].points }
    }
  }
  @{ points=$cum; teams=$teams; schedule=$opps }
}
function Compute-PowerScores { param([int]$CurrentWeek,[double]$CumWeight=0.7,[double]$SosWeight=0.3)
  $res=Get-CumulativeHybridPointsThroughWeek -CurrentWeek $CurrentWeek
  $cum=$res.points; $teams=$res.teams; $opps=$res.schedule
  $oppStrength=@{}
  foreach ($tid in $teams.Keys){
    $list=$opps[$tid]; if ($list.Count -gt 0){
      $vals=@(); foreach ($oid in $list){ if ($cum.ContainsKey($oid)){ $vals+=[double]$cum[$oid] } }
      if ($vals.Count -gt 0){ $oppStrength[$tid]=($vals | Measure-Object -Average).Average } else { $oppStrength[$tid]=0.0 }
    } else { $oppStrength[$tid]=0.0 }
  }
  function Get-ZMap($map){
    $vals=$map.Values | ForEach-Object{ [double]$_ }
    $avg=($vals | Measure-Object -Average).Average
    $std=[Math]::Sqrt( ($vals | ForEach-Object { ($_ - $avg)*($_ - $avg) } | Measure-Object -Sum).Sum / [Math]::Max(1,$vals.Count) )
    if ($std -eq 0){ $z=@{}; foreach ($k in $map.Keys){ $z[$k]=0.0 }; return $z }
    $z2=@{}; foreach ($k in $map.Keys){ $z2[$k]=([double]$map[$k]-$avg)/$std }; $z2
  }
  $zCum=Get-ZMap $cum; $zOpps=Get-ZMap $oppStrength
  $scores=@{}; foreach ($tid in $teams.Keys){ $scores[$tid]=($CumWeight*$zCum[$tid]) + ($SosWeight*$zOpps[$tid]) }
  @{ scores=$scores; cum=$cum; opp=$oppStrength; teams=$teams; weights=@{cum=$CumWeight;sos=$SosWeight} }
}

########################
# Playoff Odds (Monte) #
########################
function Get-CurrentWinsMap {
  $d=Invoke-ESPN -Views 'mTeam'
  $wins=@{}; foreach ($t in $d.teams){ $w=0; if ($t.record -and $t.record.overall){ $w=[int]$t.record.overall.wins }; $wins[$t.id]=$w }; $wins
}
function Get-CumPointsSoFar {
  $wk=Get-CurrentWeek
  (Get-CumulativeHybridPointsThroughWeek -CurrentWeek $wk).points
}
function Get-RemainingScheduleWithProjections {
  $current=Get-CurrentWeek
  $d=Invoke-ESPN -Views 'mMatchupScore,mTeam'
  $games=@()
  foreach ($m in $d.schedule){
    if ($m.matchupPeriodId -lt $current){ continue }
    if ($m.matchupPeriodId -gt $REG_SEASON_LAST){ continue }
    $games += @{
      week=[int]$m.matchupPeriodId
      homeId=[int]$m.home.teamId
      awayId=[int]$m.away.teamId
      projHome=[double]$m.home.totalPointsProjected
      projAway=[double]$m.away.totalPointsProjected
      status=$m.status
      actualH=[double]$m.home.totalPoints
      actualA=[double]$m.away.totalPoints
    }
  }
  $games
}
function Rand-Normal { param([double]$mean,[double]$std)
  if ($std -le 0) { return $mean }
  $u1=(Get-Random -Minimum 1 -Maximum 10000)/10000.0
  $u2=(Get-Random -Minimum 1 -Maximum 10000)/10000.0
  $z=[math]::Sqrt(-2.0*[math]::Log($u1))*[math]::Cos(2.0*[math]::PI*$u2)
  $mean + $std*$z
}
function Simulate-PlayoffOdds {
  $teamsMap = Get-TeamsMap
  $winsNow  = Get-CurrentWinsMap
  $ptsNow   = Get-CumPointsSoFar
  $games    = Get-RemainingScheduleWithProjections
  $current  = Get-CurrentWeek

  # fold finals
  $pending=@()
  foreach ($g in $games) {
    if ($g.week -lt $current) { continue }
    $isFinal = ($g.status -eq 'final') -or ($g.actualH -gt 0 -or $g.actualA -gt 0)
    if ($isFinal) {
      if (-not $ptsNow.ContainsKey($g.homeId)) { $ptsNow[$g.homeId]=0.0 }
      if (-not $ptsNow.ContainsKey($g.awayId)) { $ptsNow[$g.awayId]=0.0 }
      $ptsNow[$g.homeId]+=[double]$g.actualH
      $ptsNow[$g.awayId]+=[double]$g.actualA
      if ($g.actualH -gt $g.actualA) { $winsNow[$g.homeId]++ } elseif ($g.actualA -gt $g.actualH){ $winsNow[$g.awayId]++ }
    } else { $pending += $g }
  }

  # setup
  $teams=@(); $hits=@{}
  foreach ($tid in $teamsMap.Keys){ $tid=[int]$tid; $teams+=$tid; if (-not $winsNow.ContainsKey($tid)){$winsNow[$tid]=0}; if (-not $ptsNow.ContainsKey($tid)){$ptsNow[$tid]=0.0}; $hits[$tid]=0 }

  for ($s=1; $s -le $SIMS; $s++) {
    $w=@{}; $p=@{}; foreach ($tid in $teams){ $w[$tid]=[int]$winsNow[$tid]; $p[$tid]=[double]$ptsNow[$tid] }
    foreach ($g in $pending) {
      $simH=Rand-Normal -mean $g.projHome -std $SIGMA_POINTS
      $simA=Rand-Normal -mean $g.projAway -std $SIGMA_POINTS
      $p[$g.homeId]+=$simH; $p[$g.awayId]+=$simA
      $edge=[double]$g.projHome - [double]$g.projAway
      $probHome=1.0/(1.0+[math]::Exp(-$K_LOGIT*$edge))
      $flip=(Get-Random -Minimum 0 -Maximum 10000)/10000.0
      if ($flip -le $probHome){ $w[$g.homeId]++ } else { $w[$g.awayId]++ }
    }

    $rows = foreach ($tid in $teams) {
      [pscustomobject]@{ teamId=$tid; wins=[int]$w[$tid]; points=[double]$p[$tid] }
    }
    $final = $rows | Sort-Object `
      -Property @{Expression='wins';Descending=$true},
                @{Expression='points';Descending=$true},
                @{Expression='teamId';Descending=$false}

    $i=0; foreach ($row in $final){ if ($i -lt $PLAYOFF_TEAMS){ $hits[$row.teamId]++ }; $i++ }
  }

  $odds=@{}; foreach ($tid in $teams){ $odds[$tid]=[math]::Round(100.0*$hits[$tid]/$SIMS,1) }
  $table = foreach ($tid in $teams) { [pscustomobject]@{ teamId=$tid; team=$teamsMap[$tid].name; oddsPct=$odds[$tid] } }
  $table = $table | Sort-Object -Property @{Expression='oddsPct';Descending=$true}, @{Expression='team';Descending=$false}
  @{ odds=$odds; table=$table }
}

##################################
# Message Builders / Post Flows  #
##################################
function Build-Matchups-Content { param([int]$Week,$TeamsMap,$Matchups,$ChangeLogLines,$ProjStarters)
  $BIG=5.0
  $lines=@()
  $lines += ("WEEK {0} MATCHUPS" -f $Week)
  $lines += "Auto-updates on lineup changes"
  $lines += ""

  foreach ($m in $Matchups){
    $home=$TeamsMap[$m.homeId].name; $away=$TeamsMap[$m.awayId].name
    $lines += ("- {0} at {1}" -f $away,$home)
    if ($m.homeProj -or $m.awayProj){ $lines += ("    Proj: {0:N1} - {1:N1}" -f $m.homeProj,$m.awayProj) }
    if ($m.homePts -or $m.awayPts){   $lines += ("    Score: {0:N1} - {1:N1}" -f $m.homePts,$m.awayPts) }

    if ($ProjStarters.ContainsKey($m.homeId) -and $ProjStarters.ContainsKey($m.awayId)){
      $edges = Summarize-PositionEdges -projStartersByTeam $ProjStarters -homeId $m.homeId -awayId $m.awayId
      if ($edges.Count){
        $lines += ""
        $lines += "    Position Edges (Proj)"
        $lines += "    Legend: [BIG] = edge >= 5.0; [ADV] = advantage; [TIE] = tie"

        $edgeParts=@()
        $homeBig = New-Object System.Collections.Generic.HashSet[string]
        $awayBig = New-Object System.Collections.Generic.HashSet[string]

        foreach ($e in $edges){
          if ($e.home -eq 0 -and $e.away -eq 0){ $edgeParts += ("{0}: -" -f $e.bucket); continue }
          $abs=[math]::Abs($e.delta); $isBig=($abs -ge $BIG)
          if ($e.delta -gt 0){
            if ($isBig){ $null=$homeBig.Add($e.bucket); $edgeParts += ("{0}: [BIG] {1} +{2}" -f $e.bucket,$home,$abs) }
            else { $edgeParts += ("{0}: [ADV] {1} +{2}" -f $e.bucket,$home,$abs) }
          } elseif ($e.delta -lt 0){
            if ($isBig){ $null=$awayBig.Add($e.bucket); $edgeParts += ("{0}: [BIG] {1} +{2}" -f $e.bucket,$away,$abs) }
            else { $edgeParts += ("{0}: [ADV] {1} +{2}" -f $e.bucket,$away,$abs) }
          } else { $edgeParts += ("{0}: [TIE]" -f $e.bucket) }
        }
        $lines += "    " + ($edgeParts -join "   ")

        $homeKeys = Get-KeyPlayers -projStartersByTeam $ProjStarters -teamId $m.homeId -take 2
        $awayKeys = Get-KeyPlayers -projStartersByTeam $ProjStarters -teamId $m.awayId -take 2

        function Render-KeyLine($teamName,$keys,$bigBuckets){
          $pieces=@()
          foreach($k in $keys){
            $bucket=Map-SlotToBucket (Get-LineupSlotName $k.lineupSlotId)
            $isBig=$bigBuckets.Contains($bucket)
            $score = ("{0:N1}" -f $k.proj)
            if($isBig){ $pieces += ("[BIG]* {0} {1}" -f $k.playerName,$score) }
            else { $pieces += ("* {0} {1}" -f $k.playerName,$score) }
          }
          ("    {0}: {1}" -f $teamName, ($pieces -join ', '))
        }

        $lines += ""
        $lines += "    Key Players (Proj)"
        $lines += (Render-KeyLine -teamName $home -keys $homeKeys -bigBuckets $homeBig)
        $lines += (Render-KeyLine -teamName $away -keys $awayKeys -bigBuckets $awayBig)
      }
    }
    $lines += ""
  }

  if ($ChangeLogLines -and $ChangeLogLines.Count){
    $lines += "Change Log (Starters Updates)"
    foreach ($cl in $ChangeLogLines){ $lines += $cl }
  }
  ($lines -join "`n")
}

function Ensure-WeeklyMatchups {
  $week=Get-CurrentWeek; if (-not $week){ return }
  $teams=Get-TeamsMap; $matchups=Get-Matchups -Week $week

  $lastR= if (Test-Path $F_LastRosters){ Get-Content $F_LastRosters | ConvertFrom-Json } else { @{} }
  $currR= Get-StartersByTeam
  $changes=@()
  foreach ($teamId in $currR.Keys){
    $old=@(); if ($lastR.ContainsKey($teamId)){ $old=$lastR[$teamId] } else { $old=@() }
    $new=$currR[$teamId]
    $oldNames=$old | ForEach-Object{ $_.playerName }; $newNames=$new | ForEach-Object{ $_.playerName }
    $promoted=$newNames | Where-Object{ $_ -notin $oldNames }
    $demoted =$oldNames | Where-Object{ $_ -notin $newNames }
    $slotChanges=@()
    foreach ($name in ($newNames | Where-Object{ $_ -in $oldNames })){
      $o=($old | Where-Object{ $_.playerName -eq $name })[0]
      $n=($new | Where-Object{ $_.playerName -eq $name })[0]
      if ($o.lineupSlotId -ne $n.lineupSlotId){ $slotChanges += ("{0} ({1} -> {2})" -f $name,$o.lineupSlotId,$n.lineupSlotId) }
    }
    if ($promoted.Count -or $demoted.Count -or $slotChanges.Count){
      $changes += [pscustomobject]@{ teamId=[int]$teamId; promoted=$promoted; demoted=$demoted; slotChanges=$slotChanges }
    }
  }
  $changeLines=@()
  foreach ($c in $changes){
    $teamName=$teams[$c.teamId].name
    if ($c.promoted.Count){ $changeLines += ("UP   {0} promoted: {1}" -f $teamName, ($c.promoted -join ', ')) }
    if ($c.demoted.Count){  $changeLines += ("DOWN {0} benched:  {1}" -f $teamName, ($c.demoted  -join ', ')) }
    if ($c.slotChanges.Count){ $changeLines += ("SWAP {0} slot changes: {1}" -f $teamName, ($c.slotChanges -join ', ')) }
  }

  $projStarters = Get-ProjectedStartersByTeam -Week $week
  $content = Build-Matchups-Content -Week $week -TeamsMap $teams -Matchups $matchups -ChangeLogLines $changeLines -ProjStarters $projStarters
  $hash = Hash-Text $content

  $msgState = if (Test-Path $F_MatchupsMsg){ Get-Content $F_MatchupsMsg | ConvertFrom-Json } else { $null }
  $chan=$CHAN_WEEKLY_MATCHUPS
  if (-not $msgState -or $msgState.week -ne $week -or -not $msgState.message_id){
    $res=Send-DiscordMessage -ChannelId $chan -Content $content
    if ($res){ @{week=$week;message_id=$res.id;content_hash=$hash} | ConvertTo-Json | Set-Content $F_MatchupsMsg }
  } else {
    if ($msgState.content_hash -ne $hash){
      $null=Edit-DiscordMessage -ChannelId $chan -MessageId $msgState.message_id -Content $content
      @{week=$week;message_id=$msgState.message_id;content_hash=$hash} | ConvertTo-Json | Set-Content $F_MatchupsMsg
    }
  }
  $currR | ConvertTo-Json -Depth 6 | Set-Content $F_LastRosters
}

function Ensure-PowerRankings {
  $WEIGHT_CUM=0.7; $WEIGHT_SOS=0.3
  $week=Get-CurrentWeek; if (-not $week){ return }
  $calc=Compute-PowerScores -CurrentWeek $week -CumWeight $WEIGHT_CUM -SosWeight $WEIGHT_SOS
  $scores=$calc.scores; $cum=$calc.cum; $opp=$calc.opp; $teams=$calc.teams
  $sim=Simulate-PlayoffOdds; $odds=$sim.odds

  $rows=@()
  foreach ($tid in $teams.Keys){
    $rec=$teams[$tid].record
    $rows += [pscustomobject]@{
      teamId=$tid; name=$teams[$tid].name; record=$rec;
      wins=[int](($rec -split '-' | Select-Object -First 1) ?? 0);
      cum=[double]$cum[$tid]; sos=[double]$opp[$tid]; score=[double]$scores[$tid];
      odds=[double](if($odds.ContainsKey($tid)){$odds[$tid]}else{0.0})
    }
  }
  $ordered = $rows | Sort-Object -Property @{Expression='score';Descending=$true}, @{Expression='wins';Descending=$true}, @{Expression='name';Descending=$false}

  $lines=@()
  $lines += ("POWER RANKINGS — Week {0}" -f $week)
  $lines += ("Formula: Score = z(CumPts)*{0:N1} + z(SoS)*{1:N1}. CumPts uses actuals for finished weeks and projections for current." -f $WEIGHT_CUM,$WEIGHT_SOS)
  $lines += ("Playoff Odds via {0} sims (top {1}; reg W1–W{2})." -f $SIMS,$PLAYOFF_TEAMS,$REG_SEASON_LAST)
  $i=1; foreach ($t in $ordered){
    $lines += ("{0}. {1} — Score {2:N2} | CumPts {3:N1} | SoS {4:N1} | Playoff Odds {5:N1}% ({6})" -f $i,$t.name,$t.score,$t.cum,$t.sos,$t.odds,($t.record ?? ''))
    $i++
  }
  $content=($lines -join "`n"); $hash=Hash-Text $content

  $msgState = if (Test-Path $F_RankingsMsg){ Get-Content $F_RankingsMsg | ConvertFrom-Json } else { $null }
  $chan=$CHAN_POWER_RANKINGS
  if (-not $msgState -or $msgState.week -ne $week -or -not $msgState.message_id){
    $res=Send-DiscordMessage -ChannelId $chan -Content $content
    if ($res){ @{week=$week;message_id=$res.id;content_hash=$hash} | ConvertTo-Json | Set-Content $F_RankingsMsg }
  } else {
    if ($msgState.content_hash -ne $hash){
      $null=Edit-DiscordMessage -ChannelId $chan -MessageId $msgState.message_id -Content $content
      @{week=$week;message_id=$msgState.message_id;content_hash=$hash} | ConvertTo-Json | Set-Content $F_RankingsMsg
    }
  }
}

function Tick-Transactions {
  $d=Invoke-ESPN -Views 'mPendingTransactions,mTeam'; if (-not $d){ return }
  $teams=Get-TeamsMap
  $seen=@{}; if (Test-Path $F_LastTx){ $seen=(Get-Content $F_LastTx | ConvertFrom-Json) }
  if (-not $seen){ $seen=@{} }
  $chan=$CHAN_TRANSACTIONS

  foreach ($tx in $d.transactions){
    $id="$($tx.id)"; if ($seen.ContainsKey($id)){ continue }
    $teamName = if ($tx.teamId -and $teams.ContainsKey($tx.teamId)){ $teams[$tx.teamId].name } else { "Team $($tx.teamId)" }
    $type=$tx.type
    $lines=@("{0} — {1}" -f $type,$teamName)
    if ($tx.items){
      foreach ($it in $tx.items){
        $player=$null; if ($it.playerPoolEntry -and $it.playerPoolEntry.player){ $player=$it.playerPoolEntry.player.fullName }
        $desc = switch ($type) {
          'ADD'   { "Added: $player" }
          'DROP'  { "Dropped: $player" }
          'MOVE'  { "Moved: $player ($($it.fromLineupSlotId) -> $($it.toLineupSlotId))" }
          'TRADE' { "Traded: $player" }
          default { "Player: $player" }
        }
        $lines += ("- {0}" -f $desc)
      }
    }
    $content=($lines -join "`n"); $null=Send-DiscordMessage -ChannelId $chan -Content $content
    $seen[$id]=(Get-NowET).ToString("s")
  }
  $seen | ConvertTo-Json | Set-Content $F_LastTx
}

function Post-SetLineupReminder {
  $chan=$CHAN_SET_LINEUP; $week=Get-CurrentWeek
  $msg = @("Set Your Lineup!",("Reminder: lock in starters for Week {0}." -f $week),"Check injuries/byes","Verify QB/RB/WR/TE/FLEX","Do not forget K/DST") -join "`n"
  $null=Send-DiscordMessage -ChannelId $chan -Content $msg
}

#########################################
# Stats & Records (on championship end) #
#########################################
function Is-ChampionshipFinal {
  $d=Invoke-ESPN -Views 'mMatchupScore,mTeam'; if (-not $d){ return $false }
  $mx=-1; $champ=$null
  foreach ($m in $d.schedule){ if ($m.matchupPeriodId -lt 15){ continue }; if ($m.matchupPeriodId -gt $mx){ $mx=$m.matchupPeriodId; $champ=$m } }
  if (-not $champ){ return $false }
  $h=[double]$champ.home.totalPoints; $a=[double]$champ.away.totalPoints
  ($champ.status -eq 'final') -or ($h -gt 0 -or $a -gt 0)
}
function Get-SeasonSummary {
  $d=Invoke-ESPN -Views 'mMatchupScore,mTeam'; if (-not $d){ return $null }
  $teams=@{}; foreach ($t in $d.teams){
    $nm= if ($t.location -or $t.nickname){"$($t.location) $($t.nickname)"}else{"Team $($t.id)"}
    $pf=0.0; $rec=""; if ($t.record -and $t.record.overall){ $pf=[double]$t.record.overall.pointsFor; $rec="$($t.record.overall.wins)-$($t.record.overall.losses)-$($t.record.overall.ties)" }
    $teams[$t.id]=@{ name=$nm; pf=$pf; rec=$rec }
  }
  $mx=-1; $champ=$null; foreach ($m in $d.schedule){ if ($m.matchupPeriodId -lt 15){ continue }; if ($m.matchupPeriodId -gt $mx){ $mx=$m.matchupPeriodId; $champ=$m } }
  $champTeamId=$null; if ($champ){ $h=[double]$champ.home.totalPoints; $a=[double]$champ.away.totalPoints; $champTeamId= if ($h -ge $a){ $champ.home.teamId } else { $champ.away.teamId } }

  $bestPF = ($teams.GetEnumerator() | Sort-Object { $_.Value.pf } -Descending | Select-Object -First 1)
  $bestRec = ($teams.GetEnumerator() | ForEach-Object {
    $w,$l,$t = ($_.Value.rec -split '-') + 0
    [pscustomobject]@{ teamId=$_.Key; name=$_.Value.name; wins=[int]$w; losses=[int]$l; pf=[double]$_.Value.pf; rec=$_.Value.rec }
  } | Sort-Object -Property @{Expression='wins';Descending=$true}, @{Expression='losses';Descending=$false}, @{Expression='pf';Descending=$true} | Select-Object -First 1)

  $topTeamWeek=$null
  foreach ($m in $d.schedule){
    $wk=[int]$m.matchupPeriodId; $h=[double]$m.home.totalPoints; $a=[double]$m.away.totalPoints
    if ($h -gt 0 -or $a -gt 0){
      if (-not $topTeamWeek -or $h -gt $topTeamWeek.points){ $topTeamWeek=@{ teamId=$m.home.teamId; points=$h; week=$wk } }
      if (-not $topTeamWeek -or $a -gt $topTeamWeek.points){ $topTeamWeek=@{ teamId=$m.away.teamId; points=$a; week=$wk } }
    }
  }

  $year=$YEAR; $box=Load-WeeklyBox; $bestPlayer=$null
  if ($box.ContainsKey("$year")){ foreach ($wk in $box["$year"].Keys){ $entry=$box["$year"]["$wk"]; if (-not $bestPlayer -or [double]$entry.pts -gt [double]$bestPlayer.pts){ $bestPlayer=$entry } } }
  $tpText = if ($bestPlayer){ ("{0} ({1}) — {2} (W{3})" -f $bestPlayer.player,$bestPlayer.team,$bestPlayer.pts,$bestPlayer.week) } else { "N/A" }

  @{
    champion = if ($champTeamId){ @{ team=$teams[$champTeamId].name } } else { $null }
    bestPF   = @{ team=$bestPF.Value.name; pf=[math]::Round($bestPF.Value.pf,0) }
    bestRec  = @{ team=$bestRec.name; rec=$bestRec.rec }
    topTeam  = if ($topTeamWeek){ @{ team=$teams[$topTeamWeek.teamId].name; pts=[math]::Round($topTeamWeek.points,1); week=$topTeamWeek.week } } else { $null }
    topPlayer= @{ text=$tpText }
  }
}
function Load-RecordsHistory { if (Test-Path $F_RecordsHistory){ Get-Content $F_RecordsHistory | ConvertFrom-Json } else { @() } }
function Save-RecordsHistory($hist){ $hist | ConvertTo-Json -Depth 6 | Set-Content $F_RecordsHistory }
function Build-RecordsMessage { param($history)
  $lines=@(); $lines += "STATS & RECORDS (Last 10 Seasons)"; $lines += ""
  foreach ($s in $history){
    $lines += ("{0}" -f $s.season)
    if ($s.champion){ $lines += ("Champion: {0}" -f $s.champion.team) }
    if ($s.bestPF){   $lines += ("Best PF (season): {0} — {1}" -f $s.bestPF.team,$s.bestPF.pf) }
    if ($s.bestRec){  $lines += ("Best Record: {0} — {1}" -f $s.bestRec.team,$s.bestRec.rec) }
    if ($s.topTeam){  $lines += ("Top Team Week: {0} — {1} (W{2})" -f $s.topTeam.team,$s.topTeam.pts,$s.topTeam.week) }
    if ($s.topPlayer -and $s.topPlayer.text){ $lines += ("Top Player Week: {0}" -f $s.topPlayer.text) }
    $lines += ""
  }
  ($lines -join "`n")
}
function Ensure-StatsAndRecordsPost {
  $hist=Load-RecordsHistory; if (-not $hist -or $hist.Count -eq 0){ return }
  $hist=@($hist | Sort-Object { $_.season } -Descending | Select-Object -First 10)
  $content=Build-RecordsMessage -history $hist; $hash=Hash-Text $content
  $msgState= if (Test-Path $F_RecordsMsg){ Get-Content $F_RecordsMsg | ConvertFrom-Json } else { $null }
  $chan=$CHAN_STATS_RECORDS
  if (-not $msgState -or -not $msgState.message_id){
    $res=Send-DiscordMessage -ChannelId $chan -Content $content
    if ($res){ @{season=($hist[0].season);message_id=$res.id;content_hash=$hash} | ConvertTo-Json | Set-Content $F_RecordsMsg }
  } else {
    if ($msgState.content_hash -ne $hash){
      $null=Edit-DiscordMessage -ChannelId $chan -MessageId $msgState.message_id -Content $content
      @{season=($hist[0].season);message_id=$msgState.message_id;content_hash=$hash} | ConvertTo-Json | Set-Content $F_RecordsMsg
    }
  }
}
function Archive-SeasonIfFinal {
  if (-not (Is-ChampionshipFinal)){ return }
  $season=$YEAR
  $hist=Load-RecordsHistory
  if ($hist | Where-Object { $_.season -eq $season }){ return }
  $sum=Get-SeasonSummary; if (-not $sum){ return }
  $entry=@{ season=$season; champion=$sum.champion; bestPF=$sum.bestPF; bestRec=$sum.bestRec; topTeam=$sum.topTeam; topPlayer=$sum.topPlayer }
  $newHist=@($entry)+@($hist)
  $newHist=@($newHist | Sort-Object { $_.season } -Descending | Select-Object -First 10)
  Save-RecordsHistory -hist $newHist
  Ensure-StatsAndRecordsPost
}
function Tick-StatsAndRecords { Archive-SeasonIfFinal }

#########################
# Scheduler / Main Loop #
#########################
$nextMatchups = Next-Weekly -dayOfWeek 'Wednesday' -hour 10 -minute 0
$nextRankings = Next-Weekly -dayOfWeek 'Tuesday'  -hour 10 -minute 0
$nextReminder = Next-Weekly -dayOfWeek 'Sunday'   -hour 10 -minute 0

Write-Host "Jeremy Shockey running. Next (ET):" -ForegroundColor Cyan
Write-Host ("  Weekly Matchups : {0}" -f $nextMatchups) -ForegroundColor Cyan
Write-Host ("  Power Rankings  : {0}" -f $nextRankings) -ForegroundColor Cyan
Write-Host ("  Lineup Reminder : {0}" -f $nextReminder) -ForegroundColor Cyan
Write-Host "Streaming transactions and polling..." -ForegroundColor Cyan

$lastLineupPoll   = [datetime]'2000-01-01'
$lastTxPoll       = [datetime]'2000-01-01'
$lastBoxscorePoll = [datetime]'2000-01-01'
$lastStatsPoll    = [datetime]'2000-01-01'

while ($true) {
  $now = Get-NowET

  if ($now -ge $nextMatchups) { Ensure-WeeklyMatchups; $nextMatchups = $nextMatchups.AddDays(7) }
  if ($now -ge $nextRankings) { Ensure-PowerRankings;  $nextRankings = $nextRankings.AddDays(7) }
  if ($now -ge $nextReminder) { Post-SetLineupReminder; $nextReminder = $nextReminder.AddDays(7) }

  if (($now - $lastLineupPoll).TotalSeconds -ge $Poll_Lineups_Seconds) {
    $lastLineupPoll = $now
    Ensure-WeeklyMatchups
    Ensure-PowerRankings
  }

  if (($now - $lastTxPoll).TotalSeconds -ge $Poll_Transactions_Seconds) {
    $lastTxPoll = $now
    Tick-Transactions
  }

  if (($now - $lastBoxscorePoll).TotalMinutes -ge $Poll_Boxscores_Minutes) {
    $lastBoxscorePoll = $now
    $wk = Get-CurrentWeek
    if ($wk -gt 0) {
      $cap = [Math]::Min($REG_SEASON_LAST, [int]$wk)
      Update-WeeklyTopPlayers -WeekMax $cap
    }
  }

  if (($now - $lastStatsPoll).TotalMinutes -ge $Poll_Records_Minutes) {
    $lastStatsPoll = $now
    Tick-StatsAndRecords
  }

  Start-Sleep -Milliseconds 500
}
