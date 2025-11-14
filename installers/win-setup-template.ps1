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
        "TARGETDIR=`"$PythonArchPath`" ALLUSERS=1"
    } else {
        $Include_freethreaded = if ($IsFreeThreaded) { "Include_freethreaded=1" } else { "" }
        # For ARM64, use simpler parameters to avoid MSI issues
        if ($Architecture -eq "arm64" -or $Architecture -eq "arm64-freethreaded") {
            "TargetDir=`"$PythonArchPath`" InstallAllUsers=1 PrependPath=0 Include_test=0 Include_doc=0 Include_dev=0 $Include_freethreaded"
        } else {
            "DefaultAllUsersTargetDir=`"$PythonArchPath`" InstallAllUsers=1 $Include_freethreaded"
        }
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

# Check Windows Installer service status for ARM64
if ($Architecture -eq "arm64" -or $Architecture -eq "arm64-freethreaded") {
    Write-Host "Checking Windows Installer service status..."
    $msiService = Get-Service -Name msiserver -ErrorAction SilentlyContinue
    if ($msiService) {
        Write-Host "Windows Installer service status: $($msiService.Status)"
        if ($msiService.Status -ne "Running") {
            Write-Host "Starting Windows Installer service..."
            Start-Service -Name msiserver -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
    }
}

Write-Host "Install Python $Version in $PythonToolcachePath..."
$ExecParams = Get-ExecParams -IsMSI $IsMSI -IsFreeThreaded $IsFreeThreaded -PythonArchPath $PythonArchPath

Write-Host "Installation parameters: $ExecParams"
Write-Host "Architecture: $Architecture"  
Write-Host "Hardware Architecture: $HardwareArchitecture"
Write-Host "Is Free-threaded: $IsFreeThreaded"

# Special handling for Windows ARM64 builds
$IsWindowsARM64 = ($Architecture -eq "arm64") -or ($Architecture -eq "arm64-freethreaded")

if ($IsWindowsARM64) {
    Write-Host "Using special installation method for Windows ARM64..."
    
    # For ARM64, try passive installation first (shows progress but no interaction)
    Write-Host "Attempting passive installation for better diagnostics..."
    $passiveParams = $ExecParams.Replace("/quiet", "/passive")
    
    # Extract MSI files first for ARM64
    Write-Host "Extracting installer components..."
    $extractPath = Join-Path $env:TEMP "python_extract_$([System.Guid]::NewGuid())"
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
    
    # Try extraction first
    $extractArgs = "/layout `"$extractPath`" /quiet"
    $process = Start-Process -FilePath $InstallerPath -ArgumentList $extractArgs -Wait -PassThru -NoNewWindow
    
    if ($process.ExitCode -eq 0 -and (Test-Path $extractPath)) {
        Write-Host "Extraction successful. Contents:"
        Get-ChildItem $extractPath -Recurse | Select-Object Name, Length | Format-Table
        
        # Try installing from extracted MSI files
        $coreMsi = Get-ChildItem -Path $extractPath -Filter "core*.msi" -Recurse | Select-Object -First 1
        if ($coreMsi) {
            Write-Host "Installing core MSI directly: $($coreMsi.FullName)"
            $msiArgs = "/i `"$($coreMsi.FullName)`" TARGETDIR=`"$PythonArchPath`" ALLUSERS=1 /qn /l*v `"$env:TEMP\python_core_install.log`""
            $msiProcess = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
            
            if ($msiProcess.ExitCode -ne 0) {
                Write-Host "Core MSI installation failed with exit code: $($msiProcess.ExitCode)"
                if (Test-Path "$env:TEMP\python_core_install.log") {
                    Write-Host "MSI Log tail:"
                    Get-Content "$env:TEMP\python_core_install.log" -Tail 30 | Write-Host
                }
            } else {
                Write-Host "Core MSI installed successfully"
            }
        }
        
        # Clean up extraction
        Remove-Item -Path $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    # If extraction failed or didn't help, try standard installation
    if (-not (Test-Path "$PythonArchPath\python.exe")) {
        Write-Host "Attempting standard installation..."
        $process = Start-Process -FilePath $InstallerPath -ArgumentList "$ExecParams /quiet" -Wait -PassThru -NoNewWindow
        $exitCode = $process.ExitCode
        
        if ($exitCode -ne 0) {
            Write-Host "Installation failed with exit code: $exitCode"
            
            # Get detailed error information
            $errorMessage = switch ($exitCode) {
                1603 { "Fatal error during installation - MSI package incompatibility or missing prerequisites" }
                1618 { "Another installation is in progress" }
                1619 { "Installation package could not be opened" }
                1620 { "Installation package could not be opened - invalid package" }
                1625 { "Installation prohibited by system policy" }
                3010 { "Restart required" }
                default { "Unknown error" }
            }
            Write-Host "Error details: $errorMessage"
            
            # Check event logs
            Write-Host "Checking Windows event logs for installation errors..."
            $events = Get-WinEvent -LogName Application -MaxEvents 10 | Where-Object { $_.Message -like "*Python*" -or $_.Message -like "*MSI*" }
            foreach ($evt in $events) {
                Write-Host "Event: $($evt.TimeCreated) - $($evt.Message)"
            }
            
            Throw "Error happened during Python installation. Exit code: $exitCode - $errorMessage"
        }
    }
} else {
    # Original installation method for non-ARM64
    Write-Host "Using standard installation method..."
    cmd.exe /c "cd /d `"$PythonArchPath`" && `"$PythonExecName`" $ExecParams /quiet"
    if ($LASTEXITCODE -ne 0) {
        Throw "Error happened during Python installation"
    }
}

Write-Host "Installation completed"

# Verify installation by checking for Python executable
$pythonExe = if ($IsFreeThreaded) {
    Join-Path -Path $PythonArchPath -ChildPath "python${MajorVersion}.${MinorVersion}t.exe"
} else {
    Join-Path -Path $PythonArchPath -ChildPath "python.exe"
}

if (-Not (Test-Path $pythonExe)) {
    Write-Host "Warning: Python executable not found at expected location: $pythonExe"
    Write-Host "Contents of ${PythonArchPath}:"
    Get-ChildItem -Path $PythonArchPath -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
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
    }
} else {
    Write-Host "Warning: Python executable not found for pip installation at: $PythonExePath"
}

Write-Host "Create complete file"
New-Item -ItemType File -Path $PythonVersionPath -Name "$Architecture.complete" | Out-Null

Write-Host "Python $Version $Architecture setup completed"
