[String] $Architecture = "{{__ARCHITECTURE__}}"
[String] $HardwareArchitecture = "{{__HARDWARE_ARCHITECTURE__}}"
[String] $Version = "{{__VERSION__}}"
[String] $PythonExecName = "{{__PYTHON_EXEC_NAME__}}"

function Get-RegistryVersionFilter {
    param(
        [Parameter(Mandatory)][String] $Architecture,
        [Parameter(Mandatory)][Int32] $MajorVersion,
        [Parameter(Mandatory)][Int32] $MinorVersion
    )

    # FIX 1: Make architecture filter more specific to avoid conflicts between x64 and ARM64.
    $archFilter = switch ($Architecture) {
        'x86' { "32-bit" }
        'arm64' { "ARM64" }
        'arm64-freethreaded' { "ARM64" }
        default { "64-bit" }
    }
    
    "Python $MajorVersion.$MinorVersion.*($archFilter)"
}

function Remove-RegistryEntries {
    param(
        [Parameter(Mandatory)][String] $Architecture,
        [Parameter(Mandatory)][Int32] $MajorVersion,
        [Parameter(Mandatory)][Int32] $MinorVersion
    )

    # FIX 2: Use the installation architecture, not the hardware architecture, for cleanup.
    # This prevents removing the wrong keys (e.g., removing x64 keys when installing an x86 version).
    $versionFilter = Get-RegistryVersionFilter -Architecture $Architecture -MajorVersion $MajorVersion -MinorVersion $MinorVersion

    $regPath = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products"
    if (Test-Path -Path Registry::$regPath) {
        $regKeys = Get-ChildItem -Path Registry::$regPath -Recurse | Where-Object Property -Ccontains DisplayName
        foreach ($key in $regKeys) {
            if ($key.getValue("DisplayName") -match $versionFilter) {
                Write-Host "Removing registry entry for $($key.getValue('DisplayName'))"
                Remove-Item -Path $key.PSParentPath -Recurse -Force -Verbose
            }
        }
    }

    $uninstallRegistrySections = @(
        "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall",  # current user, x64
        "HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall", # all users, x64
        "HKEY_CURRENT_USER\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",  # current user, x86
        "HKEY_LOCAL_MACHINE\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"  # all users, x86
    )

    $uninstallRegistrySections | Where-Object { Test-Path -Path Registry::$_ } | ForEach-Object {
        Get-ChildItem -Path Registry::$_ | Where-Object { $_.getValue("DisplayName") -match $versionFilter } | ForEach-Object {
            Write-Host "Removing uninstall entry for $($_.getValue('DisplayName'))"
            Remove-Item Registry::$_ -Recurse -Force -Verbose
        }
    }
}

function Get-ExecParams {
    param(
        [Parameter(Mandatory)][Boolean] $IsMSI,
        [Parameter(Mandatory)][Boolean] $IsFreeThreaded,
        [Parameter(Mandatory)][String] $PythonArchPath
    )

    if ($IsMSI) {
        "TARGETDIR=$PythonArchPath ALLUSERS=1"
    } else {
        $Include_freethreaded = if ($IsFreeThreaded) { "Include_freethreaded=1" } else { "" }
        "DefaultAllUsersTargetDir=$PythonArchPath InstallAllUsers=1 $Include_freethreaded"
    }
}

$ToolcacheRoot = $env:AGENT_TOOLSDIRECTORY
if ([string]::IsNullOrEmpty($ToolcacheRoot)) {
    # GitHub images don't have `AGENT_TOOLSDIRECTORY` variable
    $ToolcacheRoot = $env:RUNNER_TOOL_CACHE
}
$PythonToolcachePath = Join-Path -Path $ToolcacheRoot -ChildPath "Python"
$PythonVersionPath = Join-Path -Path $PythonToolcachePath -ChildPath $Version
$PythonArchPath = Join-Path -Path $PythonVersionPath -ChildPath $Architecture

$IsMSI = $PythonExecName -match "msi"
$IsFreeThreaded = $Architecture -match "-freethreaded"

$MajorVersion = $Version.Split('.')[0]
$MinorVersion = $Version.Split('.')[1]

Write-Host "Check if Python hostedtoolcache folder exist..."
if (-Not (Test-Path $PythonToolcachePath)) {
    Write-Host "Create Python toolcache folder"
    New-Item -ItemType Directory -Path $PythonToolcachePath | Out-Null
}

Write-Host "Check if current Python version is installed..."
# FIX 3: Add -ErrorAction SilentlyContinue. This is critical. Without it, the script fails
# if no previous version is found, which breaks all fresh installs.
$InstalledVersions = Get-Item "$PythonToolcachePath\$MajorVersion.$MinorVersion.*\$Architecture" -ErrorAction SilentlyContinue

if ($null -ne $InstalledVersions) {
    Write-Host "Python$MajorVersion.$MinorVersion ($Architecture) was found in $PythonToolcachePath..."

    foreach ($InstalledVersion in $InstalledVersions) {
        if (Test-Path -Path $InstalledVersion) {
            Write-Host "Deleting $InstalledVersion..."
            Remove-Item -Path $InstalledVersion -Recurse -Force
            if (Test-Path -Path "$($InstalledVersion.Parent.FullName)/${Architecture}.complete") {
                Remove-Item -Path "$($InstalledVersion.Parent.FullName)/${Architecture}.complete" -Force -Verbose
            }
        }
    }
} else {
    Write-Host "No Python$MajorVersion.$MinorVersion.* found"
}

Write-Host "Remove registry entries for Python ${MajorVersion}.${MinorVersion}(${Architecture})..."
Remove-RegistryEntries -Architecture $Architecture -MajorVersion $MajorVersion -MinorVersion $MinorVersion

# FIX 4: When installing ARM64, clear any state left by a previous x64 installer.
# This directly addresses the "fails after x64" issue.
if ($Architecture -eq "arm64" -or $Architecture -eq "arm64-freethreaded") {
    Write-Host "Preparing clean environment for ARM64 installation..."
    Stop-Process -Name msiexec -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Restart-Service -Name msiserver -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Write-Host "Windows Installer service restarted."
}

Write-Host "Create Python $Version folder in $PythonToolcachePath"
New-Item -ItemType Directory -Path $PythonArchPath -Force | Out-Null

Write-Host "Copy Python binaries to $PythonArchPath"
Copy-Item -Path ./$PythonExecName -Destination $PythonArchPath | Out-Null

Write-Host "Install Python $Version in $PythonToolcachePath..."
$ExecParams = Get-ExecParams -IsMSI $IsMSI -IsFreeThreaded $IsFreeThreaded -PythonArchPath $PythonArchPath

cmd.exe /c "cd $PythonArchPath && call $PythonExecName $ExecParams /quiet"
if ($LASTEXITCODE -ne 0) {
    # If the installation fails, provide detailed logs for diagnosis.
    $logFile = Join-Path $env:TEMP "python_install_error_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    $logParams = "$ExecParams /log `"$logFile`""
    cmd.exe /c "cd $PythonArchPath && call $PythonExecName $logParams"
    
    if (Test-Path $logFile) {
        Write-Host "Installation failed. Displaying log (last 100 lines):"
        Get-Content $logFile -Tail 100 | Write-Host
    }
    
    Throw "Error happened during Python installation. Exit code: $LASTEXITCODE"
}

if ($IsFreeThreaded) {
    # Delete python.exe and create a symlink to free-threaded exe
    Remove-Item -Path "$PythonArchPath\python.exe" -Force
    New-Item -Path "$PythonArchPath\python.exe" -ItemType SymbolicLink -Value "$PythonArchPath\python${MajorVersion}.${MinorVersion}t.exe"
}

Write-Host "Create `python3` symlink"
New-Item -Path "$PythonArchPath\python3.exe" -ItemType SymbolicLink -Value "$PythonArchPath\python.exe"

Write-Host "Install and upgrade Pip"
$Env:PIP_ROOT_USER_ACTION = "ignore"
$PythonExePath = Join-Path -Path $PythonArchPath -ChildPath "python.exe"
cmd.exe /c "$PythonExePath -m ensurepip && $PythonExePath -m pip install --upgrade --force-reinstall pip --no-warn-script-location"
if ($LASTEXITCODE -ne 0) {
    Throw "Error happened during pip installation / upgrade"
}

Write-Host "Create complete file"
New-Item -ItemType File -Path $PythonVersionPath -Name "$Architecture.complete" | Out-Null
