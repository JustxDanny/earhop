#Requires AutoHotkey v2.0
#SingleInstance Force

; -----------------------------------------------------------------------------
; One-hotkey toggle for a paired Bluetooth audio device on Windows 10/11.
;
; Press hotkey:
;   - if your BT device is currently the default playback -> swap default to
;     fallback (other headphones / speakers) AND fully drop the BT audio
;     profiles so the device frees up for another host (e.g. your phone).
;   - else -> if the BT audio endpoint is missing (device disconnected),
;     trigger bin\bt-connect.ps1 to wake the device and activate the A2DP
;     profile, then set it as default playback.
;
; Bluetooth radio stays on. No admin rights needed.
; -----------------------------------------------------------------------------

; --- Paths ---
global AppDir        := A_ScriptDir
global ConfigFile    := AppDir "\config.ini"
global BinDir        := AppDir "\bin"
global SVV           := BinDir "\SoundVolumeView.exe"
global BT_CONNECT    := BinDir "\bt-connect.ps1"
global BT_DISCONNECT := BinDir "\bt-disconnect.ps1"
global LOG_FILE      := AppDir "\toggle.log"

; --- Config ---
; primary_match is a substring/prefix that uniquely identifies your BT device
; in SoundVolumeView's "Command-Line Friendly ID" column. The full ID's middle
; component (the "Device Name") can flip after BluetoothSetServiceState
; DISABLE/ENABLE cycles, so prefix-matching survives renames.
global PRIMARY_MATCH := IniRead(ConfigFile, "devices", "primary_match", "")
global PRIMARY_MAC   := IniRead(ConfigFile, "devices", "primary_mac",   "")
global PRIMARY_LABEL := IniRead(ConfigFile, "devices", "primary_label", "BT Headphones")
global FALLBACK_1    := IniRead(ConfigFile, "devices", "fallback1",     "")
global FALLBACK_2    := IniRead(ConfigFile, "devices", "fallback2",     "")
global SHOW_TOAST    := IniRead(ConfigFile, "ui",      "toast",         "1") = "1"
global HOTKEY_STR    := IniRead(ConfigFile, "ui",      "hotkey",        "~Space & s")
global HOTKEY_GUARD  := IniRead(ConfigFile, "ui",      "hotkey_guard",  "Control")

; --- Validate ---
if !FileExist(SVV) {
    MsgBox("Missing " SVV "`n`nDid you run setup.ps1?", "Toggle", "Iconx")
    ExitApp 1
}
if (PRIMARY_MATCH = "" || PRIMARY_MAC = "") {
    MsgBox("config.ini is missing primary_match or primary_mac.`n`nRun setup.ps1 to configure your device.", "Toggle", "Iconx")
    ExitApp 1
}

; -----------------------------------------------------------------------------
Log(msg) {
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " " msg "`n", LOG_FILE, "UTF-8")
}

; --- SoundVolumeView helpers ---
SvvDump() {
    tmp := A_Temp "\svv_" A_TickCount "_" Random(1000, 9999) ".tsv"
    RunWait('"' SVV '" /stab "' tmp '"',, "Hide")
    if !FileExist(tmp)
        return ""
    data := ""
    try data := FileRead(tmp, "UTF-8")
    catch {
        try data := FileRead(tmp, "UTF-16")
        catch
            data := FileRead(tmp)
    }
    try FileDelete(tmp)
    return data
}

ParseHeader(line) {
    cols := Map()
    for idx, h in StrSplit(line, "`t")
        cols[Trim(h)] := idx
    return cols
}

GetDefaultPlaybackId(dump) {
    lines := StrSplit(dump, "`n", "`r")
    if (lines.Length < 2)
        return ""
    hdr := ParseHeader(lines[1])
    if !(hdr.Has("Direction") && hdr.Has("Default") && hdr.Has("Command-Line Friendly ID"))
        return ""
    dirIdx := hdr["Direction"], defIdx := hdr["Default"], cliIdx := hdr["Command-Line Friendly ID"]
    maxIdx := Max(dirIdx, defIdx, cliIdx)
    for idx, line in lines {
        if (idx = 1)
            continue
        c := StrSplit(line, "`t")
        if (c.Length < maxIdx)
            continue
        if (c[defIdx] = "Render" && c[dirIdx] = "Render")
            return c[cliIdx]
    }
    return ""
}

DeviceInDump(dump, cliId) => InStr(dump, cliId) > 0

; Find the full Command-Line Friendly ID of a Render Device whose ID begins
; with `prefix`. Returns "" if no match. This is what lets us tolerate the
; "Device Name" component flipping (e.g. "Sonyxm4" -> "Headphones") across
; A2DP profile re-init cycles.
ResolveRenderId(dump, prefix) {
    lines := StrSplit(dump, "`n", "`r")
    if (lines.Length < 2)
        return ""
    hdr := ParseHeader(lines[1])
    if !(hdr.Has("Type") && hdr.Has("Direction") && hdr.Has("Command-Line Friendly ID"))
        return ""
    typeIdx := hdr["Type"], dirIdx := hdr["Direction"], cliIdx := hdr["Command-Line Friendly ID"]
    maxIdx := Max(typeIdx, dirIdx, cliIdx)
    for idx, line in lines {
        if (idx = 1)
            continue
        c := StrSplit(line, "`t")
        if (c.Length < maxIdx)
            continue
        if (c[typeIdx] = "Device" && c[dirIdx] = "Render" && InStr(c[cliIdx], prefix) = 1)
            return c[cliIdx]
    }
    return ""
}

SetDefault(cliId) {
    RunWait('"' SVV '" /SetDefault "' cliId '" all',, "Hide")
}

; --- BT connect (async fire-and-forget) ---
; Caller polls SVV in WaitForPrimary; we don't block on PS exit. This lets
; AHK SetDefault the moment Windows registers the audio endpoint, which can
; happen 100-300ms before PS exit cleanup completes.
BtConnect(mac) {
    logOut := AppDir "\bt-connect.log"
    cmd := A_ComSpec ' /C powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' BT_CONNECT '" -Mac ' mac ' > "' logOut '" 2>&1'
    Log("BtConnect started (async)")
    Run(cmd, , "Hide")
}

; --- BT disconnect (sync; tears down audio profiles so device frees up) ---
BtDisconnect(mac) {
    logOut := AppDir "\bt-disconnect.log"
    cmd := A_ComSpec ' /C powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' BT_DISCONNECT '" -Mac ' mac ' > "' logOut '" 2>&1'
    t0 := A_TickCount
    exit := RunWait(cmd,, "Hide")
    Log("BtDisconnect exit=" exit " ms=" (A_TickCount - t0))
    return exit
}

; Wait until BT device endpoint appears in SVV dump.
; Returns full resolved Command-Line Friendly ID on success, or "" on timeout.
; Polls every 100ms - runs in parallel with the async PS script.
WaitForPrimary(maxMs := 12000) {
    t0 := A_TickCount
    deadline := t0 + maxMs
    attempts := 0
    while (A_TickCount < deadline) {
        attempts++
        dump := SvvDump()
        id := ResolveRenderId(dump, PRIMARY_MATCH)
        if (id != "") {
            Log("WaitForPrimary OK after " attempts " attempts (" (A_TickCount - t0) " ms) id=" id)
            return id
        }
        Sleep 100
    }
    Log("WaitForPrimary FAILED after " attempts " attempts (" (A_TickCount - t0) " ms)")
    return ""
}

Toast(msg) {
    if !SHOW_TOAST
        return
    TrayTip("Audio toggle", msg, 0x1)
    SetTimer(() => TrayTip(), -1800)
}

Toggle() {
    dump := SvvDump()
    if (dump = "") {
        Toast("SoundVolumeView dump failed")
        return
    }
    currentId := GetDefaultPlaybackId(dump)

    ; --- Switching AWAY from BT device ---
    ; Default is the BT device -> swap to fallback first (so audio doesn't cut
    ; to silence), then fully tear down BT audio profiles so the device frees
    ; up for other hosts.
    if (InStr(currentId, PRIMARY_MATCH) = 1) {
        target := DeviceInDump(dump, FALLBACK_1) ? FALLBACK_1 : FALLBACK_2
        SetDefault(target)
        BtDisconnect(PRIMARY_MAC)
        Toast(PRIMARY_LABEL " disconnected (free for phone)")
        return
    }

    ; --- Switching TO BT device ---
    primaryId := ResolveRenderId(dump, PRIMARY_MATCH)
    if (primaryId = "") {
        Log(PRIMARY_LABEL " not present, triggering BT reconnect (MAC=" PRIMARY_MAC ")")
        Toast("Reconnecting " PRIMARY_LABEL "...")
        BtConnect(PRIMARY_MAC)               ; async
        primaryId := WaitForPrimary(12000)   ; parallel poll
        if (primaryId = "") {
            ; First attempt missed - launch a second cycle and wait again.
            Log("Retrying BT reconnect once")
            BtConnect(PRIMARY_MAC)
            primaryId := WaitForPrimary(10000)
            if (primaryId = "") {
                Toast("Reconnect failed - check toggle.log")
                return
            }
        }
    }
    SetDefault(primaryId)
    Log("SetDefault primary done id=" primaryId)
    Toast("Switched to " PRIMARY_LABEL)
}

; --- Hotkey ---
; Hotkey string and guard modifier come from config.ini.
; Default: ~Space & s with Control as guard = "Ctrl + Space + S" 3-key chord.
; ~ keeps Space's normal typing working; Space acts as prefix; the inner
; GetKeyState(guard) check disambiguates from plain Space+S.
;
; To change the hotkey, edit config.ini [ui] hotkey/hotkey_guard, then restart.
; Examples: hotkey="^!s" guard="" (Ctrl+Alt+S, no extra guard)
;           hotkey="#F1"  guard="" (Win+F1)
HotkeyHandler(*) {
    if (HOTKEY_GUARD = "" || GetKeyState(HOTKEY_GUARD, "P"))
        Toggle()
}
Hotkey HOTKEY_STR, HotkeyHandler
