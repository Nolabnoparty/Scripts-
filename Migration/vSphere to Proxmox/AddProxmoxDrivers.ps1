# ------------------------------------------------------------------
#   File:		AddProxmoxDrivers.ps1
#   Scope:		Install Proxmox drivers
#   version:	1.0
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
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "      VMWARE TO PROXMOX MIGRATION       " -ForegroundColor Green
Write-Host "      Installing Proxmox drivers        " -ForegroundColor DarkCyan
Write-Host "========================================" -ForegroundColor Cyan


Function Show-Step {
    param([string]$Message)
    Write-Host "`n>>> $Message..." -ForegroundColor Yellow
    Start-Sleep -Seconds 3
}

Show-Step "Executing script AddProxmoxDrivers.ps1"


# ========================================================
# PROXMOX DRIVERS INSTALLATION
# ========================================================

$driverRoot = "C:\Migration\drivers"
$logDir     = "C:\Migration"
$logFile    = Join-Path $logDir "InstalledDrivers.txt"

# Ensure the destination folder exists
if (!(Test-Path $logDir)) { 
    New-Item -Path $logDir -ItemType Directory | Out-Null 
}

# Initialize log file
"--- Driver Installation Report from $(Get-Date -Format 'MM/dd/yyyy HH:mm') ---" | Out-File $logFile

# 1. Identify OS Version
$osCaption = (Get-CimInstance Win32_OperatingSystem).Caption
$osFolder = switch -regex ($osCaption) {
    "2025" { "2k25" }
    "2022" { "2k22" }
    "2019" { "2k19" }
    "2016" { "2k16" }
    "11"   { "w11" }
    "10"   { "w10" }
    Default { "w10" } 
}

Write-Host "`n--- System: $osCaption ($osFolder) ---" -ForegroundColor Cyan

# 2. INF Component List (vioscsi and viorng EXCLUDED as requested)
$components = @("Balloon", "NetKVM", "viostor")

foreach ($comp in $components) {
    $targetPath = Join-Path $driverRoot "$comp\$osFolder"
    
    if (Test-Path $targetPath) {
        Write-Host "Installing INF Driver: $comp... " -NoNewline
        
        # Run pnputil and capture result
        $pnpOut = pnputil /add-driver "$targetPath\*.inf" /install 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "OK" -ForegroundColor Green
            "SUCCESS: $comp (INF) installed correctly." | Out-File $logFile -Append
        } else {
            Write-Host "ERROR" -ForegroundColor Red
            "ERROR: $comp (INF) failed (Code: $LASTEXITCODE)." | Out-File $logFile -Append
        }
    } else {
        Write-Host "Skipped: $comp (INF Path not found)" -ForegroundColor Gray
        "SKIP: $comp INF not found in $targetPath" | Out-File $logFile -Append
    }
}

# 3. Specific QEMU Guest Agent Installation (MSI)
Write-Host "-------------------------------------------"
$qemuGaPath = Join-Path $driverRoot "qemu-ga"
$qemuMsi = Join-Path $qemuGaPath "qemu-ga-x86_64.msi"

if (Test-Path $qemuMsi) {
    Write-Host "Installing: QEMU Guest Agent... " -NoNewline -ForegroundColor Yellow
    $process = Start-Process "msiexec.exe" -ArgumentList "/i `"$qemuMsi`" /quiet /norestart" -Wait -PassThru
    
    if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
        Write-Host "OK" -ForegroundColor Green
        "SUCCESS: QEMU Guest Agent (MSI) installed correctly." | Out-File $logFile -Append
    } else {
        Write-Host "FAILED" -ForegroundColor Red
        "ERROR: QEMU Guest Agent (MSI) failed with code $($process.ExitCode)" | Out-File $logFile -Append
    }
} else {
    Write-Host "Skipped: QEMU Guest Agent MSI not found in $qemuGaPath" -ForegroundColor Gray
    "SKIP: QEMU Guest Agent MSI not found." | Out-File $logFile -Append
}

# 4. Management of Other MSI Installers (Generic virtio folder)
$virtioPath = Join-Path $driverRoot "virtio"
if (Test-Path $virtioPath) {
    $arch = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
    $msi = Get-ChildItem -Path $virtioPath -Filter "*$arch*.msi" -Recurse | Select-Object -First 1
    
    if ($msi) {
        Write-Host "Executing generic MSI: $($msi.Name)... " -NoNewline -ForegroundColor Yellow
        $process = Start-Process "msiexec.exe" -ArgumentList "/i `"$($msi.FullName)`" /quiet /norestart" -Wait -PassThru
        
        if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
            Write-Host "OK" -ForegroundColor Green
            "SUCCESS: MSI $($msi.Name) installed." | Out-File $logFile -Append
        } else {
            Write-Host "FAILED" -ForegroundColor Red
            "ERROR: MSI $($msi.Name) failed with code $($process.ExitCode)" | Out-File $logFile -Append
        }
    }
}

Write-Host "`nOperation completed. Log: $logFile" -ForegroundColor Cyan

$path = "C:\Migration\"
$flagPath = Join-Path $path "3_ProxmoxDriversInstalled"

# Create the ProxmoxDriversInstalled flag
Show-Step "Creating ProxmoxDriversInstalled flag"
New-Item -ItemType File -Path $flagPath -Force | Out-Null
Write-Host "Flag created: $flagPath" -ForegroundColor Green


# STEP 9: Remove set AutoLogon
Show-Step "Removing AutoLogon"
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Remove-ItemProperty -Path $regPath -Name "AutoAdminLogon" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $regPath -Name "DefaultUserName" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $regPath -Name "DefaultPassword" -ErrorAction SilentlyContinue
Write-Host "AutoLogon removed." -ForegroundColor Green


# STEP 10: Remove scheduled task "AddProxmoxDrivers"
Show-Step "Removing scheduled task 'AddProxmoxDrivers'"
try {
    $tasks = Get-ScheduledTask | Where-Object { $_.TaskName -eq 'AddProxmoxDrivers' }
    if (-not $tasks -or $tasks.Count -eq 0) {
        Write-Host "No 'AddProxmoxDrivers' task found in Task Scheduler." -ForegroundColor Cyan
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


# STEP 11: Create Scheduled Task for PostMigrationSetup.ps1 with visible window
Show-Step "Creating Scheduled Task to run PostMigrationSetup.ps1"
$taskName = "PostMigrationSetup"
$scriptPath = "C:\Migration\script\PostMigrationSetup.ps1"

# Action: start PowerShell with visible window and bypass policy
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoExit -ExecutionPolicy Bypass -File `"$scriptPath`""

# Trigger: at startup
$trigger = New-ScheduledTaskTrigger -AtStartup

# Register task with elevated privileges
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -RunLevel Highest -User "SYSTEM" -Force

Write-Host "Task created to run PostMigrationSetup.ps1 at startup." -ForegroundColor Green


# STEP 12: Create the VMreadyToMigrate flag
Show-Step "Creating VMreadyToMigrate flag"
$flagPath = Join-Path $path "VMreadyToMigrate"
New-Item -ItemType File -Path $flagPath -Force | Out-Null
Write-Host "Flag created: $flagPath" -ForegroundColor Green

Show-Step "Cleanup completed"
Write-Host "`n>>> Script AddProxmoxDrivers.ps1 completed! <<<" -ForegroundColor Cyan

# Shutdown VM in 5 seconds
Write-Host "The computer will shut down in 5 seconds..." -ForegroundColor Yellow
Start-Sleep -Seconds 5
Stop-Computer -Force