# Migration Guide: vSphere to Proxmox

> **Purpose:** This document outlines the standardized workflow for migrating virtual machines from VMware vSphere to Proxmox VE, including the optimization of storage controllers for Windows guests.

## 📂 Folder Tree: Create Structure and Add Drivers
To ensure the migration scripts function correctly, you must set up the local directory structure on the target machine as defined below. The primary workspace should be located at `C:\Migration`.

# VM Migration Toolkit

This repository contains the structured driver library and automation scripts required for migrating Windows Virtual Machines to KVM/QEMU-based hypervisors (such as Proxmox, Nutanix, or OpenStack).

## 📂 Directory Structure

C:\Migration
└── Migration/
    ├── scripts/           # Automation and execution scripts
    └── drivers/           # Driver repository
        ├── Balloon/       # Memory Ballooning drivers
        │   ├── 2k16/
        │   ├── 2k19/
        │   ├── 2k22/
        │   ├── 2k25/
        │   ├── w10/
        │   └── w11/
        ├── NetVM/         # Network interface drivers
        │   ├── 2k16/
        │   ├── 2k19/
        │   ├── 2k22/
        │   ├── 2k25/
        │   ├── w10/
        │   └── w11/
        ├── qemu-ga/       # QEMU Guest Agent
        │   └── qemu-ga-x86_64.msi
        ├── viostor/       # Block storage drivers
        │   ├── 2k16/
        │   ├── 2k19/
        │   ├── 2k22/
        │   ├── 2k25/
        │   ├── w10/
        │   └── w11/
        └── virtio/        # VirtIO Guest Tools
            └── virtio-win-gt-x64.msi

---

## 🛠 Phase 1: Preparation (vSphere side)
1. **Copy** the `Migration` folder to the target VM.
2. **Execute** `PreMigration.ps1`.
3. **Reboot** the VM. 
   - *Note:* The `AddProxmoxDrivers.ps1` script will trigger automatically, install necessary drivers, and then shut down the machine.
4. **Perform** a final backup of the VM.

---

## 📦 Phase 2: Transfer & Initial Config
1. **Restore** the VM backup to the Proxmox node.
2. **Network:** Assign the correct VLAN in the Proxmox Hardware settings.
3. **Disk Configuration (Compatibility Mode):**
   - Detach the OS disk.
   - Double-click the **Unused Disk** and re-attach it using the **SATA** bus.
4. **Boot Order:** Go to **Options > Boot Order** and set the SATA disk as the primary device.
5. **Power On** the VM.

---

## ⚙️ Phase 3: Post-Migration Cleanup
1. **Automated Setup:** After booting, the VM will automatically run `PostMigrationSetup.ps1`.
2. **Verification:**
   - Network parameters are restored.
   - VMware tools/drivers are uninstalled.
3. **Reboot:** The VM will perform an automatic final restart.

---

## 🚀 Phase 4: Storage Optimization (SATA to VirtIO SCSI)
*To achieve better I/O performance, switch the OS disk to VirtIO SCSI.*

| Step | Action | Description |
| :--- | :--- | :--- |
| **1** | **Add Temp Disk** | Hot-add a 1GB disk using the **VirtIO SCSI** controller. |
| **2** | **Driver Sync** | Reboot the VM to allow Windows to load the SCSI driver, then **Shut down**. |
| **3** | **Cleanup** | Detach and remove the 1GB temporary disk. |
| **4** | **Re-attach OS** | Detach the OS disk $\rightarrow$ Re-attach as **SCSI**. |
| **5** | **Controller** | Ensure SCSI Controller is set to **VirtIO SCSI single**. |
| **6** | **Power On** | Update Boot Order if necessary and start the VM. |

---
*Generated for Infrastructure Documentation - 2026*
