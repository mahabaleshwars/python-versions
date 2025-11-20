[CmdletBinding()]
param()

[String] $Architecture = "{{__ARCHITECTURE__}}"
[String] $HardwareArchitecture = "{{__HARDWARE_ARCHITECTURE__}}"
[String] $Version = "{{__VERSION__}}"
[String] $PythonExecName = "{{__PYTHON_EXEC_NAME__}}"

# Set strict error handling
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-RegistryVersionFilter {
    param(
        [Parameter(Mandatory)][String] $Architecture,
        [Parameter(Mandatory)][Int32] $MajorVersion,
        [Parameter(Mandatory)][Int32] $MinorVersion
    )

    # Enhanced architecture detection with ARM64 support
    $archFilter = switch -Regex ($Architecture) {
        'x86|32' { "32-bit" }
        'x64|64' { "64-bit" }
        'arm64' { "ARM64" }
        '-freethreaded$' { 
            # Handle free-threaded variants
            $baseArch = $Architecture -replace '-freethreaded$', ''
            switch ($baseArch) {
                'x86' { "32-bit" }
                'x64' { "64-bit" }
                'arm64' { "ARM64" }
                default { "64-bit" }
            }
        }
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

    try {
        $versionFilter = Get-RegistryVersionFilter -Architecture $HardwareArchitecture -MajorVersion $MajorVersion -MinorVersion $MinorVersion
        Write-Verbose "Using registry filter: $versionFilter"

        # Remove UserData registry entries
        $regPath = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products"
        if (Test-Path -Path Registry::$regPath) {
            try {
                $regKeys = Get-ChildItem -Path Registry::$regPath -Recurse -ErrorAction SilentlyContinue | 
                    Where-Object { $_.Property -contains "DisplayName" }
                
                foreach ($key in $regKeys) {
                    try {
                        $displayName = $key.GetValue("DisplayName")
                        if ($displayName -match $versionFilter) {
                            Write-Host "Removing registry key: $($key.PSPath)"
                            Remove-Item -Path $key.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                        }
                    } catch {
                        Write-Warning "Failed to process registry key: $($key.PSPath). Error: $($_.Exception.Message)"
                    }
                }
            } catch {
                Write-Warning "Failed to enumerate UserData registry entries: $($_.Exception.Message)"
            }
        }

        # Remove Installer Products registry entries
        $regPath = "HKEY_CLASSES_ROOT\Installer\Products"
        if (Test-Path -Path Registry::$regPath) {
            try {
                Get-ChildItem -Path Registry::$regPath -ErrorAction SilentlyContinue | ForEach-Object {
                    try {
                        $productName = $_.GetValue("ProductName")
                        if ($productName -match $versionFilter) {
                            Write-Host "Removing registry key: $($_.PSPath)"
                            Remove-Item Registry::$_ -Recurse -Force -ErrorAction SilentlyContinue
                        }
                    } catch {
                        Write-Verbose "Could not read ProductName from $($_.PSPath)"
                    }
                }
            } catch {
                Write-Warning "Failed to enumerate Installer Products registry entries: $($_.Exception.Message)"
            }
        }

        # Enhanced uninstall registry sections with ARM64 support
        $uninstallRegistrySections = @(
            "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall",
            "HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall"
        )

        # Add WOW6432Node paths only for non-ARM64 architectures
        if ($Architecture -notmatch 'arm64') {
            $uninstallRegistrySections += @(
                "HKEY_CURRENT_USER\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
                "HKEY_LOCAL_MACHINE\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
            )
        }

        # Add ARM64 specific registry paths if needed
        if ($Architecture -match 'arm64') {
            $uninstallRegistrySections += @(
                "HKEY_LOCAL_MACHINE\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
                "HKEY_LOCAL_MACHINE\Software\WowAA32Node\Microsoft\Windows\CurrentVersion\Uninstall"
            )
        }

        $uninstallRegistrySections | Where-Object { Test-Path -Path Registry::$_ } | ForEach-Object {
            $currentPath = $_
            try {
                Get-ChildItem -Path Registry::$currentPath -ErrorAction SilentlyContinue | ForEach-Object {
                    try {
                        $displayName = $_.GetValue("DisplayName")
                        if ($displayName -match $versionFilter) {
                            Write-Host "Removing uninstall entry: $($_.PSPath)"
                            Remove-Item Registry::$_ -Recurse -Force -ErrorAction SilentlyContinue
                        }
                    } catch {
                        Write-Verbose "Could not read DisplayName from $($_.PSPath)"
                    }
                }
            } catch {
                Write-Warning "Failed to enumerate uninstall registry section ${currentPath}: $($_.Exception.Message)"
            }
        }
    } catch {
        Write-Warning "Error during registry cleanup: $($_.Exception.Message)"
        # Continue execution even if registry cleanup fails
    }
}

function Get-ExecParams {
    param(
        [Parameter(Mandatory)][Boolean] $IsMSI,
        [Parameter(Mandatory)][Boolean] $IsFreeThreaded,
        [Parameter(Mandatory)][String] $PythonArchPath,
        [Parameter()][String] $Architecture = ""
    )

    if ($IsMSI) {
        # MSI parameters
        $params = "TARGETDIR=`"$PythonArchPath`" ALLUSERS=1"
        
        # Add ARM64 specific MSI parameters if needed
        if ($Architecture -match 'arm64') {
            $params += " MSIARMENABLED=1"
        }
        
        return $params
    } else {
        # EXE installer parameters
        $params = "DefaultAllUsersTargetDir=`"$PythonArchPath`" InstallAllUsers=1"
        
        if ($IsFreeThreaded) {
            $params += " Include_freethreaded=1"
        }
        
        # Add logging for better debugging
        $params += " /log `"$PythonArchPath\install.log`""
        
        return $params
    }
}

function Test-PythonInstallation {
    param(
        [Parameter(Mandatory)][String] $PythonExePath
    )
    
    try {
        $result = & $PythonExePath --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Python installation verified: $result"
            return $true
        }
    } catch {
        Write-Warning "Failed to verify Python installation: $($_.Exception.Message)"
    }
    return $false
}

function Install-PythonWithRetry {
    param(
        [Parameter(Mandatory)][String] $PythonArchPath,
        [Parameter(Mandatory)][String] $PythonExecName,
        [Parameter(Mandatory)][String] $ExecParams,
        [Parameter()][Int32] $MaxRetries = 3
    )
    
    $attempt = 0
    $success = $false
    
    while ($attempt -lt $MaxRetries -and -not $success) {
        $attempt++
        Write-Host "Installation attempt $attempt of $MaxRetries..."
        
        try {
            $process = Start-Process -FilePath "cmd.exe" `
                -ArgumentList "/c `"cd /d `"$PythonArchPath`" && `"$PythonExecName`" $ExecParams /quiet`"" `
                -Wait -PassThru -NoNewWindow
            
            if ($process.ExitCode -eq 0) {
                $success = $true
                Write-Host "Python installation completed successfully."
            } else {
                Write-Warning "Installation failed with exit code: $($process.ExitCode)"
                if ($attempt -lt $MaxRetries) {
                    Write-Host "Waiting 5 seconds before retry..."
                    Start-Sleep -Seconds 5
                }
            }
        } catch {
            Write-Warning "Installation attempt failed: $($_.Exception.Message)"
            if ($attempt -lt $MaxRetries) {
                Start-Sleep -Seconds 5
            }
        }
    }
    
    if (-not $success) {
        throw "Python installation failed after $MaxRetries attempts"
    }
}

# Main script logic
try {
    # Validate input parameters
    if ([string]::IsNullOrWhiteSpace($Architecture)) {
        throw "Architecture parameter is required"
    }
    if ([string]::IsNullOrWhiteSpace($Version)) {
        throw "Version parameter is required"
    }
    if ([string]::IsNullOrWhiteSpace($PythonExecName)) {
        throw "PythonExecName parameter is required"
    }

    # Determine toolcache root with fallback
    $ToolcacheRoot = $env:AGENT_TOOLSDIRECTORY
    if ([string]::IsNullOrEmpty($ToolcacheRoot)) {
        $ToolcacheRoot = $env:RUNNER_TOOL_CACHE
    }
    if ([string]::IsNullOrEmpty($ToolcacheRoot)) {
        # Fallback to a default location
        $ToolcacheRoot = "C:\hostedtoolcache\windows"
        Write-Warning "Using fallback toolcache root: $ToolcacheRoot"
    }

    $PythonToolcachePath = Join-Path -Path $ToolcacheRoot -ChildPath "Python"
    $PythonVersionPath = Join-Path -Path $PythonToolcachePath -ChildPath $Version
    $PythonArchPath = Join-Path -Path $PythonVersionPath -ChildPath $Architecture

    # Detect installation type and features
    $IsMSI = $PythonExecName -match "\.msi$"
    $IsFreeThreaded = $Architecture -match "-freethreaded$"
    $IsARM64 = $Architecture -match "arm64"

    # Parse version with validation
    $VersionParts = $Version.Split('.')
    if ($VersionParts.Count -lt 2) {
        throw "Invalid version format: $Version. Expected format: X.Y.Z"
    }
    
    [Int32]$MajorVersion = $VersionParts[0]
    [Int32]$MinorVersion = $VersionParts[1]

    Write-Host "=== Python Installation Configuration ==="
    Write-Host "Version: $Version"
    Write-Host "Architecture: $Architecture"
    Write-Host "Hardware Architecture: $HardwareArchitecture"
    Write-Host "Installation Path: $PythonArchPath"
    Write-Host "Installer Type: $(if ($IsMSI) { 'MSI' } else { 'EXE' })"
    Write-Host "Free-threaded: $IsFreeThreaded"
    Write-Host "ARM64: $IsARM64"
    Write-Host "========================================"

    # Create toolcache directory if it doesn't exist
    Write-Host "Checking Python hostedtoolcache folder..."
    if (-Not (Test-Path $PythonToolcachePath)) {
        Write-Host "Creating Python toolcache folder: $PythonToolcachePath"
        New-Item -ItemType Directory -Path $PythonToolcachePath -Force | Out-Null
    }

    # Clean up existing installations
    Write-Host "Checking for existing Python $MajorVersion.$MinorVersion installations..."
    $searchPattern = Join-Path -Path $PythonToolcachePath -ChildPath "$MajorVersion.$MinorVersion.*\$Architecture"
    
    try {
        $InstalledVersions = @(Get-Item $searchPattern -ErrorAction SilentlyContinue)
        
        if ($InstalledVersions.Count -gt 0) {
            Write-Host "Found $($InstalledVersions.Count) existing installation(s)..."
            
            foreach ($InstalledVersion in $InstalledVersions) {
                if (Test-Path -Path $InstalledVersion) {
                    Write-Host "Removing: $InstalledVersion"
                    Remove-Item -Path $InstalledVersion -Recurse -Force -ErrorAction SilentlyContinue
                    
                    $completeFile = Join-Path -Path $InstalledVersion.Parent.FullName -ChildPath "$Architecture.complete"
                    if (Test-Path -Path $completeFile) {
                        Remove-Item -Path $completeFile -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        } else {
            Write-Host "No existing Python $MajorVersion.$MinorVersion installations found."
        }
    } catch {
        Write-Verbose "Error checking for existing installations: $($_.Exception.Message)"
    }

    # Clean up registry entries
    Write-Host "Removing registry entries for Python $MajorVersion.$MinorVersion ($Architecture)..."
    Remove-RegistryEntries -Architecture $Architecture -MajorVersion $MajorVersion -MinorVersion $MinorVersion

    # Create installation directory
    Write-Host "Creating Python $Version installation directory..."
    New-Item -ItemType Directory -Path $PythonArchPath -Force | Out-Null

    # Verify installer exists
    if (-Not (Test-Path -Path ".\$PythonExecName")) {
        throw "Python installer not found: .\$PythonExecName"
    }

    # Copy installer to target directory
    Write-Host "Copying Python installer to $PythonArchPath..."
    Copy-Item -Path ".\$PythonExecName" -Destination $PythonArchPath -Force

    # Prepare installation parameters
    Write-Host "Preparing installation parameters..."
    $ExecParams = Get-ExecParams -IsMSI $IsMSI -IsFreeThreaded $IsFreeThreaded -PythonArchPath $PythonArchPath -Architecture $Architecture

    # Install Python with retry logic
    Write-Host "Installing Python $Version..."
    Install-PythonWithRetry -PythonArchPath $PythonArchPath -PythonExecName $PythonExecName -ExecParams $ExecParams

    # Handle free-threaded Python setup
    if ($IsFreeThreaded) {
        Write-Host "Configuring free-threaded Python..."
        $standardPythonPath = Join-Path -Path $PythonArchPath -ChildPath "python.exe"
        $freeThreadedPath = Join-Path -Path $PythonArchPath -ChildPath "python$MajorVersion.$($MinorVersion)t.exe"
        
        if (Test-Path -Path $freeThreadedPath) {
            if (Test-Path -Path $standardPythonPath) {
                Remove-Item -Path $standardPythonPath -Force -ErrorAction SilentlyContinue
            }
            New-Item -Path $standardPythonPath -ItemType SymbolicLink -Value $freeThreadedPath -Force
            Write-Host "Created symlink: python.exe -> python$MajorVersion.$($MinorVersion)t.exe"
        } else {
            Write-Warning "Free-threaded Python executable not found: $freeThreadedPath"
        }
    }

    # Create python3 symlink
    Write-Host "Creating python3 symlink..."
    $python3Path = Join-Path -Path $PythonArchPath -ChildPath "python3.exe"
    $pythonPath = Join-Path -Path $PythonArchPath -ChildPath "python.exe"
    
    if (Test-Path -Path $pythonPath) {
        if (Test-Path -Path $python3Path) {
            Remove-Item -Path $python3Path -Force -ErrorAction SilentlyContinue
        }
        New-Item -Path $python3Path -ItemType SymbolicLink -Value $pythonPath -Force
        Write-Host "Created symlink: python3.exe -> python.exe"
    } else {
        Write-Warning "Python executable not found for symlink creation"
    }

    # Verify Python installation
    $PythonExePath = Join-Path -Path $PythonArchPath -ChildPath "python.exe"
    if (-Not (Test-PythonInstallation -PythonExePath $PythonExePath)) {
        throw "Python installation verification failed"
    }

    # Install and upgrade pip with better error handling
    Write-Host "Installing and upgrading pip..."
    $Env:PIP_ROOT_USER_ACTION = "ignore"
    $Env:PIP_DISABLE_PIP_VERSION_CHECK = "1"
    
    try {
        # First ensure pip is installed
        $ensurePipResult = Start-Process -FilePath $PythonExePath `
            -ArgumentList "-m", "ensurepip", "--default-pip" `
            -Wait -PassThru -NoNewWindow -RedirectStandardError "NUL"
        
        if ($ensurePipResult.ExitCode -ne 0) {
            Write-Warning "ensurepip returned exit code: $($ensurePipResult.ExitCode)"
        }
        
        # Then upgrade pip
        $upgradePipResult = Start-Process -FilePath $PythonExePath `
            -ArgumentList "-m", "pip", "install", "--upgrade", "--force-reinstall", "pip", "--no-warn-script-location" `
            -Wait -PassThru -NoNewWindow -RedirectStandardError "NUL"
        
        if ($upgradePipResult.ExitCode -eq 0) {
            Write-Host "Pip installed and upgraded successfully."
        } else {
            Write-Warning "Pip upgrade returned exit code: $($upgradePipResult.ExitCode)"
        }
    } catch {
        Write-Warning "Error during pip installation/upgrade: $($_.Exception.Message)"
        # Continue execution even if pip upgrade fails
    }

    # Create completion marker file
    Write-Host "Creating completion marker file..."
    $completeFilePath = Join-Path -Path $PythonVersionPath -ChildPath "$Architecture.complete"
    New-Item -ItemType File -Path $completeFilePath -Force | Out-Null

    Write-Host "=== Python $Version ($Architecture) installation completed successfully ==="
    
    # Display installation summary
    Write-Host "`nInstallation Summary:"
    Write-Host "  - Python Path: $PythonExePath"
    Write-Host "  - Architecture: $Architecture"
    Write-Host "  - Version: $Version"
    
    # Test final installation
    & $PythonExePath --version
    & $PythonExePath -m pip --version

} catch {
    Write-Error "Critical error during Python installation: $($_.Exception.Message)"
    exit 1
}
