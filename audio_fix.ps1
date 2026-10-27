#Requires -Version 5.1
<#
.SYNOPSIS
    Fixes "High Definition Audio Controller" (PCI\VEN_8086&DEV_1C20) Code 10 on Windows 10/11
    for ASUS K73SV / K53SV / X73SV / N73SV and other Intel 6-Series (HM65) laptops.

.DESCRIPTION
    Applies a standard Windows PnP OverrideConfigVector (REG_RESOURCE_REQUIREMENTS_LIST)
    so Windows allocates BAR0 (16 KB) in the valid Bus 0 chipset MMIO aperture (e.g. 0xDF600000-0xDF603FFF)
    instead of the dead Intel PCH TPM/LPC fixed range (0xFED40000-0xFED43FFF) erroneously exposed in PCI0._CRS.

.PARAMETER Step
    - fix    : Applies OverrideConfigVector and restarts the HD Audio Controller (Default).
    - status : Displays current controller, codec, and audio endpoint status.
    - undo   : Removes OverrideConfigVector and restarts the controller.

.PARAMETER BaseAddress
    Optional uint64 override for the 16 KB BAR0 base address. If omitted, the script auto-detects
    the Bus 0 chipset MMIO prefix (e.g. 0xDF600000) from sibling Intel 6-Series PCI devices.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("fix", "status", "undo")]
    [string]$Step = "fix",

    [Parameter(Mandatory = $false)]
    [uint64]$BaseAddress = 0
)

$ErrorActionPreference = "Stop"

function Test-Admin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-HdaController {
    $devs = @(Get-PnpDevice -InstanceId "PCI\VEN_8086&DEV_1C20*" -ErrorAction SilentlyContinue)
    if ($devs.Count -eq 0) {
        throw "Could not find an Intel 6-Series High Definition Audio Controller (PCI\VEN_8086&DEV_1C20*)."
    }
    return $devs[0].InstanceId
}

$CsSource = @"
using System;
using System.Runtime.InteropServices;

public class PnpConfigHelper {
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int RegOpenKeyExW(IntPtr hKey, string lpSubKey, uint ulOptions, int samDesired, out IntPtr phkResult);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int RegSetValueExW(IntPtr hKey, string lpValueName, uint Reserved, uint dwType, byte[] lpData, uint cbData);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int RegDeleteValueW(IntPtr hKey, string lpValueName);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern int RegCloseKey(IntPtr hKey);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    public static extern int CM_Locate_DevNodeW(out uint pdnDevInst, string pDeviceID, uint ulFlags);

    [DllImport("cfgmgr32.dll")]
    public static extern int CM_Disable_DevNode(uint dnDevInst, uint ulFlags);

    [DllImport("cfgmgr32.dll")]
    public static extern int CM_Enable_DevNode(uint dnDevInst, uint ulFlags);

    [DllImport("cfgmgr32.dll")]
    public static extern int CM_Setup_DevNode(uint dnDevInst, uint ulFlags);

    [DllImport("cfgmgr32.dll")]
    public static extern int CM_Get_DevNode_Status(out uint pulStatus, out uint pulProblemNumber, uint dnDevInst, uint ulFlags);

    [DllImport("cfgmgr32.dll")]
    public static extern int CM_Get_First_Log_Conf_Ex(out IntPtr plcLogConf, uint dnDevInst, uint ulFlags, IntPtr hMachine);

    [DllImport("cfgmgr32.dll")]
    public static extern int CM_Get_Next_Res_Des_Ex(out IntPtr prdResDes, IntPtr rdResDes, uint ForResource, out uint pResourceID, uint ulFlags, IntPtr hMachine);

    [DllImport("cfgmgr32.dll")]
    public static extern int CM_Get_Res_Des_Data_Size_Ex(out uint pulSize, IntPtr rdResDes, uint ulFlags, IntPtr hMachine);

    [DllImport("cfgmgr32.dll")]
    public static extern int CM_Get_Res_Des_Data_Ex(IntPtr rdResDes, byte[] Buffer, uint BufferLen, uint ulFlags, IntPtr hMachine);

    [DllImport("cfgmgr32.dll")]
    public static extern int CM_Free_Res_Des_Handle(IntPtr rdResDes);

    [DllImport("cfgmgr32.dll")]
    public static extern int CM_Free_Log_Conf_Handle(IntPtr lcLogConf);

    public static UInt64 GetDeviceMemoryBase(string instanceId, uint logConfType) {
        uint dn;
        if (CM_Locate_DevNodeW(out dn, instanceId, 0) != 0) return 0;
        IntPtr lc;
        if (CM_Get_First_Log_Conf_Ex(out lc, dn, logConfType, IntPtr.Zero) != 0) return 0;
        IntPtr prev = lc;
        bool isFirst = true;
        UInt64 foundBase = 0;
        while (true) {
            IntPtr next;
            uint resType;
            int cr = CM_Get_Next_Res_Des_Ex(out next, prev, 0, out resType, 0, IntPtr.Zero);
            if (!isFirst) CM_Free_Res_Des_Handle(prev);
            isFirst = false;
            if (cr != 0) break;
            if (resType == 1) { // CmResourceTypeMemory
                uint sz;
                if (CM_Get_Res_Des_Data_Size_Ex(out sz, next, 0, IntPtr.Zero) == 0 && sz >= 24) {
                    byte[] buf = new byte[sz];
                    if (CM_Get_Res_Des_Data_Ex(next, buf, sz, 0, IntPtr.Zero) == 0) {
                        foundBase = BitConverter.ToUInt64(buf, 8);
                    }
                }
            }
            prev = next;
        }
        CM_Free_Log_Conf_Handle(lc);
        return foundBase;
    }

    public static void RestartDevice(string instanceId, out uint status, out uint prob) {
        uint dn;
        CM_Locate_DevNodeW(out dn, instanceId, 0);
        CM_Disable_DevNode(dn, 0);
        System.Threading.Thread.Sleep(500);
        CM_Enable_DevNode(dn, 0);
        CM_Setup_DevNode(dn, 4); // CM_SETUP_DEVNODE_RESET
        System.Threading.Thread.Sleep(2500);
        CM_Get_DevNode_Status(out status, out prob, dn, 0);
    }
}
"@

if (-not ("PnpConfigHelper" -as [type])) {
    Add-Type -TypeDefinition $CsSource
}

function Resolve-TargetBaseAddress {
    param([uint64]$ExplicitBase)
    if ($ExplicitBase -ne 0) {
        return $ExplicitBase
    }
    $minValid = [uint64]::Parse("80000000", [System.Globalization.NumberStyles]::HexNumber)
    $maxValid = [uint64]::Parse("FED00000", [System.Globalization.NumberStyles]::HexNumber)
    $mask64k  = [uint64]::Parse("FFFFFFFFFFFF0000", [System.Globalization.NumberStyles]::HexNumber)

    # Check sibling Intel 6-Series Bus 0 devices (SATA 1C03, USB 1C26, USB 1C2D, MEI 1C3A)
    $siblings = @("PCI\VEN_8086&DEV_1C03*", "PCI\VEN_8086&DEV_1C26*", "PCI\VEN_8086&DEV_1C2D*", "PCI\VEN_8086&DEV_1C3A*")
    foreach ($pattern in $siblings) {
        $devs = @(Get-PnpDevice -InstanceId $pattern -ErrorAction SilentlyContinue)
        foreach ($d in $devs) {
            # Check ALLOC_LOG_CONF (2) or BOOT_LOG_CONF (1)
            foreach ($confType in @(2, 1)) {
                $addr = [PnpConfigHelper]::GetDeviceMemoryBase($d.InstanceId, [uint32]$confType)
                if ($addr -gt $minValid -and $addr -lt $maxValid) {
                    # Align down to the 64 KB (0x10000) Bus 0 peripheral block (e.g. 0xDF606000 -> 0xDF600000)
                    $candidate = $addr -band $mask64k
                    Write-Host ("Auto-detected Bus 0 chipset MMIO aperture from {0} (0x{1:X8}) -> 0x{2:X8}" -f $d.InstanceId, $addr, $candidate) -ForegroundColor Cyan
                    return $candidate
                }
            }
        }
    }
    Write-Host "Using default ASUS K73SV Bus 0 MMIO base address: 0xDF600000" -ForegroundColor Yellow
    return [uint64]::Parse("DF600000", [System.Globalization.NumberStyles]::HexNumber)
}

function Show-AudioStatus {
    $hdaId = Find-HdaController
    Write-Host "`n=== High Definition Audio Controller ===" -ForegroundColor Cyan
    & pnputil /enum-devices /instanceid $hdaId

    $allocBase = [PnpConfigHelper]::GetDeviceMemoryBase($hdaId, 2)
    if ($allocBase -ne 0) {
        Write-Host ("Allocated BAR0 Memory: 0x{0:X8} - 0x{1:X8}" -f $allocBase, ($allocBase + [uint64]0x3FFF)) -ForegroundColor Green
    } else {
        Write-Host "Allocated BAR0 Memory: None (Controller not started)" -ForegroundColor Yellow
    }

    Write-Host "`n=== Enumerated HDAUDIO Codecs ===" -ForegroundColor Cyan
    $codecs = @(Get-PnpDevice -InstanceId "HDAUDIO\*" -ErrorAction SilentlyContinue)
    if ($codecs.Count -gt 0) {
        $codecs | Select-Object Status, FriendlyName, InstanceId | Format-Table -AutoSize
    } else {
        Write-Host "No HDAUDIO codecs found." -ForegroundColor Yellow
    }

    Write-Host "=== Active Audio Endpoints ===" -ForegroundColor Cyan
    $endpoints = @(Get-PnpDevice -Class AudioEndpoint -Status OK -ErrorAction SilentlyContinue)
    if ($endpoints.Count -gt 0) {
        $endpoints | Select-Object Status, FriendlyName | Format-Table -AutoSize
    } else {
        Write-Host "No active audio endpoints found." -ForegroundColor Yellow
    }
}

switch ($Step) {
    "status" {
        Show-AudioStatus
    }

    "fix" {
        if (-not (Test-Admin)) {
            Write-Error "Administrator privileges are required to apply the fix. Please re-run PowerShell as Administrator."
        }
        $hdaId = Find-HdaController
        $logConfSubKey = "SYSTEM\CurrentControlSet\Enum\$hdaId\LogConf"
        $regPath = "HKLM:\$logConfSubKey"

        $basic = (Get-ItemProperty -Path $regPath -Name "BasicConfigVector" -ErrorAction Stop).BasicConfigVector
        if ($basic.Length -lt 104) {
            throw "Unexpected BasicConfigVector length ($($basic.Length) bytes)."
        }

        $minAddr = Resolve-TargetBaseAddress -ExplicitBase $BaseAddress
        $maxAddr = $minAddr + [uint64]0x3FFF

        # Construct a single-list REG_RESOURCE_REQUIREMENTS_LIST (168 bytes) from BasicConfigVector
        [byte[]]$override = New-Object byte[] 168
        [Array]::Copy($basic, 0, $override, 0, 168)

        # ListSize = 168 (0xA8), AlternativeLists = 1
        [BitConverter]::GetBytes([uint32]168).CopyTo($override, 0)
        [BitConverter]::GetBytes([uint32]1).CopyTo($override, 32)
        # Descriptor Count = 3 (Memory + DevicePrivate + Interrupt)
        [BitConverter]::GetBytes([uint32]3).CopyTo($override, 36)

        # Constrain Descriptor 0 (CmResourceTypeMemory) to $minAddr .. $maxAddr
        [BitConverter]::GetBytes($minAddr).CopyTo($override, 56)
        [BitConverter]::GetBytes($maxAddr).CopyTo($override, 64)

        $HKLM = [IntPtr]0x80000002
        $hKey = [IntPtr]::Zero
        $res = [PnpConfigHelper]::RegOpenKeyExW($HKLM, $logConfSubKey, 0, 0x20006, [ref]$hKey)
        if ($res -ne 0) {
            throw "RegOpenKeyExW failed with Win32 error $res"
        }
        try {
            [void][PnpConfigHelper]::RegDeleteValueW($hKey, "ForcedConfig")
            # Write OverrideConfigVector with REG_RESOURCE_REQUIREMENTS_LIST (type 10)
            $res = [PnpConfigHelper]::RegSetValueExW($hKey, "OverrideConfigVector", 0, 10, $override, [uint32]$override.Length)
            if ($res -ne 0) {
                throw "RegSetValueExW failed with Win32 error $res"
            }
        } finally {
            [void][PnpConfigHelper]::RegCloseKey($hKey)
        }

        Write-Host ("Applied OverrideConfigVector (BAR0 = 0x{0:X8}-0x{1:X8}). Restarting controller..." -f $minAddr, $maxAddr) -ForegroundColor Green
        [uint32]$st = 0
        [uint32]$pr = 0
        [PnpConfigHelper]::RestartDevice($hdaId, [ref]$st, [ref]$pr)
        Write-Host ("Controller DevNode Status=0x{0:X8} Problem=0x{1:X8}" -f $st, $pr) -ForegroundColor Cyan

        Show-AudioStatus
    }

    "undo" {
        if (-not (Test-Admin)) {
            Write-Error "Administrator privileges are required to undo the fix. Please re-run PowerShell as Administrator."
        }
        $hdaId = Find-HdaController
        $logConfSubKey = "SYSTEM\CurrentControlSet\Enum\$hdaId\LogConf"

        $HKLM = [IntPtr]0x80000002
        $hKey = [IntPtr]::Zero
        $res = [PnpConfigHelper]::RegOpenKeyExW($HKLM, $logConfSubKey, 0, 0x20006, [ref]$hKey)
        if ($res -eq 0) {
            [void][PnpConfigHelper]::RegDeleteValueW($hKey, "OverrideConfigVector")
            [void][PnpConfigHelper]::RegDeleteValueW($hKey, "ForcedConfig")
            [void][PnpConfigHelper]::RegCloseKey($hKey)
        }

        Write-Host "Removed OverrideConfigVector. Restarting controller..." -ForegroundColor Yellow
        [uint32]$st = 0
        [uint32]$pr = 0
        [PnpConfigHelper]::RestartDevice($hdaId, [ref]$st, [ref]$pr)
        Show-AudioStatus
    }
}
