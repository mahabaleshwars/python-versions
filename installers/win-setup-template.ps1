[String] $Architecture = "{{__ARCHITECTURE__}}"
[String] $HardwareArchitecture = "{{__HARDWARE_ARCHITECTURE__}}"
[String] $Version = "{{__VERSION__}}"
[String] $PythonExecName = "{{__PYTHON_EXEC_NAME__}}"

function Get-RegistryKeyByInstallPath {
    param(
        [Parameter(Mandatory)][String] $InstallPath
    )
    $uninstallKeyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    return Get-ChildItem -Path $uninstallKeyPath -Recurse | Where-Object { $_.GetValue("InstallLocation") -eq $InstallPath }
}

function Get-ExecParams {
    param(
        [Parameter(Mandatory)][Boolean] $IsMSI,
        [Parameter(Mandatory)][Boolean] $IsFreeThreaded,
        [Parameter(Mandatory)][String] $PythonArchPath
    )

    if ($IsMSI) {
        "TARGETDIR=$PythonArchPath ALLUSERS=1 /quiet"
    } else {
        $Include_freethreaded = if ($IsFreeThreaded) { "Include_freethreaded=1" } else { "" }
        "DefaultAllUsersTargetDir=$PythonArchPath InstallAllUsers=1 $Include_freethreaded /quiet"
    }
}

$ToolcacheRoot = $env:AGENT_TOOLSDIRECTORY
if ([string]::IsNullOrEmpty($ToolcacheRoot)) {
    $ToolcacheRoot = $env:RUNNER_TOOL_CACHE
}
$PythonToolcachePath = Join-Path -Path $ToolcacheRoot -ChildPath "Python"
$PythonVersionPath = Join-Path -Path $PythonToolcachePath -ChildPath $Version
$PythonArchPath = Join-Path -Path $PythonVersionPath -ChildPath $Architecture

$IsMSI = $PythonExecName -match "msi"
$IsFreeThreaded = $Architecture -match "-freethreaded"

$MajorVersion = $Version.Split('.')[0]
$MinorVersion = $Version.Split('.')[1]

# --- SIMPLIFIED CLEANUP LOGIC ---
Write-Host "Checking for existing installation at target path: $PythonArchPath"
if (Test-Path $PythonArchPath) {
    Write-Host "Existing installation found. Performing targeted cleanup..."
    $registryKeys = Get-RegistryKeyByInstallPath -InstallPath $PythonArchPath
    if ($null -ne $registryKeys) {
        foreach ($key in $registryKeys) {
            Write-Host "Removing registry key: $($key.PSPath)"
            Remove-Item -Path $key.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "Forcefully removing installation directory: $PythonArchPath"
    Remove-Item -Path $PythonArchPath -Recurse -Force
    $completionFile = Join-Path $PythonVersionPath "$Architecture.complete"
    if (Test-Path $completionFile) { Remove-Item $completionFile -Force }
} else {
    Write-Host "No previous installation found at target path."
}

# --- ROBUST INSTALLATION EXECUTION ---

# 1. Force a reset of the Windows Installer service before EVERY installation.
# This prevents hangs caused by a stuck or corrupted installer service on the runner.
Write-Host "Resetting Windows Installer service to ensure a clean state..."
Stop-Process -Name msiexec -Force -ErrorAction SilentlyContinue
Restart-Service -Name msiserver -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3 # Give the service a moment to settle.
Write-Host "Windows Installer service has been reset."

Write-Host "Creating Python installation folder at: $PythonArchPath"
New-Item -ItemType Directory -Path $PythonArchPath -Force | Out-Null

$InstallerPath = Join-Path -Path $PythonArchPath -ChildPath $PythonExecName
Write-Host "Copying Python installer to: $InstallerPath"
Copy-Item -Path ./$PythonExecName -Destination $InstallerPath | Out-Null

Write-Host "Starting Python installation..."
$ExecParams = Get-ExecParams -IsMSI $IsMSI -IsFreeThreaded $IsFreeThreaded -PythonArchPath $PythonArchPath

# 2. Use PowerShell's Start-Process for a more reliable, wait-enabled execution.
# This avoids potential issues with `cmd.exe /c call`.
$process = Start-Process -FilePath $InstallerPath -ArgumentList $ExecParams -Wait -PassThru -ErrorAction Stop

if ($process.ExitCode -ne 0) {
    Throw "Python installer failed with exit code: $($process.ExitCode)"
}

Write-Host "Python installation completed successfully."

# --- POST-INSTALLATION STEPS ---
if ($IsFreeThreaded) {
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
