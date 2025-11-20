[String] $Architecture = "{{__ARCHITECTURE__}}"
[String] $HardwareArchitecture = "{{__HARDWARE_ARCHITECTURE__}}"
[String] $Version = "{{__VERSION__}}"
[String] $PythonExecName = "{{__PYTHON_EXEC_NAME__}}"

# This function is now only used for finding registry keys to delete.
function Get-RegistryKeyByInstallPath {
    param(
        [Parameter(Mandatory)][String] $InstallPath
    )
    $uninstallKeyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    # Find all uninstall keys that point to the specific installation directory.
    return Get-ChildItem -Path $uninstallKeyPath -Recurse | Where-Object { $_.GetValue("InstallLocation") -eq $InstallPath }
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
# This is the unique, definitive path for the architecture being installed.
$PythonArchPath = Join-Path -Path $PythonVersionPath -ChildPath $Architecture

$IsMSI = $PythonExecName -match "msi"
$IsFreeThreaded = $Architecture -match "-freethreaded"

$MajorVersion = $Version.Split('.')[0]
$MinorVersion = $Version.Split('.')[1]

# --- NEW, SIMPLIFIED CLEANUP LOGIC ---

Write-Host "Checking for existing installation at target path: $PythonArchPath"
# This is the core of the new logic. We only act if the specific directory for this architecture already exists.
if (Test-Path $PythonArchPath) {
    Write-Host "Existing installation found. Performing targeted cleanup..."

    # 1. Find the specific registry keys associated with this *exact* installation path.
    $registryKeys = Get-RegistryKeyByInstallPath -InstallPath $PythonArchPath
    if ($null -ne $registryKeys) {
        foreach ($key in $registryKeys) {
            Write-Host "Removing registry key: $($key.PSPath)"
            Remove-Item -Path $key.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "No associated registry keys found for this path."
    }

    # 2. Forcefully remove the directory. This is the most reliable way to ensure a clean slate.
    Write-Host "Forcefully removing installation directory: $PythonArchPath"
    Remove-Item -Path $PythonArchPath -Recurse -Force

    # 3. Also remove the completion marker file if it exists.
    $completionFile = Join-Path $PythonVersionPath "$Architecture.complete"
    if (Test-Path $completionFile) {
        Write-Host "Removing completion marker file."
        Remove-Item $completionFile -Force
    }
    
    Write-Host "Targeted cleanup complete."
} else {
    Write-Host "No previous installation found at target path. No cleanup needed."
}
# --- END OF NEW CLEANUP LOGIC ---

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
