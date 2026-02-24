# ------------------------------------------------------------------
#   File:		PreMigration.ps1
#   Scope:		Migration VMware -> Proxmox
#   version:	1.0
# ------------------------------------------------------------------

cls

# Set UTF-8 encoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Check if running as administrator
If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "Error: Please run the script as Administrator." -ForegroundColor Red
    Pause
    Exit
}

# Show banner
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "      VMWARE TO PROXMOX MIGRATION       " -ForegroundColor Green
Write-Host "        VM & Network Preparation        " -ForegroundColor DarkCyan
Write-Host "========================================" -ForegroundColor Cyan


Function Show-Step {
    param([string]$Message)
    Write-Host "`n>>> $Message..." -ForegroundColor Yellow
    Start-Sleep -Seconds 2
}

Show-Step "Executing script PreMigration.ps1"

# STEP 1: Verify C:\Migration folder
Show-Step "Verifying presence of folder C:\Migration"
If (-Not (Test-Path "C:\Migration")) {
    Write-Host "WARNING: folder C:\Migration not found. Aborting script." -ForegroundColor Red
    Pause
    Exit
}
Write-Host "Folder C:\Migration found." -ForegroundColor Green


# Verify PreMigrationCompleted flag
$flagPath = "C:\Migration\PreMigrationCompleted"
if (Test-Path $flagPath) {
    $choice = Read-Host "The Pre-Migration phase has already been executed, continue? (Y/N)"
    if ($choice -notmatch '^[YySs]$') {
        Write-Host "Procedure aborted."
        exit
    }
}


# STEP 2: Save network parameters
Show-Step "Saving network parameters"

# Get the first physical NIC with active IPv4
$nic = Get-NetIPConfiguration |
    Where-Object { $_.IPv4Address -ne $null -and $_.InterfaceDescription -notlike "*VMware*" } |
    Select-Object -First 1

if (-not $nic) {
    Write-Host "No NIC found" -ForegroundColor Yellow
    exit
}

# Simple calculation of mask from PrefixLength
$prefix = $nic.IPv4Address.PrefixLength
$mask = ([IPAddress]::new((@(255,255,255,255)[0..($prefix/8-1)] + @(256 - [math]::Pow(2,(8-($prefix%8)))) + @(0,0,0,0))[0..3])).IPAddressToString

$ip      = $nic.IPv4Address.IPAddress
$gateway = $nic.IPv4DefaultGateway.NextHop
$dns     = ($nic.DnsServer.ServerAddresses -join ', ')
$mac     = (Get-NetAdapter | Where-Object { $_.InterfaceIndex -eq $nic.InterfaceIndex }).MacAddress

$info = @"
IP: $ip
Mask: $mask
Gateway: $gateway
DNS: $dns
MAC: $mac
"@

$path = "C:\Migration\nic_info.txt"
New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
$info | Out-File $path -Encoding UTF8
Write-Host "Parameters saved in $path" -ForegroundColor Green


# STEP 3: Set AutoLogon
Show-Step "Setting AutoLogon"
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty $regPath "AutoAdminLogon" -Value "1"
Set-ItemProperty $regPath "DefaultUserName" -Value "Administrator"
$securePwd = Read-Host "Enter the Administrator password" -AsSecureString
$plainPwd = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd))
Set-ItemProperty $regPath "DefaultPassword" -Value $plainPwd
Write-Host "AutoLogon configured." -ForegroundColor Green


# STEP 4: Create Task Scheduler for AddProxmoxDrivers.ps1 with visible window
Show-Step "Creating Task Scheduler to execute AddProxmoxDrivers.ps1"
$taskName = "AddProxmoxDrivers"
$scriptPath = "C:\Migration\Script\AddProxmoxDrivers.ps1"

# Action: start PowerShell with visible window and bypass policy
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoExit -ExecutionPolicy Bypass -File `"$scriptPath`""

# Trigger: at startup
$trigger = New-ScheduledTaskTrigger -AtStartup

# Register the task with elevated privileges
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -RunLevel Highest -User "SYSTEM" -Force

Write-Host "Task created to run AddProxmoxDrivers.ps1 at startup." -ForegroundColor Green


$path = "C:\Migration\"
$flagPath = Join-Path $path "1_PreMigrationCompleted"

# Create PreMigrationCompleted flag
Show-Step "Creating PreMigrationCompleted flag"
New-Item -ItemType File -Path $flagPath -Force | Out-Null
Write-Host "Flag created: $flagPath" -ForegroundColor Green


# STEP 5: Remove VMware Tools
$flagPath = Join-Path $path "2_VMwareToolsRemoved"

# Create VMwareToolsRemoved flag
Show-Step "Creating VMwareToolsRemoved flag"
New-Item -ItemType File -Path $flagPath -Force | Out-Null
Write-Host "Flag created: $flagPath" -ForegroundColor Green

# Use Win32_Product for maximum compatibility
$vmware = Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -like "*VMware Tools*" }
$rebootRequired = $false
If ($vmware) {
    Show-Step "Removing VMware Tools..."
    $vmware.Uninstall()
    Write-Host "VMware Tools removed. A reboot may be required." -ForegroundColor Green
    $rebootRequired = $true
} else {
    Write-Host "VMware Tools not installed. No removal necessary." -ForegroundColor Cyan
}


# Final message and reboot if required
Write-Host "`n>>> Script completed successfully! <<<" -ForegroundColor Cyan
If ($rebootRequired) {
    Write-Host "`n>>> Reboot required. The system will restart in 10 seconds... <<<" -ForegroundColor Red
    Start-Sleep -Seconds 10
    Restart-Computer
} else {
    Pause
}