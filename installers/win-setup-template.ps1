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

Write-Host "Install Python $Version in $PythonToolcachePath..."
$ExecParams = Get-ExecParams -IsMSI $IsMSI -IsFreeThreaded $IsFreeThreaded -PythonArchPath $PythonArchPath

# Special handling for Windows ARM64 builds - only apply to ARM64 architecture
$IsWindowsARM64 = ($Architecture -eq "arm64") -or ($Architecture -eq "arm64-freethreaded")

if ($IsWindowsARM64) {
    Write-Host "Special handling for Windows ARM64 installation..."
    
    # For ARM64, we need to handle the installation differently due to issues with the bundled installer
    # The bundled installer has problems with path handling on ARM64, especially for free-threaded builds
    
    # Clear any existing Python registry entries that might interfere
    Write-Host "Cleaning up any conflicting registry entries..."
    $pythonRegPaths = @(
        "HKLM:\SOFTWARE\Python\PythonCore\$MajorVersion.$MinorVersion-arm64",
        "HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore\$MajorVersion.$MinorVersion-arm64",
        "HKCU:\SOFTWARE\Python\PythonCore\$MajorVersion.$MinorVersion-arm64"
    )
    
    foreach ($regPath in $pythonRegPaths) {
        if (Test-Path $regPath) {
            Write-Host "Removing registry path: $regPath"
            Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    # Try to install using the bundled installer with corrected parameters
    $InstallerPath = Join-Path -Path $PythonArchPath -ChildPath $PythonExecName
    
    # For free-threaded builds on ARM64, ensure the correct target directory
    if ($IsFreeThreaded) {
        Write-Host "Installing free-threaded Python for ARM64..."
        # The installer needs to be explicitly told where to put the free-threaded version
        $ExecParams = "TargetDir=`"$PythonArchPath`" InstallAllUsers=1 PrependPath=0 Include_freethreaded=1"
    }
    
    Write-Host "Executing installer: $InstallerPath"
    Write-Host "Parameters: $ExecParams /quiet"
    
    # Use Start-Process for better control and error handling
    $process = Start-Process -FilePath $InstallerPath -ArgumentList "$ExecParams /quiet" -Wait -PassThru -NoNewWindow
    
    if ($process.ExitCode -ne 0) {
        Write-Host "Installation failed with exit code: $($process.ExitCode)"
        
        # Try alternative: Run without /quiet to see what's happening
        Write-Host "Attempting installation with logging enabled..."
        $logFile = Join-Path $env:TEMP "python_install_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
        $ExecParams = "$ExecParams /log `"$logFile`""
        
        $process = Start-Process -FilePath $InstallerPath -ArgumentList $ExecParams -Wait -PassThru -NoNewWindow
        
        if ($process.ExitCode -ne 0) {
            if (Test-Path $logFile) {
                Write-Host "Installation log tail (last 100 lines):"
                Get-Content $logFile -Tail 100 | Write-Host
            }
            
            Throw "Python installation failed with exit code: $($process.ExitCode)"
        }
    }
    
    Write-Host "Installation process completed"
    
    # For free-threaded builds, the executables might be in a different location
    if ($IsFreeThreaded) {
        # Check if the free-threaded executable was installed in the wrong place
        $possiblePaths = @(
            (Join-Path (Split-Path $PythonArchPath -Parent) "arm64"),
            $PythonArchPath
        )
        
        foreach ($path in $possiblePaths) {
            $pythonExe = Join-Path $path "python${MajorVersion}.${MinorVersion}t.exe"
            if (Test-Path $pythonExe) {
                Write-Host "Found Python executable at: $pythonExe"
                
                # If it's in the wrong place, move it
                if ($path -ne $PythonArchPath) {
                    Write-Host "Moving Python files from $path to $PythonArchPath..."
                    Get-ChildItem -Path $path | ForEach-Object {
                        Move-Item -Path $_.FullName -Destination $PythonArchPath -Force
                    }
                }
                break
            }
        }
    }
} else {
    # Original installation method for non-ARM64
    cmd.exe /c "cd $PythonArchPath && call $PythonExecName $ExecParams /quiet"
    if ($LASTEXITCODE -ne 0) {
        Throw "Error happened during Python installation"
    }
}

Write-Host "Verifying installation..."

# Verify Python executable exists
$pythonExe = if ($IsFreeThreaded) {
    Join-Path -Path $PythonArchPath -ChildPath "python${MajorVersion}.${MinorVersion}t.exe"
} else {
    Join-Path -Path $PythonArchPath -ChildPath "python.exe"
}

if (-Not (Test-Path $pythonExe)) {
    Write-Host "Warning: Expected Python executable not found at: $pythonExe"
    Write-Host "Contents of installation directory:"
    Get-ChildItem -Path $PythonArchPath -ErrorAction SilentlyContinue | ForEach-Object { 
        Write-Host "  $($_.Name) [$(if($_.PSIsContainer) {'DIR'} else {$_.Length})]"
    }
    
    # Check parent directory for ARM64 issues
    if ($IsWindowsARM64) {
        $parentPath = Split-Path $PythonArchPath -Parent
        Write-Host "Checking parent directory: $parentPath"
        Get-ChildItem -Path $parentPath -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host "  $($_.Name) [$(if($_.PSIsContainer) {'DIR'} else {'FILE'})]"
        }
    }
}

if ($IsFreeThreaded -and (Test-Path $pythonExe)) {
    # Create symlink for standard python.exe pointing to free-threaded version
    $standardPython = Join-Path -Path $PythonArchPath -ChildPath "python.exe"
    if (Test-Path $standardPython) {
        Remove-Item -Path $standardPython -Force
    }
    Write-Host "Creating symlink: python.exe -> python${MajorVersion}.${MinorVersion}t.exe"
    New-Item -Path $standardPython -ItemType SymbolicLink -Value $pythonExe
}

# Create python3 symlink
$python3Path = Join-Path -Path $PythonArchPath -ChildPath "python3.exe"
if (-Not (Test-Path $python3Path)) {
    $targetExe = Join-Path -Path $PythonArchPath -ChildPath "python.exe"
    if (Test-Path $targetExe) {
        Write-Host "Creating python3.exe symlink"
        New-Item -Path $python3Path -ItemType SymbolicLink -Value $targetExe
    }
}

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
