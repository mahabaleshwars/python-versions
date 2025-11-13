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

    $archFilter = if ($Architecture -eq 'x86') { "32-bit" } else { "64-bit" }
    "Python $MajorVersion.$MinorVersion.*($archFilter)"
}

function Remove-RegistryEntries {
    param(
        [Parameter(Mandatory)][String] $Architecture,
        [Parameter(Mandatory)][Int32] $MajorVersion,
        [Parameter(Mandatory)][Int32] $MinorVersion
    )

    $versionFilter = Get-RegistryVersionFilter -Architecture $HardwareArchitecture -MajorVersion $MajorVersion -MinorVersion $MinorVersion

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
$InstalledVersions = Get-Item "$PythonToolcachePath\$MajorVersion.$MinorVersion.*\$Architecture"

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

Write-Host "Create Python $Version folder in $PythonToolcachePath"
New-Item -ItemType Directory -Path $PythonArchPath -Force | Out-Null

Write-Host "Copy Python binaries to $PythonArchPath"
Copy-Item -Path ./$PythonExecName -Destination $PythonArchPath | Out-Null

# Verify the installer was copied successfully
$InstallerPath = Join-Path -Path $PythonArchPath -ChildPath $PythonExecName
if (-Not (Test-Path $InstallerPath)) {
    Throw "Python installer not found at: $InstallerPath"
}

Write-Host "Python installer found at: $InstallerPath"
Write-Host "Installer size: $((Get-Item $InstallerPath).Length) bytes"

Write-Host "Install Python $Version in $PythonToolcachePath..."
$ExecParams = Get-ExecParams -IsMSI $IsMSI -IsFreeThreaded $IsFreeThreaded -PythonArchPath $PythonArchPath

Write-Host "Installation parameters: $ExecParams"
Write-Host "Architecture: $Architecture"
Write-Host "Hardware Architecture: $HardwareArchitecture"
Write-Host "Is Free-threaded: $IsFreeThreaded"

# Special handling for Windows ARM64 builds
$IsWindowsARM64 = ($HardwareArchitecture -eq "ARM64") -or ($Architecture -eq "arm64") -or ($Architecture -eq "arm64-freethreaded")

if ($IsWindowsARM64) {
    Write-Host "Using special installation method for Windows ARM64..."
    Write-Host "Executing: $InstallerPath $ExecParams /quiet"
    
    # Try different installation approaches for ARM64
    try {
        # First attempt: Direct execution with Start-Process
        $process = Start-Process -FilePath $InstallerPath -ArgumentList "$ExecParams /quiet" -Wait -PassThru -NoNewWindow
        $exitCode = $process.ExitCode
        
        if ($exitCode -ne 0) {
            Write-Host "Installation failed with exit code: $exitCode"
            Write-Host "Attempting alternative installation method..."
            
            # Second attempt: Use cmd.exe with full path
            $cmdArgs = "/c `"$InstallerPath`" $ExecParams /quiet"
            Write-Host "Executing: cmd.exe $cmdArgs"
            
            $process = Start-Process -FilePath "cmd.exe" -ArgumentList $cmdArgs -Wait -PassThru -NoNewWindow -WorkingDirectory $PythonArchPath
            $exitCode = $process.ExitCode
        }
        
        if ($exitCode -ne 0) {
            # Log more details for debugging
            Write-Host "Installation failed. Checking for log files..."
            $logFiles = Get-ChildItem -Path $env:TEMP -Filter "Python*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 5
            foreach ($log in $logFiles) {
                Write-Host "Log file: $($log.FullName)"
                Write-Host "Last 50 lines:"
                Get-Content $log.FullName -Tail 50 | Write-Host
            }
            Throw "Error happened during Python installation. Exit code: $exitCode"
        }
    }
    catch {
        Write-Host "Exception during installation: $_"
        Throw
    }
} else {
    # Original installation method for non-ARM64
    Write-Host "Using standard installation method..."
    Write-Host "Executing: cd $PythonArchPath && call $PythonExecName $ExecParams /quiet"
    
    cmd.exe /c "cd $PythonArchPath && call $PythonExecName $ExecParams /quiet"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Installation failed with exit code: $LASTEXITCODE"
        
        # Check for installation logs
        $logFiles = Get-ChildItem -Path $env:TEMP -Filter "Python*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 5
        foreach ($log in $logFiles) {
            Write-Host "Log file: $($log.FullName)"
            Write-Host "Last 50 lines:"
            Get-Content $log.FullName -Tail 50 | Write-Host
        }
        
        Throw "Error happened during Python installation"
    }
}

Write-Host "Installation completed successfully"

# Verify installation by checking for Python executable
$pythonExe = if ($IsFreeThreaded) {
    Join-Path -Path $PythonArchPath -ChildPath "python${MajorVersion}.${MinorVersion}t.exe"
} else {
    Join-Path -Path $PythonArchPath -ChildPath "python.exe"
}

if (-Not (Test-Path $pythonExe)) {
    Write-Host "Warning: Python executable not found at expected location: $pythonExe"
    Write-Host "Contents of $PythonArchPath:"
    Get-ChildItem -Path $PythonArchPath | ForEach-Object { Write-Host "  $_" }
}

if ($IsFreeThreaded) {
    # Delete python.exe and create a symlink to free-threaded exe
    $standardPython = Join-Path -Path $PythonArchPath -ChildPath "python.exe"
    if (Test-Path $standardPython) {
        Remove-Item -Path $standardPython -Force
    }
    New-Item -Path $standardPython -ItemType SymbolicLink -Value "$PythonArchPath\python${MajorVersion}.${MinorVersion}t.exe"
}

Write-Host "Create 'python3' symlink"
New-Item -Path "$PythonArchPath\python3.exe" -ItemType SymbolicLink -Value "$PythonArchPath\python.exe"

Write-Host "Install and upgrade Pip"
$Env:PIP_ROOT_USER_ACTION = "ignore"
$PythonExePath = Join-Path -Path $PythonArchPath -ChildPath "python.exe"

if (Test-Path $PythonExePath) {
    cmd.exe /c "$PythonExePath -m ensurepip && $PythonExePath -m pip install --upgrade --force-reinstall pip --no-warn-script-location"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Warning: Pip installation/upgrade failed with exit code: $LASTEXITCODE"
        # Don't throw here, as Python might still be usable
    }
} else {
    Write-Host "Warning: Python executable not found for pip installation at: $PythonExePath"
}

Write-Host "Create complete file"
New-Item -ItemType File -Path $PythonVersionPath -Name "$Architecture.complete" | Out-Null

Write-Host "Python $Version $Architecture setup completed"