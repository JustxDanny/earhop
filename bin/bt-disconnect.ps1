# Disconnect a paired Classic-Bluetooth audio device from this PC.
# Inverse of bt-connect.ps1. Calls BluetoothSetServiceState(DISABLE) on each
# audio-related profile GUID. PC side drops the link; the device becomes free
# for another host (e.g. phone) to connect via A2DP without contention.
#
# DISABLE alone (no ENABLE follow-up) is correct here - we want the profile to
# stay torn down. rc=1168 (ELEMENT_NOT_FOUND) means already disabled, harmless.
#
# Exit codes:
#   0 = all profiles disabled (rc=0 or rc=1168)
#   1 = uncaught error
#   2 = no BT radio
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File bt-disconnect.ps1 -Mac AABBCCDDEEFF

param(
    [Parameter(Mandatory=$true)][string]$Mac
)

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

$addr   = [Convert]::ToUInt64($Mac.Replace(':','').Replace('-',''), 16)
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
    [void][Bt]::BluetoothGetDeviceInfo($hRadio, [ref]$di)
    Write-Host ('Device: {0}  fConn={1}' -f $di.szName, $di.fConnected)

    # Tear down audio + media-key + telephony profiles. HFP/Headset included so
    # incoming phone-call routing also drops back to XM4-on-phone exclusively.
    $profiles = @(
        @{ n='A2DP Sink'; g=[Guid]::new('0000110B-0000-1000-8000-00805F9B34FB') },
        @{ n='AVRCP CT';  g=[Guid]::new('0000110E-0000-1000-8000-00805F9B34FB') },
        @{ n='AVRCP TG';  g=[Guid]::new('0000110C-0000-1000-8000-00805F9B34FB') },
        @{ n='Hands-Free';g=[Guid]::new('0000111E-0000-1000-8000-00805F9B34FB') },
        @{ n='Headset';   g=[Guid]::new('00001108-0000-1000-8000-00805F9B34FB') }
    )
    $DISABLE = 0x00
    foreach ($p in $profiles) {
        $g  = $p.g
        $rc = [Bt]::BluetoothSetServiceState($hRadio, [ref]$di, [ref]$g, $DISABLE)
        Write-Host ('  {0,-11} DISABLE rc={1}' -f $p.n, $rc)
    }

    exit 0
} catch {
    Write-Host ('ERROR: {0}' -f $_.Exception.Message)
    exit 1
} finally {
    if ($hRadio -ne [IntPtr]::Zero) { [Bt]::CloseHandle($hRadio) | Out-Null }
    if ($hFind  -ne [IntPtr]::Zero) { [Bt]::BluetoothFindRadioClose($hFind) | Out-Null }
}
