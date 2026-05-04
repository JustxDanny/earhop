# EarHop

> One hotkey. Hop your audio between Bluetooth headphones and PC speakers — including waking the headphones from a fully-disconnected state. No admin, no UI clicks, no Settings dance.

Windows treats Bluetooth audio reconnection as a manual ritual: open Settings → Bluetooth → find device → Connect → wait → manually pick it as default playback. **EarHop collapses that into a single keystroke** by talking to the Win32 Bluetooth API directly to force the A2DP profile up, then redirecting the default playback device the moment Windows registers the audio endpoint.

```
[Ctrl + Space + S]   ─►  XM4 paired but disconnected → wakes BT, activates
                          A2DP, sets as default. ~3-8s end-to-end.

[Ctrl + Space + S]   ─►  XM4 currently default → swaps to your speakers AND
                          fully drops the BT audio profiles, freeing the
                          headphones for your phone. <1s.
```

---

## Why this exists

Modern Windows still doesn't expose a clean way to "click a button to reconnect my Bluetooth headphones and start playing through them." You have to:

1. Click the speaker icon, see your headphones aren't an option (because the audio endpoint isn't registered until A2DP is active).
2. Open Settings, navigate to Bluetooth, find the device, click **Connect**.
3. Wait 5-15 seconds while Windows brings up A2DP.
4. Open the speaker icon again, switch default to the headphones.

EarHop is one keystroke for steps 1-4. The interesting part isn't the AutoHotkey wrapper — it's the discovery that **`BluetoothSetServiceState(A2DP_SINK, DISABLE)` then `(ENABLE)`** is the no-admin Win32 incantation that actually replicates Settings' Connect button. And that calling **ENABLE alone returns `rc=87` (`ERROR_INVALID_PARAMETER`)** because Windows refuses no-op transitions. The DISABLE→ENABLE toggle forces a real state change and makes the audio Render endpoint pop up in MMDevice within ~1 second.

---

## What's in the box

```
earhop/
├── toggle.ahk            # main script, AHK v2
├── start.cmd             # launcher (use this in shell:startup for autostart)
├── setup.ps1             # interactive first-run wizard
├── config.ini            # device IDs, MAC, hotkey - written by setup.ps1
├── bin/
│   ├── AutoHotkey64.exe  # portable AHK v2 runtime
│   ├── SoundVolumeView.exe   # NirSoft, default-device switcher
│   ├── bt-connect.ps1    # wakes BT + activates A2DP profile
│   └── bt-disconnect.ps1 # tears down BT audio profiles
└── README.md
```

No installer. No registry edits. No admin. Drop the folder anywhere, run `setup.ps1` once, you're done.

---

## Requirements

- Windows 10 (1809+) or Windows 11
- A paired classic-Bluetooth audio device (Sony WH-1000XM*, Bose, JBL, etc. — anything that advertises A2DP Sink, which is basically every BT headset)
- PowerShell 5.1+ (ships with Windows by default)
- That's it.

The bundled `bin/AutoHotkey64.exe` and `bin/SoundVolumeView.exe` are portable — you don't need to install anything.

---

## Setup (≈30 seconds)

1. **Download or `git clone`** this repo anywhere on disk:
   ```
   git clone https://github.com/JustxDanny/earhop.git
   cd earhop
   ```

2. **Make sure your BT headphones are connected** to Windows right now. Open the speaker icon → click the arrow next to the default device → confirm your headphones appear in the list and audio actually plays through them. EarHop uses this state to discover their audio endpoint ID.

3. **Run the setup wizard.** Right-click `setup.ps1` → "Run with PowerShell" — *or* from a terminal:
   ```
   powershell -ExecutionPolicy Bypass -File setup.ps1
   ```

   You'll see something like:
   ```
   Step 1/4: which Bluetooth device should the hotkey toggle?
     [ 1]  Name: JBL Flip 6                        MAC: AABBCCDDEE01  Status: OK
     [ 2]  Name: WH-1000XM4                        MAC: AABBCCDDEE02  Status: OK
     [ 3]  Name: Bose QC45                         MAC: AABBCCDDEE03  Status: OK
   Pick the device #: 2

   Step 2/4: pick FALLBACK 1 - the device to switch to when you toggle AWAY...
     [ 1]  Name: Sonyxm4              state=Active     cli=WH-1000XM4 Stereo\Device\Sonyxm4\Render
     [ 2]  Name: Headphones           state=Active     cli=XMFHZ02 Stereo\Device\Headphones\Render
     [ 3]  Name: Speakers             state=Active     cli=High Definition Audio Device\Device\Speakers\Render
   Pick fallback 1 #: 2

   Step 3/4: pick FALLBACK 2 - the always-present backup...
   Pick fallback 2 #: 3

   Step 4/4: short label for tray notifications
     Label: XM4

   Wrote config.ini  ✓
   Unblocking bundled binaries...
   Done. Hotkey: Ctrl + Space + S
   ```

4. **Start it.** Double-click `start.cmd` — a tray icon appears. Hotkey is live. Right-click the tray icon → Exit to stop.

5. **(Optional) Autostart on login.** Press <kbd>Win</kbd>+<kbd>R</kbd> → `shell:startup` → Enter. Drop a copy of `start.cmd` in that folder. (Make sure the cmd inside that copy uses *absolute paths* to your earhop folder — see the [Autostart caveat](#autostart-caveat) below.)

---

## How it actually works

Two kinds of operations, very different mechanisms.

### Switching AWAY from the BT device (`<1s`)

Trivial: SoundVolumeView sets the default device to your fallback, then `bt-disconnect.ps1` calls `BluetoothSetServiceState(svc, DISABLE)` for every audio-related service GUID (A2DP, AVRCP, HFP, Headset). The PC drops the link from its end; the headphones immediately become available for your phone with zero contention.

### Switching TO the BT device (`~3-8s` cold, `~3s` warm)

The interesting part. Two stages run by `bt-connect.ps1`:

**Stage 1 — Wake the device.**
WinRT `BluetoothDevice.GetRfcommServicesAsync(BluetoothCacheMode.Uncached)` forces a fresh SDP probe over the air. This wakes a sleeping device because the baseband inquiry has to actually reach it. The link tends to flip `ConnectionStatus = Connected` as a side effect even when the SDP call itself returns a timeout.

**Stage 2 — Activate the A2DP audio profile.**
This is the part nobody documents well. The naive approach — call `BluetoothSetServiceState(A2DP_SINK_GUID, ENABLE)` — returns `rc=87` (`ERROR_INVALID_PARAMETER`) and does nothing, because Windows treats it as a no-op when the service is already in the enabled state in the persistent BT cache.

The trick is the **DISABLE→ENABLE toggle**:

```powershell
BluetoothSetServiceState(hRadio, deviceInfo, A2DP_SINK_GUID,  0x00)  # DISABLE
Start-Sleep -Milliseconds 250                                         # let it propagate
BluetoothSetServiceState(hRadio, deviceInfo, A2DP_SINK_GUID,  0x01)  # ENABLE
```

The DISABLE forces a real state transition. The ENABLE that follows is no longer a no-op, so Windows actually brings up the L2CAP+AVDTP profile and **registers the audio Render endpoint in MMDevice within ~1 second** of `ENABLE` returning `rc=0`. We do the same cycle for the AVRCP CT GUID — empirically it's also required on some firmwares to make MMDevice see the endpoint.

Meanwhile AHK fires the PowerShell helper **asynchronously** and polls SoundVolumeView at 100ms intervals. The instant the audio endpoint shows up, AHK calls `SVV /SetDefault` and toasts. PowerShell's cleanup runs invisibly in the background — the user perceives the switch the moment audio starts flowing.

```
0ms     hotkey pressed
~50ms   AHK fires bt-connect.ps1 async, starts polling SVV
~150ms  PS startup overhead done, BT radio handle open
~2s     SDP probe completes, BT link Connected
~5s     A2DP DISABLE+ENABLE returns rc=0
~5.1s   AHK poll detects new endpoint, fires SVV /SetDefault
~5.2s   tray toast "Switched to XM4", audio flowing
~8s     PS finishes AVRCP cycle in background (invisible)
```

---

## Configuration reference

Open `config.ini` to tweak. Re-run `setup.ps1` if you swap headphones.

| Key | Section | What |
|---|---|---|
| `primary_match` | `[devices]` | Substring/prefix that uniquely identifies your BT device's audio endpoint in SVV. Match on `<Friendly Name>\Device\` because the middle "Device Name" component flips after profile re-init (e.g. `Sonyxm4` ↔ `Headphones`) and a hardcoded full ID would break. |
| `primary_mac` | `[devices]` | BT MAC, no separators (`AABBCCDDEEFF`). Used by `bt-connect.ps1` to talk to the Win32 BT API. |
| `primary_label` | `[devices]` | Short name used in tray notifications. |
| `fallback1` | `[devices]` | Full SVV CmdID of the preferred fallback (your other headphones, if you have a second pair). |
| `fallback2` | `[devices]` | Full SVV CmdID of the always-present backup (your built-in PC speakers). |
| `toast` | `[ui]` | `1` = show tray notification on toggle, `0` = silent. |
| `hotkey` | `[ui]` | AutoHotkey v2 hotkey definition. Default `~Space & s`. Examples: `^!s` = Ctrl+Alt+S, `#F1` = Win+F1, `ScrollLock` = ScrollLock alone. |
| `hotkey_guard` | `[ui]` | Optional extra modifier required for the hotkey to fire. Default `Control`, gives a 3-key chord. Set blank to disable. |

---

## Sharing this with a friend

For someone else to use EarHop with their own BT device:

1. They `git clone` (or download zip) and unzip somewhere.
2. Pair their BT headphones in Windows Settings, make sure they're connected.
3. Run `setup.ps1` — wizard auto-discovers their BT devices and audio endpoints, prompts for selection, writes `config.ini` for them.
4. Run `start.cmd`. Done.

No code changes needed. Everything user-specific lives in `config.ini`, and `setup.ps1` writes it from the live system. The repo ships with an empty `config.ini` template.

---

## Known gotchas

### Autostart caveat

Windows' Startup folder runs scripts **with the cwd set to the Startup folder**, not the script's own folder. So if your `start.cmd` uses `%~dp0` and you place it in Startup, `%~dp0` resolves to the Startup folder — not your earhop install. The bundled `start.cmd` uses `%~dp0` correctly *for double-click usage*, but for autostart you should either:

- **(Recommended)** Create a *shortcut* to `start.cmd` in `shell:startup` (right-click `start.cmd` → Send to → Desktop, then move the `.lnk` to `shell:startup`). The shortcut preserves the original `%~dp0` resolution.
- *Or* copy `start.cmd` into Startup AND edit it to use absolute paths to your earhop folder.

(This was [bug #1](#bug-fix-history) in the development log.)

### "Reconnect failed - check toggle.log"

The BT link came up but the audio profile didn't register. Most common causes:

- Headphones are connected to your phone via Bluetooth multipoint and refusing PC. Disconnect from phone first.
- Headphones are in deep sleep — power them off and on.
- You're out of range or low battery.

Check `bt-connect.log` to see exactly which stage failed.

### "WH-1000XM4 connected (Bluetooth)" toast appears but audio doesn't switch

Almost always means SoundVolumeView is being sandboxed by Windows SmartScreen. Re-run `setup.ps1` (it unblocks the binaries) or right-click `bin\SoundVolumeView.exe` → Properties → check **Unblock**.

### Hotkey conflict

The default `Ctrl+Space+S` is a 3-key chord chosen because it almost never collides with anything. If it does, edit `[ui] hotkey` in `config.ini` and restart. AHK v2 hotkey syntax: <https://www.autohotkey.com/docs/v2/Hotkeys.htm>

---

## Bug-fix history

This started as a 60-line AHK script and grew over a sequence of conversations with [Claude Code](https://claude.com/claude-code) using "agentic engineering" — Claude doing the diagnostic work, me directing what to fix and validating each step. Each bug found also got a structured report (symptom / root cause / fix / why it broke / what to notice next time / verification). Highlights:

| # | Bug | Root cause | Fix |
|---|---|---|---|
| 1 | Startup folder copy of `start.cmd` failed with `Windows cannot find ...\Startup\bin\AutoHotkey64.exe` | `%~dp0` in a `.cmd` resolves to the file's *parent* dir, which is Startup itself when copied there — not the project | Hardcode absolute paths in the Startup copy, or use a `.lnk` shortcut to the original |
| 2 | Hotkey-fired reconnect from disconnected XM4 always toasted "Reconnect failed" even though headphones lit up Connected | RFCOMM SDP wake brought the BT link up but A2DP profile never auto-activated. Conflated `ConnectionStatus = Connected` with "audio is ready" | Two-stage script: WinRT SDP wake + `BluetoothSetServiceState` DISABLE→ENABLE on A2DP Sink GUID |
| 3 | `BluetoothSetServiceState(A2DP, ENABLE)` returned `rc=87` (`ERROR_INVALID_PARAMETER`) and did nothing | Windows rejects the call as a no-op when the service is already enabled in the persistent cache | DISABLE first, sleep ~250ms, then ENABLE — forces a real state transition |
| 4 | Em-dash in a PS comment crashed `bt-connect.ps1` with "string is missing the terminator" | PS 5.1 reads `.ps1` files as ANSI when there's no BOM; non-ASCII bytes (em-dash, smart quotes) confuse the parser's quote tracking | Keep `.ps1` files strict ASCII, or save with UTF-8 BOM |
| 5 | After A2DP profile re-init, hardcoded SVV CmdID stopped matching because the middle "Device Name" component flipped from `Sonyxm4` to `Headphones` | Renamed audio endpoints don't survive driver re-init; the friendly-name part of the CmdID isn't stable | Match by prefix on `<Friendly Name>\Device\`, resolve full ID dynamically each toggle |
| 6 | 9.7s perceived latency between hotkey and audio actually playing | AHK was using `RunWait` to block until PowerShell exited *and* polling SVV every 400ms after that. The audio endpoint was registered ~3s before PS exit; AHK couldn't see it until then | Fire PowerShell async via `Run`, AHK polls SVV at 100ms in parallel — fires `SetDefault` the instant Windows registers the endpoint. Cut latency to ~5-8s end-to-end, with the perceived gap between Windows BT toast and AHK toast dropping from ~3s to ~300ms |

End-to-end the cold-connect path went from "manual click ritual + ~15s wait" → "single keystroke + ~5-8s wait" with a ~300ms perceived gap between BT-connected and audio-flowing.

---

## License

[MIT](LICENSE). Bundles SoundVolumeView (NirSoft freeware) and the AutoHotkey v2 portable runtime (GPLv2). If you redistribute, retain those upstream notices.
