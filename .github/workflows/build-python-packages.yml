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

    # FIX: Be more specific about architecture in registry filter
    if ($Architecture -eq 'x86') {
        $archFilter = "32-bit"
    } elseif ($Architecture -eq 'arm64' -or $Architecture -eq 'arm64-freethreaded') {
        $archFilter = "ARM64"
    } else {
        $archFilter = "64-bit"
    }
    
    "Python $MajorVersion.$MinorVersion.*($archFilter)"
}

function Remove-RegistryEntries {
    param(
        [Parameter(Mandatory)][String] $Architecture,
        [Parameter(Mandatory)][Int32] $MajorVersion,
        [Parameter(Mandatory)][Int32] $MinorVersion
    )

    # CRITICAL FIX: Use the actual architecture for registry cleanup, not hardware architecture
    $versionFilter = Get-RegistryVersionFilter -Architecture $Architecture -MajorVersion $MajorVersion -MinorVersion $MinorVersion

    $regPath = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products"
    if (Test-Path -Path Registry::$regPath) {
        $regKeys = Get-ChildItem -Path Registry::$regPath -Recurse | Where-Object Property -Ccontains DisplayName
        foreach ($key in $regKeys) {
            if ($key.getValue("DisplayName") -match $versionFilter) {
                Remove-Item -Path $key.PSParentPath -Recurse -Force -Verbose
            }
        }
    }

    $regPath = "HKEY_CLASSES_ROOT\Installer\Products"
    if (Test-Path -Path Registry::$regPath) {
        Get-ChildItem -Path Registry::$regPath | Where-Object { $_.GetValue("ProductName") -match $versionFilter } | ForEach-Object {
            Remove-Item Registry::$_ -Recurse -Force -Verbose
        }
    }

    $uninstallRegistrySections = @(
        "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKEY_CURRENT_USER\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKEY_LOCAL_MACHINE\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    $uninstallRegistrySections | Where-Object { Test-Path -Path Registry::$_ } | ForEach-Object {
        Get-ChildItem -Path Registry::$_ | Where-Object { $_.getValue("DisplayName") -match $versionFilter } | ForEach-Object {
            Remove-Item Registry::$_ -Recurse -Force -Verbose
        }
    }
    
    # ADDITIONAL FIX: Clear Python-specific registry keys for the specific architecture
    $pythonRegPaths = @(
        "HKLM:\SOFTWARE\Python\PythonCore\$MajorVersion.$MinorVersion-arm64",
        "HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore\$MajorVersion.$MinorVersion-arm64",
        "HKCU:\SOFTWARE\Python\PythonCore\$MajorVersion.$MinorVersion-arm64"
    )
    
    if ($Architecture -eq "arm64" -or $Architecture -eq "arm64-freethreaded") {
        foreach ($regPath in $pythonRegPaths) {
            if (Test-Path $regPath) {
                Write-Host "Removing ARM64-specific registry path: $regPath"
                Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
            }
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

function Clear-InstallerCache {
    Write-Host "Clearing Windows Installer cache..."
    
    # Clear any pending installer operations
    Stop-Process -Name msiexec -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    
    # Restart Windows Installer service to clear any cached state
    Write-Host "Restarting Windows Installer service..."
    Restart-Service -Name msiserver -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
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

# CRITICAL FIX: Clear installer cache when installing ARM64 after x64
if ($Architecture -eq "arm64" -or $Architecture -eq "arm64-freethreaded") {
    Clear-InstallerCache
}

Write-Host "Create Python $Version folder in $PythonToolcachePath"
New-Item -ItemType Directory -Path $PythonArchPath -Force | Out-Null

Write-Host "Copy Python binaries to $PythonArchPath"
Copy-Item -Path ./$PythonExecName -Destination $PythonArchPath | Out-Null

Write-Host "Install Python $Version in $PythonToolcachePath..."
$ExecParams = Get-ExecParams -IsMSI $IsMSI -IsFreeThreaded $IsFreeThreaded -PythonArchPath $PythonArchPath

# FIX: For ARM64, ensure clean environment
if ($Architecture -eq "arm64" -or $Architecture -eq "arm64-freethreaded") {
    Write-Host "Installing Python for ARM64 architecture..."
    
    # Clear any x64 Python from PATH temporarily
    $originalPath = $env:PATH
    $env:PATH = $env:PATH -replace '[^;]*Python[^;]*x64[^;]*;?', ''
    
    # Install Python
    cmd.exe /c "cd $PythonArchPath && call $PythonExecName $ExecParams /quiet"
    $installExitCode = $LASTEXITCODE
    
    # Restore original PATH
    $env:PATH = $originalPath
    
    if ($installExitCode -ne 0) {
        Write-Host "Installation failed with exit code: $installExitCode"
        Throw "Error happened during Python installation"
    }
} else {
    # Standard installation for non-ARM64
    cmd.exe /c "cd $PythonArchPath && call $PythonExecName $ExecParams /quiet"
    if ($LASTEXITCODE -ne 0) {
        Throw "Error happened during Python installation"
    }
}

if ($IsFreeThreaded) {
    # Delete python.exe and create a symlink to free-threaded exe
    Remove-Item -Path "$PythonArchPath\python.exe" -Force
    New-Item -Path "$PythonArchPath\python.exe" -ItemType SymbolicLink -Value "$PythonArchPath\python${MajorVersion}.${MinorVersion}t.exe"
}

Write-Host "Create 'python3' symlink"
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
