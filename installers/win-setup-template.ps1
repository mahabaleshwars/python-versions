[String] $Architecture = "{{__ARCHITECTURE__}}"
[String] $HardwareArchitecture = "{{__HARDWARE_ARCHITECTURE__}}"
[String] $Version = "{{__VERSION__}}"
[String] $PythonExecName = "{{__PYTHON_EXEC_NAME__}}"

# This function is no longer reliable for cleanup and is being deprecated.
# We keep it here in case it's used by other parts of the build we can't see.
function Get-RegistryVersionFilter {
    param(
        [Parameter(Mandatory)][String] $Architecture,
        [Parameter(Mandatory)][Int32] $MajorVersion,
        [Parameter(Mandatory)][Int32] $MinorVersion
    )
    $archFilter = switch ($Architecture) {
        'x86' { "32-bit" }
        'arm64' { "ARM64" }
        'arm64-freethreaded' { "ARM64" }
        default { "64-bit" }
    }
    "Python $MajorVersion.$MinorVersion.*($archFilter)"
}

# This is the new, robust cleanup function.
function Remove-InstallationByPath {
    param(
        [Parameter(Mandatory)][String] $InstallPath
    )
    
    # 1. Find the Uninstall string from the registry based on the specific install path.
    $uninstallKeyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    $uninstallKey = Get-ChildItem -Path $uninstallKeyPath -Recurse | ForEach-Object {
        $key = $_
        if (($key.GetValue("InstallLocation") -eq $InstallPath)) {
            return $key
        }
    }

    if ($null -ne $uninstallKey) {
        $uninstallString = $uninstallKey.GetValue("UninstallString")
        if (-not [string]::IsNullOrEmpty($uninstallString)) {
            Write-Host "Found existing installation at specified path. Running uninstaller: $uninstallString"
            # 2. Run the official uninstaller silently and wait for it to complete.
            $command, $args = $uninstallString.Split(' ', 2)
            $process = Start-Process -FilePath $command -ArgumentList "$args /quiet" -Wait -PassThru
            if ($process.ExitCode -ne 0) {
                Write-Host "Uninstaller finished with a non-zero exit code: $($process.ExitCode). Continuing cleanup."
            } else {
                Write-Host "Uninstaller completed successfully."
            }
        }
    }

    # 3. As a final guarantee, forcefully remove the directory.
    if (Test-Path $InstallPath) {
        Write-Host "Forcefully removing installation directory to ensure a clean state: $InstallPath"
        Remove-Item -Path $InstallPath -Recurse -Force
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
# This is the unique, definitive path for this specific architecture.
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

# THE CORE FIX: Instead of searching for and deleting arbitrary registry keys, we now
# perform a targeted uninstall and cleanup based on the *exact* path for the architecture we are about to install.
Write-Host "Ensuring clean installation directory for $PythonArchPath..."
Remove-InstallationByPath -InstallPath $PythonArchPath

# This check for a .complete file is still useful.
$completionFile = Join-Path $PythonVersionPath "$Architecture.complete"
if (Test-Path $completionFile) {
    Remove-Item $completionFile -Force
}

Write-Host "Create Python $Version folder in $PythonToolcachePath"
New-Item -ItemType Directory -Path $PythonArchPath -Force | Out-Null

Write-Host "Copy Python binaries to $PythonArchPath"
Copy-Item -Path ./$PythonExecName -Destination $PythonArchPath | Out-Null

Write-Host "Install Python $Version in $PythonToolcachePath..."
$ExecParams = Get-ExecParams -IsMSI $IsMSI -IsFreeThreaded $IsFreeThreaded -PythonArchPath $PythonArchPath

cmd.exe /c "cd $PythonArchPath && call $PythonExecName $ExecParams /quiet"
if ($LASTEXITCODE -ne 0) {
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
