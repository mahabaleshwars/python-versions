[String] $Architecture = "{{__ARCHITECTURE__}}"
[String] $HardwareArchitecture = "{{__HARDWARE_ARCHITECTURE__}}"
[String] $Version = "{{__VERSION__}}"
[String] $PythonExecName = "{{__PYTHON_EXEC_NAME__}}"

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

function Preemptive-RemoveAllPythonRegistryKeys {
    param(
        [Parameter(Mandatory)][String] $MajorVersion,
        [Parameter(Mandatory)][String] $MinorVersion
    )
    Write-Host "Aggressively removing any pre-existing Python $MajorVersion.$MinorVersion registry keys..."
    $versionString = "Python $MajorVersion.$MinorVersion"

    # Search and destroy any matching keys in the main Uninstall sections
    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($path in $uninstallPaths) {
        if (Test-Path $path) {
            Get-ChildItem -Path $path -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.GetValue("DisplayName") -match [regex]::Escape($versionString)) {
                    Write-Host "Removing pre-existing registry key: $($_.PSPath)"
                    Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
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

# --- AGGRESSIVE CLEANUP AND ROBUST INSTALLATION ---

# 1. Aggressively remove ANY potential conflicting registry keys from the runner.
Preemptive-RemoveAllPythonRegistryKeys -MajorVersion $MajorVersion -MinorVersion $MinorVersion

# 2. Force a reset of the Windows Installer service to clear any stuck processes.
Write-Host "Resetting Windows Installer service..."
Stop-Process -Name msiexec -Force -ErrorAction SilentlyContinue
Restart-Service -Name msiserver -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

Write-Host "Creating Python installation folder at: $PythonArchPath"
New-Item -ItemType Directory -Path $PythonArchPath -Force | Out-Null

$InstallerPath = Join-Path -Path $PythonArchPath -ChildPath $PythonExecName
Write-Host "Copying Python installer to: $InstallerPath"
Copy-Item -Path ./$PythonExecName -Destination $InstallerPath | Out-Null

Write-Host "Starting Python installation..."
$ExecParams = Get-ExecParams -IsMSI $IsMSI -IsFreeThreaded $IsFreeThreaded -PythonArchPath $PythonArchPath

# Use Start-Process for a more reliable execution, now with logging on failure.
try {
    $process = Start-Process -FilePath $InstallerPath -ArgumentList $ExecParams -Wait -PassThru -ErrorAction Stop
    if ($process.ExitCode -ne 0) {
        Throw "Python installer failed with exit code: $($process.ExitCode)"
    }
} catch {
    Write-Host "Initial installation failed. Retrying with verbose logging..."
    $logFile = Join-Path $env:TEMP "python_install_error_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    $logParams = "$ExecParams /log `"$logFile`""
    
    Start-Process -FilePath $InstallerPath -ArgumentList $logParams -Wait -PassThru
    
    if (Test-Path $logFile) {
        Write-Host "Installation failed. Displaying verbose log:"
        Get-Content $logFile | Write-Host
    }
    # Re-throw the original exception to fail the job.
    throw $_
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
