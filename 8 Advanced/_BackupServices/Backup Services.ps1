#Requires -Version 5.1

param(
    [bool] $SortByServiceName = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runDate = Get-Date
$dateString = $runDate.ToString('yyyyMMdd_HHmm')
$desktopPath = [Environment]::GetFolderPath('Desktop')
$backupFile = Join-Path -Path $desktopPath -ChildPath "Services_Backup_$dateString.reg"
# $logFile = Join-Path -Path $desktopPath -ChildPath "Services_Backup_$dateString.log"

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message,
        [ConsoleColor] $Color = [ConsoleColor]::Gray
    )

    $entry = "[{0}] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $entry -ForegroundColor $Color
    # Add-Content -LiteralPath $script:logFile -Value $entry -Encoding Unicode
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $administratorRole = [Security.Principal.WindowsBuiltInRole]::Administrator

    if (-not $principal.IsInRole($administratorRole)) {
        Write-Log 'Restarting with administrator privileges. Please respond to the UAC prompt.' Yellow
        $sortArgument = '-SortByServiceName:{0}' -f $SortByServiceName.ToString().ToLowerInvariant()
        $elevatedArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, $sortArgument)
        $elevatedProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $elevatedArguments -Verb RunAs -Wait -PassThru
        exit $elevatedProcess.ExitCode
    }

    Write-Log "Starting service startup configuration backup. Output: $backupFile" Cyan
    $startValues = @{
        boot = 0
        system = 1
        auto = 2
        manual = 3
        disabled = 4
    }
    $skippedServices = New-Object System.Collections.Generic.List[string]
    $registryText = New-Object System.Text.StringBuilder
    [void]$registryText.AppendLine('Windows Registry Editor Version 5.00')
    [void]$registryText.AppendLine()
    [void]$registryText.AppendLine(';Services Startup Configuration Backup ' + $runDate.ToString('yyyy/MM/dd HH:mm:ss'))
    [void]$registryText.AppendLine()

    $services = @(Get-CimInstance -ClassName Win32_Service)
    $serviceNames = @{}
    $normalizedNameCounts = @{}
    foreach ($service in $services) {
        $serviceNames[$service.Name.ToLowerInvariant()] = $true
        if ($service.Name -match '^(?<Base>.+)_[0-9a-fA-F]{5,}$') {
            $baseName = $Matches['Base'].ToLowerInvariant()
            if ($normalizedNameCounts.ContainsKey($baseName)) {
                $normalizedNameCounts[$baseName]++
            }
            else {
                $normalizedNameCounts[$baseName] = 1
            }
        }
    }
    $backedUpCount = 0
    $backupEntries = New-Object System.Collections.Generic.List[object]

    foreach ($service in $services) {
        $startMode = ([string]$service.StartMode).ToLowerInvariant()
        if (-not $startValues.ContainsKey($startMode)) {
            [void]$skippedServices.Add($service.Name)
            continue
        }

        $registryName = $service.Name
        if ($service.Name -match '^(?<Base>.+)_[0-9a-fA-F]{5,}$') {
            $baseName = $Matches['Base']
            $baseNameKey = $baseName.ToLowerInvariant()
            if ($serviceNames.ContainsKey($baseNameKey) -or $normalizedNameCounts[$baseNameKey] -gt 1) {
                Write-Log ("UID suffix retained to avoid a duplicate service name: {0}" -f $service.Name) Yellow
            }
            else {
                $registryName = $baseName
            }
        }

        [void]$backupEntries.Add([pscustomobject]@{
            RegistryName = $registryName
            StartValue = $startValues[$startMode]
        })
        $backedUpCount++
    }

    if ($SortByServiceName) {
        $backupEntries = @($backupEntries | Sort-Object -Property RegistryName)
    }

    foreach ($entry in $backupEntries) {
        [void]$registryText.AppendLine("[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$($entry.RegistryName)]")
        [void]$registryText.AppendLine(("`"Start`"=dword:{0:x8}" -f $entry.StartValue))
        [void]$registryText.AppendLine()
    }

    [System.IO.File]::WriteAllText($backupFile, $registryText.ToString(), [System.Text.Encoding]::Unicode)
    Write-Log ("Found {0} services and backed up {1} startup configurations." -f $services.Count, $backedUpCount) Green

    if ($skippedServices.Count -gt 0) {
        Write-Log ("Services skipped because their startup mode was unsupported: {0}" -f ($skippedServices -join ', ')) Yellow
    }

    Write-Log "Backup saved: $backupFile" Green
    Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $backupFile + '"')
}
catch {
    $errorMessage = $_.Exception.Message
    try {
        Write-Log "An error occurred: $errorMessage" Red
    }
    catch {
        Write-Host "An error occurred: $errorMessage" -ForegroundColor Red
    }
    exit 1
}
