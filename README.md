# Active alarm list in the PLC (Tc3_EventLogger)

## Disclaimer

All sample code provided by Beckhoff Automation LLC are for illustrative purposes only and are provided "as is"
and without any warranties, express or implied. Actual implementations in applications will vary significantly.
Beckhoff Automation LLC shall have no liability for, and does not waive any rights in relation to, any code
samples that it provides or the use of such code samples for any purpose.

## Overview

A reusable function block that keeps the list of currently raised alarms **in the PLC**, plus a demo that drives
one stack light per station from it. No HMI involved.

## Why a listener

Tc3_EventLogger has no "get active alarms" call for the PLC.
[`FB_ReadTc3Events`](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/11028199435.html) needs a
visualization object and returns an 80-row text table of all events. The supported PLC pattern is a listener:
extend `FB_ListenerBase2`, subscribe with a filter, and maintain your own table from the callbacks
(`OnAlarmRaised` adds, `OnAlarmCleared` / `OnAlarmDisposed` remove, `OnMessageSent` goes to a ring buffer).
`FB_ActiveAlarmListener` is that listener.

## Reusable part

Copy these three files. Dependencies: Tc3_EventLogger, Tc2_System.

| File | Purpose |
|---|---|
| `POUs/I_ActiveAlarmList.TcIO` | Read-only view of the list. Consumers depend on this, not on the FB. |
| `POUs/FB_ActiveAlarmListener.TcPOU` | Fills the application's tables from the EventLogger callbacks. |
| `DUTs/ST_EventListEntry.TcDUT` | One row: class, event id, severity, source, raised / confirmation state, timestamps, latency. |

The application owns and sizes the tables
([`ARRAY[*]`](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/8825257611.html) VAR_IN_OUT, any bounds):

```
VAR
    fbListener      : FB_ActiveAlarmListener;
    aActiveAlarms   : ARRAY[1..128] OF ST_EventListEntry;
    aRecentMessages : ARRAY[1..32]  OF ST_EventListEntry;
END_VAR

fbFilter.Clear().EventClass.EqualTo(TC_EVENTS.StationEvents.CycleComplete.uuidEventClass);
fbListener.Subscribe2(fbFilter);                                                 // once
fbListener(aActiveAlarms := aActiveAlarms, aRecentMessages := aRecentMessages);  // every cycle
```

`TC_EVENTS.StationEvents` is a namespace, not a class; the class GUID is taken from any of its events.

### I_ActiveAlarmList

Properties (read-only):

| Property | Type | Meaning |
|---|---|---|
| `nActiveAlarms` | UDINT | alarms currently raised |
| `nMaxAlarms` | UDINT | number of rows in the alarm table (upper index for `GetAlarm`) |
| `nAlarmChangeCounter` | UDINT | increments on every raise / clear / dispose |
| `nMessageSequence` | UDINT | running number of the newest message (0 = none) |
| `nMaxRecentMessages` | UDINT | size of the message ring buffer |

Methods:

| Method | Returns | Meaning |
|---|---|---|
| `GetAlarm(nIndex, stEntry)` | BOOL | copy row `nIndex` (1..`nMaxAlarms`); FALSE = empty row |
| `GetMessage(nSequence, stEntry)` | BOOL | copy the message with that sequence number; FALSE = overwritten |
| `Count(eMin, eMax)` | UDINT | raised alarms in a severity range |
| `CountBySource(nSourceId, eMin, eMax)` | UDINT | same, for one `FB_TcSourceInfo.nId` |
| `CountByEventClass(guid, eMin, eMax)` | UDINT | same, for one event class |
| `IsActive(eventClass, nEventId, nSourceId)` | BOOL | is this alarm raised |

Consumers take `ipAlarmList : I_ActiveAlarmList` as a `VAR_INPUT` and check it for `0`. Any other producer
(own `FB_TcAlarm` states, data pushed in over ADS) can implement the same interface without touching them.

The FB additionally has `Reset()`, `bTableOverflow`, `hrLastError`, `tLastLatency`, `tMaxLatency`.
Alarm identity is event class + event id + source id, as in the EventLogger.

**Active** means what `FB_TcAlarm.bActive` means: raised, or cleared but still waiting for confirmation. Each row
carries `bRaised` and `eConfirmationState`; the listener reads both from the EventLogger inside the callback
(`ITcAlarm` via `TcQueryInterface`), so alarms created with `bWithConfirmation := TRUE` stay listed after
`Clear(FALSE)` until `Confirm()`, and `Clear(TRUE)` ends them at once. Alarms without confirmation leave on clear.

## Demo: 12 stations, 12 stack lights

| File | Purpose |
|---|---|
| `MyEvents.tmc` | `StationEvents`: 2 CycleComplete (message), 3/6/7 Warning, 4/8/9 Error, 5/10 Critical. `MachineEvents`: not subscribed, proves the filter. |
| `POUs/FB_Station.TcPOU` | Publisher. One `FB_TcSourceInfo` (`nId` = station), one message, `aAlarms[1..8]`. `SendMessage`, `Raise(n)`, `Clear(n)`, `ClearAll`. |
| `POUs/FB_StackLight.TcPOU` | Red: any Error/Critical of this source. Yellow: any Warning. Green: 3 s after a message. All flash at 1 Hz. |
| `POUs/MAIN.TcPOU` | Wires it up; test variables. Also one alarm with confirmation required (`fbAckAlarm`, source id 13) with `bTestAck*` controls. |

Station = source. Every station event carries the station number as `nId`, so a stack light is one
`CountBySource` per color.

## Test

Online: set `MAIN.nTestStation` (1..12) and `nTestAlarm` (1..8; 1/4/5 Warning, 2/6/7 Error, 3/8 Critical), pulse
`bTestRaise`, `bTestClear`, `bTestSendMessage`, `bTestClearAll`. Watch `MAIN.aActiveAlarms` and
`aStackLights[n].bRed / bYellow / bGreen`.

Automated, over ADS with the TcXaeMgmt PowerShell module (installed with TwinCAT XAE):

```powershell
.\tests\Test-ActiveAlarms.ps1 -NetId 199.4.42.250.1.1
```

Checks list contents, flashing, multiple alarms per severity, ring buffer, filter, confirmation handling, and latency.

## Timing

The callbacks run inside the `fbListener(...)` call, in the PLC task. Each row stores the EventLogger's raise
stamp (`nTimestamp`), the callback time (`nReceived`) and the difference (`tLatency`); the FB tracks
`tMaxLatency`. Measured on the target with a 10 ms task: events land in the table one cycle after they are raised, two
cycles worst case over several hundred raises (MAIN runs the publishers after the listener; swap the order
to save a cycle). The test asserts `tMaxLatency <= 2` cycles.

## Limits

The PLC cannot read the EventLogger's own active-alarm collection, so the table is a copy. It drifts if:

| Cause | Mitigation |
|---|---|
| alarm raised before `Subscribe2` | subscribe in the first cycle |
| listener not called every cycle (queue overrun) | call it every cycle, same or faster task than publishers |
| table full (`bTableOverflow`) | size `aActiveAlarms` generously |
| callback returns <> `S_OK` | always return `S_OK` |

If that ever matters: `FB_TcEventLogger.IsAlarmRaised` can verify single rows; alarms owned by this PLC can be
read from their `FB_TcAlarm.bRaised` directly; or a helper process on the IPC can read `ActiveAlarms` from the
.NET proxy and write it back over ADS. The last is a true pull and valid when its asynchronous, unbounded
latency is acceptable; it also needs .NET and a second process on the target.

## Notes

* `fbEvent` in the callbacks is a `REFERENCE`; copy, never store.
* `OnAlarmCleared` fires for `Clear(FALSE)` and `Clear(TRUE)` alike, and the callback's `FB_TcEvent` has no
  confirmation state. The listener therefore asks the alarm itself (`ITcAlarm.GetIsRaised` /
  `GetConfirmationState`) before deciding whether the row stays.
* `Count...` is a linear scan. 12 stations x 2 calls x 128 rows per cycle is trivial.
