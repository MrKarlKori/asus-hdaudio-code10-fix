# Deep-Dive Technical Analysis: Intel 6-Series HD Audio (`VEN_8086&DEV_1C20`) Code 10 on Windows 10/11

## 1. Executive Summary

On affected Intel 6-Series (Cougar Point / HM65) laptops (such as the **ASUS K73SV** running BIOS `K73SV.205`), onboard audio works out-of-the-box on Ubuntu Linux, but fails on Windows 10/11 with **Device Manager Code 10 (`CM_PROB_FAILED_START`, `STATUS_UNSUCCESSFUL` / `0xC0000001`)** on the **High Definition Audio Controller (`PCI\VEN_8086&DEV_1C20`)**, with zero child codecs enumerated on the HDA link.

Through kernel WPP tracing of `HDAudBus.sys` and `pci.sys`, binary disassembly of `HDAudBus.sys` (`HdaController::Init`), live inspection of transient `ALLOC_LOG_CONF` descriptors via `cfgmgr32.dll`, and ACPI DSDT decompilation, we proved the exact root cause:

1. **Unassigned Boot BAR0:** The BIOS leaves the HD Audio controller (`00:1B.0`, `\_SB.PCI0.HDEF`) with `BAR0` unallocated at boot (no `BOOT_LOG_CONF`).
2. **Erroneous `0xFED40000` Window in `PCI0._CRS`:** When no discrete TPM is installed (`TPMF == 0`), the BIOS's `\_SB.PCI0._CRS` method exposes the physical address range **`0xFED40000 - 0xFED44FFF` (20 KB)** as a generic `ResourceProducer` PCI memory window (`MTPM`).
3. **Top-Down PCI Allocation into Dead Silicon Space:** Windows 10/11's PCI memory arbiter (`pci.sys`) allocates unassigned MMIO BARs **top-down** from the highest window in `ACPI\PNP0A08\0`. Because `0xFED40000 - 0xFED44FFF` (20 KB) sits above the normal `0xDF600000` Bus 0 PCI hole and is large enough to hold HD Audio's 16 KB (`0x4000`) `BAR0`, Windows assigns **`BAR0 = 0xFED40000 - 0xFED43FFF`**.
4. **Hardware Master-Abort (`0xFFFFFFFF`):** On Intel 6-Series chipsets, `0xFED40000 - 0xFED44FFF` is permanently decoded in silicon for **Intel TXT / TPM / LPC cycles** and is never routed to internal PCI devices. Every MMIO read by `HDAudBus.sys` at `0xFED40000` returns `0xFFFFFFFF`. Reading `0xFFFF` from `GCAP` (`BAR0 + 0x00`) tricks `HDAudBus!HdaController::Init` into believing the controller has 61 DMA streams; polling Stream #60 (`BAR0 + 0x800`) to stop DMA times out with `STATUS_IO_TIMEOUT` (`0xC00000B5`), causing `HdaController::Init` to abort with `STATUS_UNSUCCESSFUL` (`0xC0000001`).

---

## 2. Reference Hardware & Firmware Profile

| Component | Details |
| :--- | :--- |
| **System Model** | ASUS K73SV (Intel HM65 Express Chipset / Sandy Bridge) |
| **BIOS Version** | AMI Aptio `K73SV.205` (Release Date: `2011-04-01`) |
| **OS Tested** | Windows 10 22H2 (Build 19045, x64) |
| **HDA Controller** | `PCI\VEN_8086&DEV_1C20&SUBSYS_1AA31043&REV_05` (Bus 0, Device 27, Function 0 / `00:1B.0`) |
| **Audio Codecs** | Realtek ALC269 (`HDAUDIO\FUNC_01&VEN_10EC&DEV_0269&SUBSYS_10431AA3`) & Intel HDMI (`VEN_8086&DEV_2805`) |

---

## 3. Step-by-Step Root Cause Proof

### 3.1. ACPI DSDT Analysis (`\_SB.PCI0._CRS`)

In the decompiled DSDT, `\_SB.PCI0._CRS` constructs the list of MMIO windows produced by the PCI Root Bridge (`ACPI\PNP0A08\0`). It defines a 20 KB (`0x5000`) `DWordMemory` descriptor named `MTPM` at `0xFED40000 - 0xFED44FFF`:

```asl
DWordMemory (ResourceProducer, PosDecode, MinFixed, MaxFixed, NonCacheable, ReadWrite,
    0x00000000,         // Granularity
    0xFED40000,         // Range Minimum
    0xFED44FFF,         // Range Maximum
    0x00000000,         // Translation Offset
    0x00005000,         // Length (20 KB)
    ,, _Y0F, AddressRangeMemory, TypeStatic)
```

Inside `_CRS`, the AML checks `If (TPMF)`:
- If a TPM is present (`TPMF != 0`), it sets `MTPM._LEN = 0` so the PCI bus cannot use `0xFED40000`.
- If no TPM is present (`TPMF == 0`), it leaves `0xFED40000 - 0xFED44FFF` active as a **general-purpose PCI Root Bridge memory window**.

Meanwhile, the sibling Intel 6-Series devices on PCI Bus 0 all have valid `BOOT_LOG_CONF` allocations placed by the BIOS in the `0xDF600000` range:
- `PCI\VEN_8086&DEV_1C03` (SATA AHCI): `0xDF606000 - 0xDF6067FF`
- `PCI\VEN_8086&DEV_1C26` (EHCI USB #1): `0xDF607000 - 0xDF6073FF`
- `PCI\VEN_8086&DEV_1C2D` (EHCI USB #2): `0xDF608000 - 0xDF6083FF`
- `PCI\VEN_8086&DEV_1C3A` (MEI Controller): `0xDF60B000 - 0xDF60B00F`

`PCI\VEN_8086&DEV_1C20` (HD Audio) has no `BOOT_LOG_CONF`, leaving `0xDF600000 - 0xDF603FFF` (16 KB) unused while Windows allocates top-down from `ACPI\PNP0A08\0` and picks `0xFED40000 - 0xFED43FFF`.

---

### 3.2. Capturing the Transient `ALLOC_LOG_CONF` (`0xFED40000`)

Because Windows PnP automatically frees a device's `ALLOC_LOG_CONF` as soon as `IRP_MN_START_DEVICE` fails with Code 10, Device Manager shows no resources when inspected after boot. By polling `CM_Get_First_Log_Conf_Ex(..., ALLOC_LOG_CONF)` in a tight 1 ms loop during `pnputil /restart-device`, we captured the exact resources assigned to `PCI\VEN_8086&DEV_1C20` during `StartDevice`:

```text
Captured ALLOC_LOG_CONF at iteration 20!
ResType 1 (Memory): Start=0xFED40000 Length=0x4000 (End=0xFED43FFF)
ResType 2 (IRQ):    RAW=24 bytes
```

---

### 3.3. Kernel WPP Trace & Disassembly of `HDAudBus.sys`

Capturing a kernel ETW/WPP session for `HDAudBus.sys` (Provider GUID `{b3a109ec-1cb3-4947-95ed-431033eeb1b4}`) during device start produced 4 events:

| Event ID | Trace MessageGUID | Function | Decoded Payload |
| :--- | :--- | :--- | :--- |
| **26** | `ead5ad86-6902-360e-e587-8cf1d219f2d7` | `HdAudBusResourceList::Create` | `FDO 0xFFFFCA8FB5CC2B90`, Status `0x00000000` |
| **50** | `0497f899-9da4-3669-d6bf-e6ba04f073db` | `HdaController::Init` | Mapped `BAR0` (`Length = 0x4000`) to `0xFFFF8781C4ED3000` |
| **51** | `0497f899-9da4-3669-d6bf-e6ba04f073db` | `HdaController::SetDmaEngineState` | Stream index `0x3C` (`60`), target state `0`, failed with **`0xC00000B5` (`STATUS_IO_TIMEOUT`)** |
| **58** | `0497f899-9da4-3669-d6bf-e6ba04f073db` | `HdaController::Init` | Controller initialization failed with **`0xC0000001` (`STATUS_UNSUCCESSFUL`)** |

Disassembling `HDAudBus!HdaController::Init` and `HDAudBus!HdaController::SetDmaEngineState` with `hdaudbus.pdb` explains why Event 51 and Event 58 occur:
1. `HdaController::Init` maps physical `BAR0` (`0xFED40000`, length `0x4000`) via `MmMapIoSpaceEx` (Event 50).
2. It reads the **Global Control (`GCTL`)** register at `BAR0 + 0x08`:
   ```asm
   mov rax, qword ptr [rbx+30h] ; BAR0 virtual address
   add rax, 8
   mov eax, dword ptr [rax]     ; reads GCTL
   bt   eax, 0                   ; tests bit 0 (CRST - Controller Reset)
   ```
   Because `0xFED40000` is unrouted, reading `BAR0 + 0x08` returns **`0xFFFFFFFF`**, so bit 0 (`CRST`) is **`1`**.
3. Seeing `CRST == 1`, `HdaController::Init` reads **Global Capabilities (`GCAP`)** at `BAR0 + 0x00` (`0xFFFF`), extracts the 4-bit fields `ISS` (`15`), `OSS` (`15`), and `BSS` (`31`), and calculates `15 + 15 + 31 = 61` DMA streams (`0..60`).
4. It loops backward from stream `60` (`0x3C`) down to `0`, calling `HdaController::SetDmaEngineState` to clear the `RUN` bit (`bit 1`) of each stream descriptor control register (`SDnCTL`).
5. For stream `60` (`BAR0 + 0x800`), `SetDmaEngineState` clears bit 1, writes `0xFD` back, and polls `BAR0 + 0x800` up to 400 times waiting for `bit 1 == 0`. Because every read returns `0xFF`, the loop exhausts all 400 iterations, logs **Event 51 (`STATUS_IO_TIMEOUT`, `0xC00000B5`)**, and `HdaController::Init` returns **`0xC0000001` (`STATUS_UNSUCCESSFUL`, Event 58)**.

---

## 4. The Native Windows Solution (`OverrideConfigVector`)

To prevent `pci.sys` from allocating `0xFED40000` to `PCI\VEN_8086&DEV_1C20`, we write a standard 168-byte **`REG_RESOURCE_REQUIREMENTS_LIST`** (Registry Type `10`) to:

`HKLM\SYSTEM\CurrentControlSet\Enum\PCI\VEN_8086&DEV_1C20...\LogConf\OverrideConfigVector`

The resource requirements list contains one `IO_RESOURCE_LIST` with three `IO_RESOURCE_DESCRIPTOR` entries matching `BasicConfigVector`, except the 64-bit Memory descriptor (`Type = 3`, `Length = 0x4000`, `Alignment = 0x4000`) has its `MinimumAddress` and `MaximumAddress` constrained to **`0xDF600000 - 0xDF603FFF`** (or the detected `0x..600000 - 0x..603FFF` Bus 0 chipset aperture on systems with a different RAM split).

When the device node is restarted via `CM_Disable_DevNode` / `CM_Enable_DevNode`:
- `pci.sys` allocates **`BAR0 = 0xDF600000 - 0xDF603FFF`** and **`IRQ 22`**.
- `HDAudBus.sys` maps `0xDF600000`, reads the real Intel HM65 HD Audio registers (`GCAP = 0x4401`: 4 ISS, 4 OSS, 0 BSS), brings the HDA link out of reset, and immediately enumerates both the **Realtek ALC269** (`VEN_10EC&DEV_0269`) and **Intel HDMI** (`VEN_8086&DEV_2805`) codecs.
