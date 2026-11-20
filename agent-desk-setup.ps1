# agent-desk-setup.ps1
# Interactive version: run at the agent's desk in an elevated PowerShell, with the agent out of queue.
#   irm <raw gist url> | iex
# Everything is inside a function so a stop doesn't close your PowerShell window.

function Invoke-AgentDeskSetup {
    $ErrorActionPreference = 'Continue'
    function Step($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
    function Ok($t)   { Write-Host "  [OK]   $t" -ForegroundColor Green }
    function Warn($t) { Write-Host "  [!!]   $t" -ForegroundColor Yellow }
    function Info($t) { Write-Host "  $t" }

    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Run this in an elevated (Run as administrator) PowerShell." -ForegroundColor Red; return
    }
    $cs = Get-CimInstance Win32_ComputerSystem
    Write-Host "`n$env:COMPUTERNAME  |  $($cs.Manufacturer) $($cs.Model)  |  $(Get-Date)" -ForegroundColor White

    # --- 1. Wi-Fi off when on Ethernet ---------------------------------------
    Step "Wi-Fi policy"
    $wcm = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WcmSvc\GroupPolicy'
    New-Item -Path $wcm -Force | Out-Null
    New-ItemProperty -Path $wcm -Name 'fMinimizeConnections' -PropertyType DWord -Value 3 -Force | Out-Null
    Ok "Prevent Wi-Fi when on Ethernet set (full effect after reboot)"
    $wifi = Get-NetIPConfiguration | Where-Object { $_.InterfaceAlias -like 'Wi-Fi*' -and $_.IPv4Address.IPAddress -notlike '169.254*' -and $_.IPv4Address }
    if ($wifi) { Warn "Wi-Fi currently has an address ($($wifi.IPv4Address.IPAddress)) - goes away after reboot" }

    # --- 2. Power plan ----------------------------------------------------------
    Step "Power plan"
    powercfg /change monitor-timeout-ac 0
    powercfg /change standby-timeout-ac 0
    powercfg /change hibernate-timeout-ac 0
    powercfg /setacvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 0
    powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
    powercfg /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
    powercfg /setactive SCHEME_CURRENT
    Ok "On AC: no screen-off/sleep/hibernate, lid = do nothing; USB selective suspend off"

    # --- 3. Dock NIC --------------------------------------------------------------
    Step "Dock network adapter"
    $nics = Get-NetAdapter -Physical | Where-Object { $_.InterfaceDescription -match 'Dell Giga Ethernet|Realtek USB' }
    if (-not $nics) {
        Warn "No dock NIC found - is the laptop docked? Adapters present:"
        Get-NetAdapter | Format-Table Name, InterfaceDescription, Status -AutoSize | Out-Host
    }
    $keywords = '*EEE','AdvancedEEE','EnableGreenEthernet','GigaLite','PowerSavingMode','*SelectiveSuspend','SelectiveSuspend','*DeviceSleepOnDisconnect'
    foreach ($n in $nics) {
        Info "$($n.Name) - $($n.InterfaceDescription) - driver $($n.DriverVersion) - $($n.LinkSpeed)"
        $todo = @()
        $pm = Get-NetAdapterPowerManagement -Name $n.Name -ErrorAction SilentlyContinue
        if ($pm -and "$($pm.AllowComputerToTurnOffDevice)" -eq 'Enabled') { $todo += 'PowerMgmt'; Warn "Allow computer to turn off this device: Enabled" }
        foreach ($kw in $keywords) {
            $p = Get-NetAdapterAdvancedProperty -Name $n.Name -RegistryKeyword $kw -ErrorAction SilentlyContinue
            if ($p) {
                if ("$($p.RegistryValue[0])" -ne '0') { $todo += $kw; Warn "$($p.DisplayName): $($p.DisplayValue)" }
                else { Ok "$($p.DisplayName): $($p.DisplayValue)" }
            }
        }
        if (-not $todo) { Ok "Nothing to change on this adapter"; continue }

        Read-Host "`n  Agent out of queue? Press Enter to apply (network drops ~5-10 sec)" | Out-Null
        if ($todo -contains 'PowerMgmt') { Set-NetAdapterPowerManagement -Name $n.Name -AllowComputerToTurnOffDevice Disabled -NoRestart }
        foreach ($kw in ($todo | Where-Object { $_ -ne 'PowerMgmt' })) {
            Set-NetAdapterAdvancedProperty -Name $n.Name -RegistryKeyword $kw -RegistryValue 0 -NoRestart
        }
        Restart-NetAdapter -Name $n.Name
        Info "Adapter restarted - waiting for an address..."
        $ip = $null
        for ($i = 0; $i -lt 30 -and -not $ip; $i++) {
            Start-Sleep 2
            $ip = (Get-NetIPAddress -InterfaceAlias $n.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                   Where-Object { $_.IPAddress -notlike '169.254*' }).IPAddress
        }
        if ($ip) {
            $gw = (Get-NetIPConfiguration -InterfaceAlias $n.Name).IPv4DefaultGateway.NextHop
            Ok "IP $ip, gateway $gw"
            if ($gw -and (Test-Connection $gw -Count 2 -Quiet)) { Ok "Gateway responds" } else { Warn "Gateway not responding" }
        } else {
            Warn "No DHCP address after 60 sec - try reseating the dock's USB-C, then power-cycling the dock"
        }
    }

    # --- 4. Software check --------------------------------------------------------
    Step "Software"
    $apps = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
    $a = $apps | Where-Object { $_.DisplayName -like '*Dell Command | Update*' } | Select-Object -First 1
    if ($a) { Ok "$($a.DisplayName) $($a.DisplayVersion)" } else { Warn "Dell Command | Update NOT installed" }

    # Poly Studio (formerly Poly Lens Desktop)
    $polyUrl = 'https://www.hp.com/us-en/poly/software-and-services/software/poly-lens/app.html'
    $poly = $apps | Where-Object { $_.DisplayName -match 'Poly Studio|Poly Lens' } | Select-Object -First 1
    if ($poly) {
        Ok "$($poly.DisplayName) $($poly.DisplayVersion)"
    } else {
        Warn "Poly Studio not found - install from: $polyUrl"
        if ((Read-Host "  Open the Poly Studio download page now? (y/N)") -eq 'y') { Start-Process $polyUrl }
    }
    $dcu = @("$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe","${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe") |
           Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $dcu -and $cs.Manufacturer -match 'Dell') {
        if ((Read-Host "  Install Dell Command Update with winget? (y/N)") -eq 'y') {
            winget install --id Dell.CommandUpdate -e --accept-package-agreements --accept-source-agreements --scope machine
            $dcu = @("$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe","${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe") |
                   Where-Object { Test-Path $_ } | Select-Object -First 1
        }
    }
    if ($dcu -and (Read-Host "  Run DCU scan now? (y/N)") -eq 'y') {
        & $dcu /configure -userConsent=disable -autoSuspendBitLocker=enable -scheduleManual -updatesNotification=disable -forceRestart=disable -silent | Out-Null
        & $dcu /scan
        if ((Read-Host "  Apply these updates now? BIOS updates may force a reboot (y/N)") -eq 'y') {
            & $dcu /applyUpdates -reboot=disable
            Info "dcu-cli exit code: $LASTEXITCODE (0 = done, 1 = reboot needed, 500 = nothing to do)"
        }
    }

    # --- 5. Clean up any scheduled versions -----------------------------------------
    Get-ScheduledTask -TaskName 'AgentDeskHardening*' -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

    Step "Done"
    Info "Reboot to finish the Wi-Fi policy (and any updates)."
    if ((Read-Host "  Reboot now? (y/N)") -eq 'y') { Restart-Computer -Force }
}

Invoke-AgentDeskSetup
