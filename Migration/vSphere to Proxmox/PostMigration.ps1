# ------------------------------------------------------------------
# 	File:		PostMigration.ps1
#	Scope:		VMware drivers removal & network restore
#	version:	1.0
# ------------------------------------------------------------------

cls

# Set UTF-8 encoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Check if running as administrator
If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "Restarting script with administrative privileges..." -ForegroundColor Yellow
    Start-Sleep -Seconds 3
    Start-Process powershell.exe "-NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

# Show banner
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "     VMWARE TO PROXMOX MIGRATION    			   " -ForegroundColor Green
Write-Host "     VMware drivers removal & network restore      " -ForegroundColor DarkCyan
Write-Host "===================================================" -ForegroundColor Cyan


# Verify VMreadyToMigrate flag
$flagPath = "C:\Migration\VMreadyToMigrate"
if (-Not (Test-Path $flagPath)) {
    $choice = Read-Host "The VM setup was not completed (flag not found), continue? (Y/N)"
    if ($choice -notmatch '^[YySs]$') {
        Write-Host "Procedure aborted."
        exit
    }
}


Function Show-Step {
    param([string]$Message)
    Write-Host "`n>>> $Message..." -ForegroundColor Yellow
    Start-Sleep -Seconds 2
}

Show-Step "Executing script PostMigration.ps1"


# STEP 1: Restore network configuration
Show-Step "Restoring network configuration..."
$nicInfoPath = "C:\Migration\nic_info.txt"
$gateway = $null
$dns = $null

if (Test-Path $nicInfoPath) {
    # CRITICAL FIX: Parsing for ':' separator
    $nicData = Get-Content $nicInfoPath | ForEach-Object {
        $parts = $_ -split ":" 
        if ($parts.Count -eq 2) {
            switch ($parts[0].Trim()) {
                "IP"       { $ip = $parts[1].Trim() }
                "Mask"     { $mask = $parts[1].Trim() }
                "Gateway"  { $gateway = $parts[1].Trim() }
                "DNS"      { $dns = $parts[1].Trim() } 
            }
        }
    }

    if ($ip -and $mask) {
        # Find active Ethernet NIC (likely VirtIO)
        $netAdapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.InterfaceDescription -like "*VirtIO*" } | Select-Object -First 1

        if (-not $netAdapter) {
             # Fallback: if VirtIO is not found (e.g., the network is the first generic NIC)
             $netAdapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
        }

        if ($netAdapter) {
            $nicName = $netAdapter.Name
            Write-Host "IP Configuration: $ip / $mask on NIC: $nicName"
            
            # Setting IP/Mask/Gateway
            netsh interface ip set address name="$nicName" static $ip $mask $gateway
            
            # Setting DNS (Added)
            if ($dns) {
                # Clears any previous configurations
                netsh interface ip set dns name="$nicName" static none 
                
                $dnsList = $dns -split ', ' # Separates saved DNS entries
                $primaryDns = $dnsList[0]
                
                # Set Primary DNS
                netsh interface ip set dns name="$nicName" static $primaryDns primary
                Write-Host "Primary DNS restored: $primaryDns"
                
                # Set Secondary DNS (if present)
                if ($dnsList.Count -gt 1) {
                    $secondaryDns = $dnsList[1]
                    netsh interface ip add dns name="$nicName" $secondaryDns index=2
                    Write-Host "Secondary DNS restored: $secondaryDns"
                }
            } else {
                 Write-Host "No DNS saved in file. Leaving DHCP for DNS." -ForegroundColor Yellow
            }
            
            Write-Host "Network configuration restored." -ForegroundColor Green
        } else {
             Write-Host "No active network adapter found for IP assignment." -ForegroundColor Red
        }

    } else {
        Write-Host "Incomplete network data in nic_info.txt." -ForegroundColor Red
    }
} else {
    Write-Host "File nic_info.txt not found. Network not configured." -ForegroundColor Red
}


# STEP 2: Verify gateway ping + success/failure flag
Write-Host "Verifying gateway connectivity..." -ForegroundColor Cyan
Start-Sleep -Seconds 10

$SuccessFlag = "C:\Migration\ping_gateway_successful.flag"
$FailureFlag = "C:\Migration\ping_gateway_failed.flag"

# Ensure directory exists
$dir = Split-Path $SuccessFlag -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$ping_gateway_successful = $false
$ping_gateway_failed = $false

if ($gateway) {
    Write-Host "Pinging $gateway..." -ForegroundColor Yellow
    try {
        Test-Connection -ComputerName $gateway -Count 4 | Format-Table Address, ResponseTime, Status
        Write-Host "`nResult:" -ForegroundColor Cyan

        if (Test-Connection -ComputerName $gateway -Count 2 -Quiet) {
            Write-Host "Ping successful." -ForegroundColor Green
            $ping_gateway_successful = $true
            $ping_gateway_failed = $false
            "SUCCESS: $gateway $(Get-Date)" | Out-File $SuccessFlag -Force
            if (Test-Path $FailureFlag) { Remove-Item $FailureFlag -Force }
        } else {
            Write-Host "Ping UNSUCCESSFUL." -ForegroundColor Red
            $ping_gateway_failed = $true
            "FAILED: $gateway $(Get-Date)" | Out-File $FailureFlag -Force
            if (Test-Path $SuccessFlag) { Remove-Item $SuccessFlag -Force }
        }
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        $ping_gateway_failed = $true
        "ERROR: $($_.Exception.Message) $(Get-Date)" | Out-File $FailureFlag -Force
        if (Test-Path $SuccessFlag) { Remove-Item $SuccessFlag -Force }
    }
} else {
    Write-Host "Gateway undefined." -ForegroundColor Cyan
    $ping_gateway_failed = $true
    "FAILED: gateway undefined $(Get-Date)" | Out-File $FailureFlag -Force
    if (Test-Path $SuccessFlag) { Remove-Item $SuccessFlag -Force }
}

Write-Host "ping_gateway_successful = $ping_gateway_successful" -ForegroundColor Cyan


# STEP 3: Remove "PostMigration" scheduled task
Show-Step "Removing 'PostMigration' scheduled task"
try {
    $tasks = Get-ScheduledTask | Where-Object { $_.TaskName -eq 'PostMigration' }
    if (-not $tasks -or $tasks.Count -eq 0) {
        Write-Host "No 'PostMigration' task found in Task Scheduler." -ForegroundColor Cyan
    } else {
        foreach ($t in $tasks) {
            try {
                $state = ($t | Get-ScheduledTaskInfo).State
                if ($state -eq 'Running') {
                    Write-Host "Task running: $($t.TaskName) - Stopping..." -ForegroundColor Yellow
                    Stop-ScheduledTask -InputObject $t -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 2
                }
            } catch {
                Write-Host "Unable to stop task: $($_.Exception.Message)" -ForegroundColor Red
            }

            try {
                Disable-ScheduledTask -InputObject $t -ErrorAction SilentlyContinue | Out-Null
            } catch {
                Write-Host "Unable to disable task: $($_.Exception.Message)" -ForegroundColor Red
            }

            try {
                Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
                Write-Host "Task removed: $($t.TaskPath)$($t.TaskName)" -ForegroundColor Green
            } catch {
                Write-Host "Error during task removal: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
} catch {
    Write-Host "Error retrieving scheduled tasks: $($_.Exception.Message)" -ForegroundColor Red
}


# Enable view hidden devices
Show-Step "Enabling view of hidden devices"
$env:devmgr_show_nonpresent_devices = 1


# STEP 4: Removal of VMware and VMXNET devices (including hidden ones)
Show-Step "Removing VMware and VMXNET devices"
$devices = Get-PnpDevice -PresentOnly:$false | Where-Object {
    $_.FriendlyName -like "*VMware*" -or $_.InstanceId -like "*VMware*" -or
    $_.FriendlyName -like "*VMXNET*" -or $_.InstanceId -like "*VMXNET*"
}
if ($devices) {
    foreach ($device in $devices) {
        Write-Host "Removing device: $($device.FriendlyName) [$($device.InstanceId)]"
        try {
            pnputil /remove-device "$($device.InstanceId)" | Out-Null
        } catch {
            Write-Host "Removal error: $($device.InstanceId)" -ForegroundColor Red
        }
    }
} else {
    Write-Host "No VMware/VMXNET devices found." -ForegroundColor Yellow
}


# STEP 5: Removal of VMware drivers via pnputil
Show-Step "Removing VMware drivers via pnputil"
$drivers = pnputil /enum-drivers | Select-String "VMware"
if ($drivers) {
    foreach ($line in $drivers) {
        if ($line -match "Published Name\s*:\s*(oem\d+\.inf)") {
            $inf = $matches[1]
            Write-Host "Removing driver: $inf"
            pnputil /delete-driver $inf /uninstall /force | Out-Null
        }
    }
} else {
    Write-Host "No VMware drivers found." -ForegroundColor Yellow
}

# STEP 6: VMware registry key cleanup
Show-Step "Cleaning VMware registry keys"
$regPaths = @(
    "HKLM:\SOFTWARE\VMware, Inc.",
    "HKLM:\SYSTEM\CurrentControlSet\Services\VMTools",
    "HKLM:\SYSTEM\CurrentControlSet\Services\vmhgfs",
    "HKLM:\SYSTEM\CurrentControlSet\Services\vmci",
    "HKLM:\SYSTEM\CurrentControlSet\Services\vmvss",
    "HKLM:\SYSTEM\CurrentControlSet\Services\vmxnet",
    "HKLM:\SYSTEM\CurrentControlSet\Services\vmx_svga",
    "HKLM:\SYSTEM\CurrentControlSet\Services\vm3dmp",
    "HKLM:\SYSTEM\CurrentControlSet\Services\hcmon"
)
foreach ($path in $regPaths) {
    if (Test-Path $path) {
        Write-Host "Removing registry key: $path"
        Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# STEP 7: VMware folder cleanup
Show-Step "Cleaning VMware folders"
$folders = @(
    "C:\Program Files\VMware",
    "C:\Program Files\Common Files\VMware"
)
foreach ($folder in $folders) {
    if (Test-Path $folder) {
        Write-Host "Removing folder: $folder"
        Remove-Item -Path $folder -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`nVMware removal completed. Restart the system to finalize cleanup." -ForegroundColor Green


# STEP 8: Writing operation confirmation flags
Show-Step "Writing flags"

# Folder path
$FlagsDir = 'C:\Migration'

# Ensure folder exists
if (-not (Test-Path $FlagsDir)) { New-Item -ItemType Directory -Path $FlagsDir -Force | Out-Null }

# Flags to create
New-Item -ItemType File -Path "$FlagsDir\4_VMwareDriversRemoved" -Force | Out-Null
New-Item -ItemType File -Path "$FlagsDir\MIGRATION_COMPLETED" -Force | Out-Null
Write-Host "Flags created: VMwareDriversRemoved, MIGRATION_COMPLETED" -ForegroundColor Green

# Flag to remove
$flagToRemove = "$FlagsDir\VMreadyToMigrate"
if (Test-Path $flagToRemove) {
    Remove-Item $flagToRemove -Force
    Write-Host "Flag removed: VMreadyToMigrate" -ForegroundColor Green
} else {
    Write-Host "The flag VMreadyToMigrate does not exist." -ForegroundColor Cyan
}


# Final message
Write-Host "============================================="
Write-Host " DRIVER REMOVAL PROCEDURE FINISHED       " -ForegroundColor Green
Write-Host "============================================="

Write-Host "The computer will restart in 5 seconds..." -ForegroundColor Yellow
Start-Sleep -Seconds 5
Restart-Computer