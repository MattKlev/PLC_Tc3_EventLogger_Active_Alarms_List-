<#
.SYNOPSIS
    End-to-end test of FB_ActiveAlarmListener + FB_StackLight against a running PLC.

.DESCRIPTION
    Drives the test variables in MAIN over ADS (TcXaeMgmt PowerShell module, ships with TwinCAT XAE)
    and checks the active alarm list, the message ring buffer, the stack light outputs and the
    raise -> row latency.

.EXAMPLE
    .\tests\Test-ActiveAlarms.ps1 -NetId 199.4.42.250.1.1

    Requires: TcXaeMgmt module, an ADS route to the target, the PLC in Run.
#>
param(
    [string]$NetId = '199.4.42.250.1.1',
    [int]$Port = 851
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module TcXaeMgmt

$TaskCycleMs  = 10.0                # PlcTask cycle time (tsproj: CycleTime=100000 x 100 ns)
$MaxLatencyMs = 2 * $TaskCycleMs    # raise -> row visible must fit in two cycles
$Sev = @{ Verbose = 0; Info = 1; Warning = 2; Error = 3; Critical = 4 }
$Ev  = @{ Message = 2; Warning = 3; Alarm = 4; Critical = 5 }           # event ids in TC_EVENTS.StationEvents
# FB_Station.aAlarms index -> event id, severity   (see FB_Station header)
$Alarms = @{ 1 = @(3, 'Warning'); 2 = @(4, 'Error'); 3 = @(5, 'Critical'); 4 = @(6, 'Warning')
             5 = @(7, 'Warning'); 6 = @(8, 'Error'); 7 = @(9, 'Error'); 8 = @(10, 'Critical') }
$Conf = @{ NotSupported = 0; NotRequired = 1; WaitForConfirmation = 2; Confirmed = 3; Reset = 4 }   # TcEventConfirmationState

$script:Failures = New-Object System.Collections.Generic.List[string]
function Check([bool]$Cond, [string]$Msg) {
    Write-Host ("  {0}  {1}" -f ($(if ($Cond) { 'PASS' } else { 'FAIL' })), $Msg)
    if (-not $Cond) { $script:Failures.Add($Msg) }
}
function Hex([int]$hr) { '0x{0:X8}' -f ($hr -band 0xFFFFFFFF) }

# --- ADS helpers --------------------------------------------------------------------------------
$S = New-TcSession -NetId $NetId -Port $Port
function Read-Plc([string]$Path)              { Read-TcValue -Session $S -Path $Path }
function Read-PlcEnum([string]$Path)          { $S.Connection.ReadValue($Path, [int16]) }    # enums need an explicit type
function Write-Plc([string]$Path, $Value)      { Write-TcValue -Session $S -Path $Path -Value $Value -Force }
function ToMs([TimeSpan]$t)              { [math]::Round($t.TotalMilliseconds, 3) }

# --- MAIN test controls -------------------------------------------------------------------------
function Set-Alarm([int]$Station, [int]$Idx, [bool]$Raise) {
    # raise / clear FB_Station.aAlarms[Idx] on a station; returns MAIN.hrTest
    Write-Plc 'MAIN.nTestStation' $Station
    Write-Plc 'MAIN.nTestAlarm'   $Idx
    Write-Plc $(if ($Raise) { 'MAIN.bTestRaise' } else { 'MAIN.bTestClear' }) $true
    Start-Sleep -Milliseconds 250
    Read-Plc 'MAIN.hrTest'
}
function Send-Message([int]$Station) {
    Write-Plc 'MAIN.nTestStation' $Station
    Write-Plc 'MAIN.bTestSendMessage' $true
    Start-Sleep -Milliseconds 250
    Read-Plc 'MAIN.hrTest'
}
function Clear-All([int]$Station) {
    Write-Plc 'MAIN.nTestStation' $Station
    Write-Plc 'MAIN.bTestClearAll' $true
    Start-Sleep -Milliseconds 250
}
function Pulse([string]$Flag) { Write-Plc "MAIN.$Flag" $true; Start-Sleep -Milliseconds 250 }

# --- listener -----------------------------------------------------------------------------------
function Read-Row([string]$P) {
    [pscustomobject]@{
        bUsed = Read-Plc "$P.bUsed"; nSequence = Read-Plc "$P.nSequence"; nEventId = Read-Plc "$P.nEventId"
        eSeverity = Read-PlcEnum "$P.eSeverity"; nSourceId = Read-Plc "$P.nSourceId"; sSourceName = Read-Plc "$P.sSourceName"
        bIsAlarm = Read-Plc "$P.bIsAlarm"; LatencyMs = ToMs (Read-Plc "$P.tLatency")
        bRaised = Read-Plc "$P.bRaised"; eConfirmationState = Read-PlcEnum "$P.eConfirmationState"
    }
}
function Get-ActiveRows([int]$MaxRows = 128) {
    $rows = @()
    for ($i = 1; $i -le $MaxRows; $i++) {
        if (Read-Plc "MAIN.aActiveAlarms[$i].bUsed") { $rows += Read-Row "MAIN.aActiveAlarms[$i]" }
    }
    $rows
}
function Get-MessageRow([int]$Seq, [int]$Ring = 32) { Read-Row "MAIN.aRecentMessages[$((($Seq - 1) % $Ring) + 1)]" }
function Get-ActiveCount { Read-Plc 'MAIN.fbListener._nActiveAlarms' }

# --- stack light --------------------------------------------------------------------------------
function Get-Light([int]$Station) {
    $p = "MAIN.aStackLights[$Station]"
    [pscustomobject]@{ nActiveAlarms = Read-Plc "$p.nActiveAlarms"; nActiveWarnings = Read-Plc "$p.nActiveWarnings"; bMessageActive = Read-Plc "$p.bMessageActive" }
}
function Test-Flashing([int]$Station, [string]$Color, [int]$Samples = 13, [int]$DurationMs = 1300) {
    # TRUE if the output was seen both ON and OFF within the window (1 Hz blink)
    $on = $false; $off = $false
    for ($k = 0; $k -lt $Samples; $k++) {
        if (Read-Plc "MAIN.aStackLights[$Station].b$Color") { $on = $true } else { $off = $true }
        Start-Sleep -Milliseconds ($DurationMs / $Samples)
    }
    $on -and $off
}
function Test-Dark([int]$Station, [string]$Color, [int]$Samples = 13, [int]$DurationMs = 1300) {
    for ($k = 0; $k -lt $Samples; $k++) {
        if (Read-Plc "MAIN.aStackLights[$Station].b$Color") { return $false }
        Start-Sleep -Milliseconds ($DurationMs / $Samples)
    }
    $true
}

try {
    Write-Host '== 0. startup state'
    Check ($S.Connection.ReadState().AdsState -eq 'Run') "PLC in Run"
    Check ((Read-Plc 'MAIN.hrSubscribe') -eq 0) 'listener Subscribe2 returned S_OK'
    $notInit = 1..12 | Where-Object { -not (Read-Plc "MAIN.aStations[$_].bInitialized") }
    Check (-not $notInit) "all 12 stations initialized (not initialized: $($notInit -join ','))"
    # hrLastError latches the last failed call (e.g. Clear on a non-raised alarm), informational only
    $errs = 1..12 | ForEach-Object { $h = Read-Plc "MAIN.aStations[$_].hrLastError"; if ($h) { "$_=$(Hex $h)" } }
    Write-Host "  info  station hrLastError: $($errs -join ' ')"
    foreach ($st in 1..12) { if ((Read-Plc "MAIN.aStations[$st].nRaised") -gt 0) { Clear-All $st } }   # start clean
    Start-Sleep -Milliseconds 300
    Check ((Get-ActiveCount) -eq 0) 'active alarm list empty at start'
    $busy = 1..12 | ForEach-Object { Get-Light $_ } | Where-Object { $_.nActiveAlarms -or $_.nActiveWarnings }
    Check (-not $busy) 'no stack light reports alarms/warnings at start'

    Write-Host '== 1. raise Error alarm on station 3'
    $hr = Set-Alarm 3 2 $true
    Check ($hr -eq 0) "Raise returned S_OK (hr=$hr)"
    $rows = Get-ActiveRows
    Check ($rows.Count -eq 1) "exactly one row in active list ($($rows.Count))"
    if ($rows.Count) {
        $r0 = $rows[0]
        Check ($r0.nSourceId -eq 3) "row source id = 3 ($($r0.nSourceId))"
        Check ($r0.sSourceName -eq 'Station 3') "row source name = 'Station 3' ('$($r0.sSourceName)')"
        Check ($r0.nEventId -eq $Ev.Alarm) "row event id = 4 ($($r0.nEventId))"
        Check ($r0.eSeverity -eq $Sev.Error) "row severity = Error ($($r0.eSeverity))"
        Check $r0.bIsAlarm 'row flagged as alarm'
        Check ($r0.LatencyMs -ge 0 -and $r0.LatencyMs -le $MaxLatencyMs) `
            "raise -> row latency $($r0.LatencyMs) ms (EventLogger stamp -> listener callback), within $MaxLatencyMs ms = 2 task cycles"
    }
    Check ((Get-Light 3).nActiveAlarms -eq 1) 'stack light 3 counts 1 alarm'
    Check ((Get-Light 4).nActiveAlarms -eq 0) 'stack light 4 counts 0 alarms'
    Check (Test-Flashing 3 'Red')  'stack light 3 RED flashing'
    Check (Test-Dark 3 'Yellow')   'stack light 3 YELLOW dark'
    Check (Test-Dark 4 'Red')      'stack light 4 RED dark'

    Write-Host '== 2. raising the same alarm again must not duplicate'
    $hr = Set-Alarm 3 2 $true
    Check ($hr -ne 0) "second Raise rejected by EventLogger (hr=$(Hex $hr))"
    Check ((Get-ActiveCount) -eq 1) 'still one row'

    Write-Host '== 3. second station: raise on 7, clear 3 -> only 7 stays red'
    Set-Alarm 7 2 $true | Out-Null
    Check ((Get-ActiveCount) -eq 2) 'two rows'
    Set-Alarm 3 2 $false | Out-Null
    Check ((Get-ActiveCount) -eq 1) 'one row after clearing station 3'
    $rows = Get-ActiveRows
    Check ($rows.Count -eq 1 -and $rows[0].nSourceId -eq 7) 'remaining row belongs to station 7'
    Check (Test-Dark 3 'Red')     'stack light 3 RED dark'
    Check (Test-Flashing 7 'Red') 'stack light 7 RED still flashing'

    Write-Host '== 4. two alarms on one station: red stays until the last one clears'
    Set-Alarm 7 3 $true | Out-Null
    Check ((Get-Light 7).nActiveAlarms -eq 2) 'stack light 7 counts 2 alarms'
    Set-Alarm 7 2 $false | Out-Null
    Check ((Get-Light 7).nActiveAlarms -eq 1) 'stack light 7 counts 1 alarm after clearing Error'
    Check (Test-Flashing 7 'Red') 'stack light 7 RED still flashing (Critical active)'
    Set-Alarm 7 3 $false | Out-Null
    Check ((Get-Light 7).nActiveAlarms -eq 0) 'stack light 7 counts 0 alarms'
    Check ((Get-ActiveCount) -eq 0) 'active alarm list empty'
    Check (Test-Dark 7 'Red') 'stack light 7 RED dark'

    Write-Host '== 5. warning on station 5 -> yellow only'
    Set-Alarm 5 1 $true | Out-Null
    $l5 = Get-Light 5
    Check ($l5.nActiveWarnings -eq 1 -and $l5.nActiveAlarms -eq 0) "stack light 5: 1 warning, 0 alarms ($l5)"
    $rows = Get-ActiveRows
    Check ($rows.Count -eq 1 -and $rows[0].eSeverity -eq $Sev.Warning -and $rows[0].nSourceId -eq 5) 'row is Warning from station 5'
    Check (Test-Flashing 5 'Yellow') 'stack light 5 YELLOW flashing'
    Check (Test-Dark 5 'Red')        'stack light 5 RED dark'
    Set-Alarm 5 1 $false | Out-Null
    Check ((Get-Light 5).nActiveWarnings -eq 0) 'stack light 5 warnings cleared'
    Check (Test-Dark 5 'Yellow') 'stack light 5 YELLOW dark'

    Write-Host '== 6. message on station 2 -> green pulse, ring buffer entry'
    $seq0 = Read-Plc 'MAIN.fbListener._nMessageSequence'
    $hr = Send-Message 2
    Check ($hr -eq 0) "Send returned S_OK (hr=$hr)"
    $seq1 = Read-Plc 'MAIN.fbListener._nMessageSequence'
    Check ($seq1 -eq $seq0 + 1) "message sequence incremented ($seq0 -> $seq1)"
    $m = Get-MessageRow $seq1
    Check ($m.bUsed -and $m.nSequence -eq $seq1) "ring buffer row for seq $seq1 present"
    Check ($m.nSourceId -eq 2 -and $m.sSourceName -eq 'Station 2') "message source = station 2 ($($m.nSourceId), '$($m.sSourceName)')"
    Check ($m.nEventId -eq $Ev.Message -and $m.eSeverity -eq $Sev.Info -and -not $m.bIsAlarm) 'message is CycleComplete (id 2) / Info / not an alarm'
    Check ((Get-ActiveCount) -eq 0) 'messages do not enter the active alarm list'
    Check (Get-Light 2).bMessageActive        'stack light 2 message pulse active'
    Check (-not (Get-Light 1).bMessageActive) 'stack light 1 message pulse NOT active'
    Check (Test-Flashing 2 'Green') 'stack light 2 GREEN flashing'
    Start-Sleep -Seconds 3
    Check (-not (Get-Light 2).bMessageActive) 'stack light 2 message pulse ended after 3 s'
    Check (Test-Dark 2 'Green') 'stack light 2 GREEN dark'

    Write-Host '== 7. all three at once on station 12'
    Set-Alarm 12 2 $true | Out-Null
    Set-Alarm 12 1 $true | Out-Null
    Send-Message 12 | Out-Null
    $l12 = Get-Light 12
    Check ($l12.nActiveAlarms -eq 1 -and $l12.nActiveWarnings -eq 1 -and $l12.bMessageActive) "stack light 12 red+yellow+green ($l12)"
    # green is a 3 s pulse, so sample it first; red/yellow are held by alarms
    Check (Test-Flashing 12 'Green') 'GREEN flashing on 12'
    Check ((Test-Flashing 12 'Red') -and (Test-Flashing 12 'Yellow')) 'RED and YELLOW flashing on 12'
    Set-Alarm 12 2 $false | Out-Null
    Set-Alarm 12 1 $false | Out-Null
    Check ((Get-ActiveCount) -eq 0) 'active alarm list empty'

    Write-Host '== 8. events from another class (MachineEvents) must NOT reach the listener'
    if (Read-Plc 'MAIN.fbMachineAlarm.bRaised') { Pulse 'bTestMachineClearAlarm' }     # leftover from an earlier run
    Check ((Read-Plc 'MAIN.hrMachineTest') -eq 0) 'machine events created without error'
    $seq0 = Read-Plc 'MAIN.fbListener._nMessageSequence'
    $chg0 = Read-Plc 'MAIN.fbListener._nAlarmChangeCounter'
    Pulse 'bTestMachineMessage'
    Check ((Read-Plc 'MAIN.hrMachineTest') -eq 0) 'machine message Send returned S_OK (it did reach the EventLogger)'
    Check ((Read-Plc 'MAIN.fbListener._nMessageSequence') -eq $seq0) 'listener message sequence unchanged'
    Pulse 'bTestMachineRaiseAlarm'
    Check ((Read-Plc 'MAIN.hrMachineTest') -eq 0) 'machine alarm Raise returned S_OK (it did reach the EventLogger)'
    Check (Read-Plc 'MAIN.fbMachineAlarm.bRaised') 'machine alarm is raised in the EventLogger'
    Check ((Get-ActiveCount) -eq 0) 'listener active alarm list still empty'
    Check ((Read-Plc 'MAIN.fbListener._nAlarmChangeCounter') -eq $chg0) 'listener change counter unchanged'
    Check ((Get-Light 3).nActiveAlarms -eq 0) 'stack light 3 unaffected although machine events use source id 3'
    Check ((Test-Dark 3 'Red') -and (Test-Dark 3 'Green')) 'stack light 3 RED and GREEN dark'
    # and the listener still works for its own class while the foreign alarm is raised
    Set-Alarm 3 2 $true | Out-Null
    $rows = Get-ActiveRows
    Check ($rows.Count -eq 1 -and $rows[0].nEventId -eq $Ev.Alarm -and $rows[0].sSourceName -eq 'Station 3') `
        "station 3 alarm still tracked next to the raised machine alarm (one row, 'Station 3')"
    Set-Alarm 3 2 $false | Out-Null
    Pulse 'bTestMachineClearAlarm'
    Check ((Read-Plc 'MAIN.hrMachineTest') -eq 0) 'machine alarm Clear returned S_OK'
    Check ((Get-ActiveCount) -eq 0) 'active alarm list empty at end'
    Check ((Read-Plc 'MAIN.fbListener._nMessageSequence') -eq $seq0) 'message sequence still unchanged by machine events'

    Write-Host '== 9. several alarms of the SAME severity: light holds until the last one clears'
    $st = 6
    $warnings = @($Alarms.Keys | Where-Object { $Alarms[$_][1] -eq 'Warning'  } | Sort-Object)   # 1, 4, 5
    $errors   = @($Alarms.Keys | Where-Object { $Alarms[$_][1] -eq 'Error'    } | Sort-Object)   # 2, 6, 7
    $crits    = @($Alarms.Keys | Where-Object { $Alarms[$_][1] -eq 'Critical' } | Sort-Object)   # 3, 8
    foreach ($i in $warnings) { Check ((Set-Alarm $st $i $true) -eq 0) "raise warning alarm #$i (event id $($Alarms[$i][0])) on station $st" }
    $l = Get-Light $st
    Check ($l.nActiveWarnings -eq $warnings.Count -and $l.nActiveAlarms -eq 0) "stack light ${st}: $($warnings.Count) warnings, 0 alarms ($l)"
    $ids = @(Get-ActiveRows | ForEach-Object nEventId | Sort-Object)
    $want = @($warnings | ForEach-Object { $Alarms[$_][0] } | Sort-Object)
    Check (($ids -join ',') -eq ($want -join ',')) "active list holds event ids [$($ids -join ', ')]"
    Check ((Test-Flashing $st 'Yellow') -and (Test-Dark $st 'Red')) "stack light $st YELLOW flashing, RED dark"
    for ($n = 0; $n -lt $warnings.Count; $n++) {
        Set-Alarm $st $warnings[$n] $false | Out-Null
        $remaining = $warnings.Count - $n - 1
        Check ((Get-Light $st).nActiveWarnings -eq $remaining) "cleared warning #$($warnings[$n]): $remaining warning(s) left"
        if ($remaining) { Check (Test-Flashing $st 'Yellow') "stack light $st YELLOW still flashing with $remaining warning(s)" }
    }
    Check (Test-Dark $st 'Yellow') "stack light $st YELLOW dark after the last warning cleared"

    foreach ($i in ($errors + $crits)) { Check ((Set-Alarm $st $i $true) -eq 0) "raise $($Alarms[$i][1]) alarm #$i (event id $($Alarms[$i][0])) on station $st" }
    $nRed = $errors.Count + $crits.Count
    Check ((Get-Light $st).nActiveAlarms -eq $nRed) "stack light ${st}: $nRed red-class alarms"
    Check ((Get-ActiveCount) -eq $nRed) 'listener row count matches'
    Check (Test-Flashing $st 'Red') "stack light $st RED flashing"
    foreach ($i in $errors) { Set-Alarm $st $i $false | Out-Null }
    Check ((Get-Light $st).nActiveAlarms -eq $crits.Count) "all Errors cleared, $($crits.Count) Critical(s) keep red"
    Check (Test-Flashing $st 'Red') "stack light $st RED still flashing on Criticals only"
    for ($n = 0; $n -lt $crits.Count; $n++) {
        Set-Alarm $st $crits[$n] $false | Out-Null
        Check ((Get-Light $st).nActiveAlarms -eq ($crits.Count - $n - 1)) "cleared critical #$($crits[$n]): $($crits.Count - $n - 1) left"
    }
    Check (Test-Dark $st 'Red') "stack light $st RED dark after the last alarm cleared"
    Check ((Get-ActiveCount) -eq 0) 'active alarm list empty at the very end'
    Check (-not (Read-Plc 'MAIN.fbListener.bTableOverflow')) 'no table overflow'
    Check ((Read-Plc 'MAIN.fbListener.hrLastError') -eq 0) 'listener hrLastError = S_OK'

    Write-Host '== 11. alarm WITH confirmation required (MAIN.fbAckAlarm, source id 13): row = FB_TcAlarm.bActive'
    function Get-AckState { [pscustomobject]@{ bRaised = Read-Plc 'MAIN.fbAckAlarm.bRaised'; bActive = Read-Plc 'MAIN.fbAckAlarm.bActive'; eConf = Read-PlcEnum 'MAIN.fbAckAlarm.eConfirmationState' } }
    function Get-AckRow { @(Get-ActiveRows | Where-Object nSourceId -eq 13) }
    if ((Get-AckState).bActive) { Pulse 'bTestAckClearReset' }                       # leftover from an earlier run
    Check ((Get-ActiveCount) -eq 0) 'list empty before the confirmation sequences'
    # A: Raise -> Confirm -> Clear(FALSE): confirmed while raised, clear ends it
    Pulse 'bTestAckRaise';   $r = @(Get-AckRow)
    Check ($r.Count -eq 1 -and $r[0].bRaised -and $r[0].eConfirmationState -eq $Conf.WaitForConfirmation) 'A: raised -> row present, bRaised, WaitForConfirmation'
    Pulse 'bTestAckConfirm'; $r = @(Get-AckRow)
    Check ($r.Count -eq 1 -and $r[0].bRaised -and $r[0].eConfirmationState -eq $Conf.Confirmed) 'A: confirmed while raised -> row stays, Confirmed'
    Pulse 'bTestAckClear'
    Check (@(Get-AckRow).Count -eq 0 -and -not (Get-AckState).bActive) 'A: Clear(FALSE) after confirm -> row gone, FB_TcAlarm.bActive FALSE'
    # B: Raise -> Clear(FALSE) -> Confirm: the case the plain listener got wrong
    Pulse 'bTestAckRaise'
    Pulse 'bTestAckClear';   $r = @(Get-AckRow); $ack = Get-AckState
    Check ($r.Count -eq 1 -and -not $r[0].bRaised -and $r[0].eConfirmationState -eq $Conf.WaitForConfirmation) 'B: Clear(FALSE) unconfirmed -> row STAYS, bRaised FALSE, WaitForConfirmation'
    Check ($ack.bActive -and -not $ack.bRaised) 'B: ... and FB_TcAlarm agrees: bActive TRUE, bRaised FALSE'
    Pulse 'bTestAckConfirm'
    Check (@(Get-AckRow).Count -eq 0 -and -not (Get-AckState).bActive) 'B: Confirm -> row gone, bActive FALSE'
    # C: Raise -> Clear(TRUE): reset confirmation, ends immediately
    Pulse 'bTestAckRaise'
    Pulse 'bTestAckClearReset'
    Check (@(Get-AckRow).Count -eq 0 -and -not (Get-AckState).bActive -and (Get-AckState).eConf -eq $Conf.Reset) 'C: Clear(TRUE) -> row gone, state Reset'
    # plain alarms (no confirmation) still leave on Clear
    Set-Alarm 3 2 $true | Out-Null;  $r = @(Get-ActiveRows)
    Check ($r.Count -eq 1 -and $r[0].bRaised -and $r[0].eConfirmationState -ne $Conf.WaitForConfirmation) 'plain alarm: raised, not waiting for confirmation'
    Set-Alarm 3 2 $false | Out-Null
    Check ((Get-ActiveCount) -eq 0) 'plain alarm: Clear(FALSE) removes the row'

    Write-Host '== 12. determinism: raise/send -> row latency over the whole run'
    $maxMs  = ToMs (Read-Plc 'MAIN.fbListener.tMaxLatency')
    $lastMs = ToMs (Read-Plc 'MAIN.fbListener.tLastLatency')
    Write-Host "  info  tMaxLatency = $maxMs ms, tLastLatency = $lastMs ms, task cycle = $TaskCycleMs ms"
    Check ($maxMs -gt 0 -and $maxMs -le $MaxLatencyMs) "worst-case latency over all raises/sends $maxMs ms <= $MaxLatencyMs ms (2 task cycles)"
}
finally {
    Close-TcSession -Session $S
}

Write-Host ''
if ($script:Failures.Count) {
    Write-Host "$($script:Failures.Count) FAILED:"
    $script:Failures | ForEach-Object { Write-Host "  - $_" }
    exit 1
}
Write-Host 'ALL PASSED'
