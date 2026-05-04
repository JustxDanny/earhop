# Force-connect a paired classic-Bluetooth audio device on Windows 10/11.
# ASCII-only on purpose: PowerShell 5.1 reads .ps1 as ANSI when there is no BOM,
# and a stray non-ASCII byte (em-dash, smart quote) breaks quote balancing.
#
# Strategy (two-stage):
#
#   Stage 1 - WAKE THE DEVICE (bring up the Classic BT ACL link).
#       SDP probe via WinRT GetRfcommServicesAsync(Uncached). The Uncached
#       flag forces a fresh baseband inquiry which wakes a sleeping device.
#       The link tends to flip ConnectionStatus = Connected as a side effect
#       even when the SDP call itself returns a timeout.
#
#   Stage 2 - ACTIVATE THE A2DP AUDIO PROFILE.
#       BluetoothSetServiceState(A2DP_SINK, DISABLE) then (ENABLE) on the
#       A2DP Sink GUID. This is what makes Windows enumerate the audio
#       Render endpoint in MMDevice and make it visible to apps.
#
#       Critical detail: ENABLE alone returns rc=87 (ERROR_INVALID_PARAMETER)
#       when the service is already in the enabled state - Windows rejects
#       no-op transitions. The DISABLE/ENABLE toggle forces a real state
#       transition and the audio endpoint pops up within ~1 second.
#
#       Same cycle for AVRCP_CT so media keys work AND because on some
#       device firmwares the A2DP cycle alone returns rc=0 but the audio
#       endpoint never registers - the AVRCP cycle is what unsticks it.
#
# Exit codes:
#   0 = profile cycle attempted (Render endpoint should appear in SVV soon)
#   1 = uncaught error
#   2 = device not found / no BT radio
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File bt-connect.ps1 -Mac AABBCCDDEEFF

param(
    [Parameter(Mandatory=$true)][string]$Mac,
    [int]$WakeRetries  = 2,
    [int]$WakeDelayMs  = 400,
    [int]$SocketHoldMs = 800,    # enough to register ACL link without overpaying
    [int]$CycleGapMs   = 250,
    [int]$SdpTimeoutMs = 2500    # SDP that hasn't replied in 2.5s isn't going to
)

# ---------- Win32 P/Invoke for BluetoothSetServiceState ----------
$src = @'
using System;
using System.Runtime.InteropServices;
public static class Bt {
    [StructLayout(LayoutKind.Sequential)]
    public struct BLUETOOTH_FIND_RADIO_PARAMS { public uint dwSize; }

    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEMTIME { public ushort y,mo,dw,d,h,mi,s,ms; }

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct BLUETOOTH_DEVICE_INFO {
        public uint dwSize;
        public ulong Address;
        public uint ulClassofDevice;
        [MarshalAs(UnmanagedType.Bool)] public bool fConnected;
        [MarshalAs(UnmanagedType.Bool)] public bool fRemembered;
        [MarshalAs(UnmanagedType.Bool)] public bool fAuthenticated;
        public SYSTEMTIME stLastSeen;
        public SYSTEMTIME stLastUsed;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=248)] public string szName;
    }

    [DllImport("bluetoothapis.dll")] public static extern IntPtr BluetoothFindFirstRadio(ref BLUETOOTH_FIND_RADIO_PARAMS p, out IntPtr h);
    [DllImport("bluetoothapis.dll")] public static extern bool BluetoothFindRadioClose(IntPtr h);
    [DllImport("bluetoothapis.dll")] public static extern uint BluetoothGetDeviceInfo(IntPtr hRadio, ref BLUETOOTH_DEVICE_INFO pbtdi);
    [DllImport("bluetoothapis.dll")] public static extern uint BluetoothSetServiceState(IntPtr hRadio, ref BLUETOOTH_DEVICE_INFO pbtdi, ref Guid pGuidService, uint dwServiceFlags);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
'@
Add-Type -TypeDefinition $src

# ---------- WinRT helpers (used for wake / status) ----------
[void][Windows.Devices.Bluetooth.BluetoothDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]
[void][Windows.Devices.Bluetooth.Rfcomm.RfcommDeviceService, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]
[void][Windows.Networking.Sockets.StreamSocket, Windows.Networking.Sockets, ContentType=WindowsRuntime]
Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction SilentlyContinue

$asTaskOp = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } |
    Select-Object -First 1
$asTaskAction = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } |
    Select-Object -First 1

function AwaitOp($op, [Type]$resultType, [int]$timeoutMs = 6000) {
    $task = $asTaskOp.MakeGenericMethod($resultType).Invoke($null, @($op))
    if (-not $task.Wait($timeoutMs)) { throw 'WinRT op timeout' }
    if ($task.IsFaulted) { throw $task.Exception }
    return $task.Result
}

function AwaitAction($op, [int]$timeoutMs = 6000) {
    $task = $asTaskAction.Invoke($null, @($op))
    if (-not $task.Wait($timeoutMs)) { throw 'WinRT action timeout' }
    if ($task.IsFaulted) { throw $task.Exception }
}

function GetDev([uint64]$a) {
    return AwaitOp ([Windows.Devices.Bluetooth.BluetoothDevice]::FromBluetoothAddressAsync($a)) ([Windows.Devices.Bluetooth.BluetoothDevice])
}

# ---------- main ----------
$addr = [Convert]::ToUInt64($Mac.Replace(':','').Replace('-',''), 16)
$hRadio = [IntPtr]::Zero
$hFind  = [IntPtr]::Zero

try {
    $find = New-Object Bt+BLUETOOTH_FIND_RADIO_PARAMS
    $find.dwSize = [System.Runtime.InteropServices.Marshal]::SizeOf($find)
    $hFind  = [Bt]::BluetoothFindFirstRadio([ref]$find, [ref]$hRadio)
    if ($hFind -eq [IntPtr]::Zero) {
        Write-Host 'No BT radio'
        exit 2
    }

    $di = New-Object Bt+BLUETOOTH_DEVICE_INFO
    $di.dwSize  = [System.Runtime.InteropServices.Marshal]::SizeOf($di)
    $di.Address = $addr
    $rc = [Bt]::BluetoothGetDeviceInfo($hRadio, [ref]$di)
    if ($rc -ne 0) {
        Write-Host ('GetDeviceInfo failed rc={0}' -f $rc)
        exit 2
    }
    Write-Host ('Device: {0}  fConn={1} Auth={2}' -f $di.szName, $di.fConnected, $di.fAuthenticated)

    # ---- STAGE 1: SDP wake ----
    # Single SDP probe. The probe forces a baseband inquiry which establishes
    # the BT ACL link as a side effect (status flips Connected even if the SDP
    # call itself returns timeout). Skipped if already Connected per BT radio.
    if (-not $di.fConnected) {
        try {
            $dev = GetDev $addr
            [void](AwaitOp ($dev.GetRfcommServicesAsync([Windows.Devices.Bluetooth.BluetoothCacheMode]::Uncached)) ([Windows.Devices.Bluetooth.Rfcomm.RfcommDeviceServicesResult]) $SdpTimeoutMs)
            Write-Host '  SDP wake done'
        } catch {
            Write-Host ('  SDP wake threw: {0}' -f $_.Exception.Message)
        }
        [void][Bt]::BluetoothGetDeviceInfo($hRadio, [ref]$di)
    }

    # ---- STAGE 2: A2DP cycle ----
    # Re-query device info because fConnected may have flipped.
    [void][Bt]::BluetoothGetDeviceInfo($hRadio, [ref]$di)

    # A2DP + AVRCP cycle. Both required: A2DP for audio endpoint registration,
    # AVRCP empirically also needed on some device firmwares (without it,
    # A2DP ENABLE returns rc=0 but the Render endpoint stays invisible to
    # MMDevice). Interleaved: both DISABLE first, then both ENABLE.
    $a2dp  = [Guid]::new('0000110B-0000-1000-8000-00805F9B34FB')
    $avrcp = [Guid]::new('0000110E-0000-1000-8000-00805F9B34FB')
    $rcAd = [Bt]::BluetoothSetServiceState($hRadio, [ref]$di, [ref]$a2dp,  0x00)
    $rcVd = [Bt]::BluetoothSetServiceState($hRadio, [ref]$di, [ref]$avrcp, 0x00)
    Start-Sleep -Milliseconds $CycleGapMs
    $rcAe = [Bt]::BluetoothSetServiceState($hRadio, [ref]$di, [ref]$a2dp,  0x01)
    $rcVe = [Bt]::BluetoothSetServiceState($hRadio, [ref]$di, [ref]$avrcp, 0x01)
    Write-Host ('  A2DP  DISABLE rc={0}  ENABLE rc={1}' -f $rcAd, $rcAe)
    Write-Host ('  AVRCP DISABLE rc={0}  ENABLE rc={1}' -f $rcVd, $rcVe)

    # No final verify - AHK polls SVV next, that's the source of truth.
    exit 0
} catch {
    Write-Host ('ERROR: {0}' -f $_.Exception.Message)
    exit 1
} finally {
    if ($hRadio -ne [IntPtr]::Zero) { [Bt]::CloseHandle($hRadio) | Out-Null }
    if ($hFind  -ne [IntPtr]::Zero) { [Bt]::BluetoothFindRadioClose($hFind) | Out-Null }
}
