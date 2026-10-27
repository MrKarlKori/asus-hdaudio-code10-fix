# Fix: "High Definition Audio Controller" Code 10 on Windows 10 / 11 (ASUS K73SV / K53SV / N73SV & Intel 6-Series Laptops)

If you upgraded an older laptop (such as an **ASUS K73SV, K53SV, X73SV, X53SV, N53SV, N73SV**, or another 2011–2013 Intel Sandy Bridge / HM65 laptop) to **Windows 10 or Windows 11** and your onboard speakers/headphone jack completely disappeared:

- Sound works fine in **Ubuntu / Linux** (so you know the speakers and sound chip aren't broken).
- In Windows Device Manager, under **System devices**, **High Definition Audio Controller** (`PCI\VEN_8086&DEV_1C20`) shows a yellow warning icon with **Error Code 10 (`This device cannot start` / `STATUS_UNSUCCESSFUL`)**.
- Reinstalling Realtek drivers does nothing because Windows cannot even see the Realtek audio chip behind the controller.

**This repository fixes the problem permanently in seconds using a built-in Windows Plug-and-Play registry setting — no BIOS flashing, no `testsigning` mode, and no third-party drivers required.**

---

## Why Does This Happen? (In Plain English)

1. **A 2011 BIOS Quirks:** When your laptop boots, the BIOS forgets to pre-assign a memory address (`BAR0`) to the onboard sound controller, leaving it up to the operating system to pick a free 16 KB spot in memory.
2. **A Fake "Free" Memory Spot:** Your BIOS also tells the operating system: *"Hey, this laptop doesn't have a TPM security chip installed, so feel free to use the memory address `0xFED40000` for any PCI device!"*
3. **Why Linux Works & Windows 10/11 Fails:**
   - **Linux** knows `0xFED40000` is permanently hardwired inside Intel chipsets for TPM chips and refuses to put your sound card there.
   - **Windows 10/11** allocates memory from the highest address downward, sees `0xFED40000` at the top of the list, and assigns your sound card to `0xFED40000`.
   - Because the Intel chipset hardware blocks PCI traffic at `0xFED40000`, the Windows audio driver (`HDAudBus.sys`) reads nothing but dead air (`0xFFFFFFFF`), times out, and shuts down with **Code 10**.

### How This Fix Works
Windows has a built-in feature called **`OverrideConfigVector`** that tells the Windows Plug-and-Play manager what memory range a device is allowed to use.

The included PowerShell script (`audio_fix.ps1`):
1. Automatically finds your Intel High Definition Audio Controller in the registry.
2. Checks where your other Intel chipset devices live on PCI Bus 0 (for example, `0xDF606000` for SATA, `0xDF607000` for USB) and picks the matching `0x..600000–0x..603FFF` slot reserved for onboard audio.
3. Saves an `OverrideConfigVector` rule in the Windows Registry so Windows never places the sound controller at `0xFED40000` again.
4. Restarts the audio controller immediately — your **Realtek High Definition Audio** and **Intel HDMI Audio** devices pop right up without even needing a reboot!

---

## Quick Start (How to Apply the Fix)

1. Open **PowerShell as Administrator**:
   - Press `Win + X` and click **Windows PowerShell (Admin)** or **Terminal (Admin)**.
2. Navigate to this folder and run the fix:
   ```powershell
   cd path\to\asus-hdaudio-code10-fix
   powershell -ExecutionPolicy Bypass -File .\audio_fix.ps1 -Step fix
   ```
3. Within 3–5 seconds, you should see the speaker icon in your taskbar light up and **Realtek High Definition Audio** appear in Device Manager with `Status: OK`!

---

## Other Commands

- **Check Current Audio Status:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\audio_fix.ps1 -Step status
  ```
- **Undo / Remove the Fix (Restore Default Windows Behavior):**
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\audio_fix.ps1 -Step undo
  ```

---

## FAQ

### Does this survive reboots and Windows Updates?
**Yes.** The `OverrideConfigVector` is stored in `HKLM\SYSTEM\CurrentControlSet\Enum\PCI\...\LogConf`, which Windows reads every time the system boots. (If you ever do a clean reinstall of Windows from scratch, just run the script once again.)

### Does this disable Secure Boot or require Test Signing?
**No.** Unlike custom DSDT table overrides, `OverrideConfigVector` is a standard, documented Windows Plug-and-Play registry configuration. Secure Boot stays on, and anti-cheat software (Valorant, FaceIt, etc.) is completely unaffected.

### Where can I read the deep-dive kernel & hardware investigation?
See **[TECHNICAL_DETAILS.md](TECHNICAL_DETAILS.md)** for the full ACPI DSDT disassembly, `HDAudBus.sys` WPP kernel trace, disassembly of `HdaController::Init`, and byte-level `REG_RESOURCE_REQUIREMENTS_LIST` layout.
