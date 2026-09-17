# Windows PowerShell installation script for Komari Agent

# Logging functions with colors
function Log-Info { param([string]$Message) Write-Host "$Message"    -ForegroundColor Cyan }
function Log-Success { param([string]$Message) Write-Host "$Message"    -ForegroundColor Green }
function Log-Warning { param([string]$Message) Write-Host "[WARNING] $Message"    -ForegroundColor Yellow }
function Log-Error { param([string]$Message) Write-Host "[ERROR] $Message"    -ForegroundColor Red }
function Log-Step { param([string]$Message) Write-Host "$Message"    -ForegroundColor Magenta }
function Log-Config { param([string]$Message) Write-Host "- $Message"    -ForegroundColor White }

# Default parameters
$InstallDir = Join-Path $Env:ProgramFiles "Komari"
$ServiceName = "komari-agent"
$GitHubProxy = ""
$KomariArgs = @()
$InstallVersion = ""
$RemoteControlChoice = "" # "", "enabled" or "disabled"

# ---------------------------------------------------------------------------
# Release source (fork-owned). Owner/repo are defined HERE ONLY — do not
# hardcode the slug anywhere else in this script.
# All values can be overridden through environment variables.
# ---------------------------------------------------------------------------
$RepoOwner = if ($env:KOMARI_AGENT_REPO_OWNER) { $env:KOMARI_AGENT_REPO_OWNER } else { "xinian5216" }
$RepoName = if ($env:KOMARI_AGENT_REPO_NAME) { $env:KOMARI_AGENT_REPO_NAME } else { "komari-agent-stable" }
$GitHubApiBase = if ($env:KOMARI_AGENT_API_BASE) { $env:KOMARI_AGENT_API_BASE } else { "https://api.github.com" }
$GitHubReleaseBase = if ($env:KOMARI_AGENT_RELEASE_BASE) { $env:KOMARI_AGENT_RELEASE_BASE } else { "https://github.com" }
$RepoSlug = "$RepoOwner/$RepoName"

# Remote control policy for new installations: monitoring only unless the
# operator explicitly opts in. KOMARI_AGENT_REMOTE_CONTROL=1|0 is the
# environment equivalent of --enable/--disable-remote-control; an explicit
# command line option below overrides it.
if ($env:KOMARI_AGENT_REMOTE_CONTROL) {
    $value = $env:KOMARI_AGENT_REMOTE_CONTROL.Trim().ToLower()
    switch ($value) {
        { $_ -in @("1", "true", "yes", "enabled") } { $RemoteControlChoice = "enabled"; break }
        { $_ -in @("0", "false", "no", "disabled") } { $RemoteControlChoice = "disabled"; break }
        default {
            Log-Error "Invalid KOMARI_AGENT_REMOTE_CONTROL value: $($env:KOMARI_AGENT_REMOTE_CONTROL) (expected 1 or 0)"
            exit 1
        }
    }
}

# Parse script arguments
for ($i = 0; $i -lt $args.Count; $i++) {
    switch ($args[$i]) {
        "--install-dir" { $InstallDir = $args[$i + 1]; $i++; continue }
        "--install-service-name" { $ServiceName = $args[$i + 1]; $i++; continue }
        "--install-ghproxy" { $GitHubProxy = $args[$i + 1]; $i++; continue }
        "--install-version" { $InstallVersion = $args[$i + 1]; $i++; continue }
        "--enable-remote-control" { $RemoteControlChoice = "enabled"; continue }
        "--disable-remote-control" { $RemoteControlChoice = "disabled"; continue }
        Default { $KomariArgs += $args[$i] }
    }
}

# Ensure running as Administrator
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Log-Error "Please run this script as Administrator."
    exit 1
}

# Prepare GitHub proxy display
if ($GitHubProxy -ne '') { $ProxyDisplay = $GitHubProxy } else { $ProxyDisplay = '(direct)' }

# Detect architecture early for constructing binary name
switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { $arch = 'amd64' }
    'ARM64' { $arch = 'arm64' }
    'x86' { $arch = '386' }
    Default { Log-Error "Unsupported architecture: $env:PROCESSOR_ARCHITECTURE"; exit 1 }
}

# Ensure installation directory exists for nssm and agent
Log-Step "Ensuring installation directory exists: $InstallDir"
New-Item -ItemType Directory -Path $InstallDir -Force -ErrorAction SilentlyContinue | Out-Null # Ensure $InstallDir exists

# Check for nssm and download if not present
$nssmExeToUse = Join-Path $InstallDir "nssm.exe"

# First, check if nssm is in PATH and is functional
$nssmCmd = Get-Command nssm -ErrorAction SilentlyContinue
if ($nssmCmd) {
    Log-Info "nssm found in PATH at $($nssmCmd.Source)."
    try {
        $nssmVersionOutput = nssm version 2>&1
        Log-Info "Detected nssm version: $nssmVersionOutput"
    }
    catch {
        Log-Warning "nssm found in PATH failed to execute 'nssm version'. Will attempt to use/download local copy. Error: $_"
        $nssmCmd = $null # Force re-evaluation for local copy or download
    }
}

# If nssm not found in PATH or the one in PATH failed, check local $InstallDir
if (-not $nssmCmd) {
    if (Test-Path $nssmExeToUse) {
        Log-Info "nssm found at $nssmExeToUse. Attempting to use it by adding $InstallDir to PATH."
        $env:Path = "$($InstallDir);$($env:Path)"
        $nssmCmd = Get-Command nssm -ErrorAction SilentlyContinue
        if ($nssmCmd) {
            try {
                $nssmVersionOutput = nssm version 2>&1
            }
            catch {
                Log-Warning "nssm from $InstallDir failed to execute 'nssm version'. Error: $_"
                $nssmCmd = $null # Mark as unusable
            }
        }
        else {
            Log-Warning "Failed to make nssm from $nssmExeToUse available via PATH. Will attempt download."
        }
    }
}

# If still no usable nssm command, proceed to download
if (-not $nssmCmd) {
    Log-Info "nssm not found or not usable. Attempting to download to $InstallDir..."
    $NssmVersion = "2.24"
    $NssmZipUrl = "https://nssm.cc/release/nssm-$NssmVersion.zip"
    $TempNssmZipPath = Join-Path $env:TEMP "nssm-$NssmVersion.zip"
    $TempExtractDir = Join-Path $env:TEMP "nssm_extract_temp"

    try {
        Log-Info "Downloading nssm from $NssmZipUrl..."
        Invoke-WebRequest -Uri $NssmZipUrl -OutFile $TempNssmZipPath -UseBasicParsing

        if (Test-Path $TempExtractDir) { Remove-Item -Recurse -Force $TempExtractDir }
        New-Item -ItemType Directory -Path $TempExtractDir -Force | Out-Null
        Expand-Archive -Path $TempNssmZipPath -DestinationPath $TempExtractDir -Force
        
        $NssmSourceDirInsideZip = "nssm-$NssmVersion" # Used for Get-ChildItem search path
        # The path part within the extracted nssm folder, e.g., "nssm-2.24\win32"
        # 'win32' nssm is used for both 'amd64' and 'arm64' PowerShell architectures.
        $NssmArchSubDir = Join-Path "nssm-$NssmVersion" "win32"
        $NssmSourceExePath = Join-Path (Join-Path $TempExtractDir $NssmArchSubDir) "nssm.exe"

        if (-not (Test-Path $NssmSourceExePath)) {
            Log-Error "Could not find nssm.exe at expected path: $NssmSourceExePath after extraction."
            # Fallback search for nssm.exe within the extracted directory
            $foundNssmFallback = Get-ChildItem -Path $TempExtractDir -Recurse -Filter "nssm.exe" | 
            Where-Object { $_.FullName -like "*$NssmArchSubDir\nssm.exe" } | 
            Select-Object -First 1
            if ($foundNssmFallback) {
                Log-Warning "Found nssm.exe at $($foundNssmFallback.FullName) using fallback search. Using this."
                $NssmSourceExePath = $foundNssmFallback.FullName
            }
            else {
                Log-Error "nssm.exe ($NssmArchSubDir) still not found in $TempExtractDir. Please install nssm manually (from https://nssm.cc) and ensure it's in your PATH."
                exit 1
            }
        }
        
        Copy-Item -Path $NssmSourceExePath -Destination $nssmExeToUse -Force

        $env:Path = "$($InstallDir);$($env:Path)"
        $nssmCmd = Get-Command nssm -ErrorAction SilentlyContinue # Re-check after adding to PATH
        if ($nssmCmd) {
            Log-Success "Downloaded nssm is now configured and available in PATH."
        }
        else {
            Log-Error "Failed to configure downloaded nssm in PATH from $nssmExeToUse. Please ensure $InstallDir is in your system PATH or nssm is installed globally."
            exit 1
        }
    }
    catch {
        Log-Error "Failed to download or configure nssm: $_"
        Log-Error "Please install nssm manually from https://nssm.cc and ensure nssm.exe is in your PATH."
        exit 1
    }
    finally {
        if (Test-Path $TempNssmZipPath) { Remove-Item $TempNssmZipPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $TempExtractDir) { Remove-Item $TempExtractDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Final check that nssm is operational
try {
    $nssmVersionOutput = nssm version 2>&1
}
catch {
    Log-Error "nssm command failed to execute even after setup attempts. Please check the nssm installation and PATH. Error: $_"
    exit 1
}

Log-Step "Installation configuration:"
Log-Config "Service name: $ServiceName"
Log-Config "Install directory: $InstallDir"
Log-Config "GitHub proxy: $ProxyDisplay"
Log-Config "Agent arguments: $($KomariArgs -join ' ')"
if ($InstallVersion -ne "") {
    Log-Config "Specified agent version: $InstallVersion"
} else {
    Log-Config "Agent version: Latest"
}

# ---------------------------------------------------------------------------
# Remote control resolution
# ---------------------------------------------------------------------------
# An existing installation keeps its remote control setting. Only an explicit
# option (flag or KOMARI_AGENT_REMOTE_CONTROL) changes it; when the setting of
# an existing service cannot be read reliably the installer stops instead of
# guessing.
function Get-ExistingRemoteControlState {
    $statusOutput = (nssm status $ServiceName 2>&1) -join ' '
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service -and ($statusOutput -match "does not exist" -or $statusOutput -notmatch "SERVICE_")) {
        return "absent"
    }

    $readable = $false
    $argsLine = ""

    $nssmArgs = nssm get $ServiceName AppParameters 2>$null
    if ($LASTEXITCODE -eq 0) {
        $readable = $true
        $argsLine = ($nssmArgs -join ' ')
    }

    if (-not $readable) {
        try {
            $reg = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName\Parameters" -Name AppParameters -ErrorAction Stop
            $readable = $true
            $argsLine = [string]$reg.AppParameters
        }
        catch { }
    }

    if (-not $readable) {
        return "unknown"
    }
    if ($argsLine -match '--disable-web-ssh' -or $argsLine -match '--disable-remote-control') {
        return "disabled"
    }
    return "enabled"
}

$existingRemoteControl = Get-ExistingRemoteControlState
if ($existingRemoteControl -eq "unknown" -and $RemoteControlChoice -eq "") {
    Log-Error "An existing service for $ServiceName was found, but its remote control setting could not be read."
    Log-Info "Refusing to change it silently. Re-run with either:"
    Log-Info "  --disable-remote-control   (monitoring only)"
    Log-Info "  --enable-remote-control    (keep remote control available)"
    exit 1
}

if ($RemoteControlChoice -ne "") {
    $RemoteControlDecision = $RemoteControlChoice
    $RemoteControlSource = "explicit option"
}
elseif ($existingRemoteControl -eq "disabled" -or $existingRemoteControl -eq "enabled") {
    $RemoteControlDecision = $existingRemoteControl
    $RemoteControlSource = "kept from the existing service"
}
else {
    $RemoteControlDecision = "disabled"
    $RemoteControlSource = "default for new installations"
}

if ($RemoteControlDecision -eq "enabled") {
    $argsLine = $KomariArgs -join ' '
    if ($argsLine -match '--disable-web-ssh' -or $argsLine -match '--disable-remote-control') {
        Log-Error "Conflicting options: remote control is enabled but a disabling flag was passed through."
        exit 1
    }
}
Log-Config "Remote control: $RemoteControlDecision ($RemoteControlSource)"

# Paths
$BinaryName = "komari-agent-windows-$arch.exe"
$AgentPath = Join-Path $InstallDir "komari-agent.exe"

# Uninstall previous service and binary
function Uninstall-Previous {
    Log-Step "Checking for existing service..."
    # Check if service exists using nssm status, as Get-Service might not work for nssm services if not properly registered
    $serviceStatus = nssm status $ServiceName 2>&1
    if ($serviceStatus -notmatch "SERVICE_STOPPED" -and $serviceStatus -notmatch "does not exist") {
        Log-Info "Stopping service $ServiceName..."
        nssm stop $ServiceName 2>&1 | Out-Null
    }
    # Attempt to remove the service using nssm
    # We check if it exists first by trying to get its status.
    # nssm remove will succeed if the service exists, and fail otherwise.
    # We add confirm to avoid interactive prompts.
    $removeOutput = nssm remove $ServiceName confirm 2>&1
    if ($LASTEXITCODE -eq 0) {
    }
    elseif ($removeOutput -match "Can't open service! (The specified service does not exist as an installed service.)" -or $removeOutput -match "No such service" -or $removeOutput -match "does not exist") {
        Log-Info "Service $ServiceName does not exist or was already removed."
    }
    else {
        # If nssm remove fails for other reasons, try sc.exe delete as a fallback for older installations
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc) {
            Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
            sc.exe delete $ServiceName | Out-Null
        }
    }

    if (Test-Path $AgentPath) {
        Log-Warning "Removing old binary..."
        Remove-Item $AgentPath -Force
    }
}

function Get-LatestSnapshotVersion {
    param([Parameter(Mandatory = $true)][string]$AssetName)

    $ApiUrl = "$GitHubApiBase/repos/$RepoSlug/releases?per_page=100"
    $ApiUrls = @($ApiUrl)
    if ($GitHubProxy -ne "") {
        $ApiUrls = @("$GitHubProxy/$ApiUrl", $ApiUrl)
    }

    for ($i = 0; $i -lt $ApiUrls.Count; $i++) {
        try {
            Log-Info "Fetching snapshot releases from GitHub API..."
            $releases = Invoke-RestMethod -Uri $ApiUrls[$i] -UseBasicParsing
        }
        catch {
            $releases = $null
        }

        if ($releases) {
            $latestSnapshot = $releases |
            Where-Object {
                $_.draft -eq $false -and
                $_.prerelease -eq $true -and
                $_.tag_name -like "Snapshot-*" -and
                (@($_.assets.name) -contains $AssetName)
            } |
            Sort-Object -Property @{ Expression = { [datetime]$_.published_at }; Descending = $true }, @{ Expression = { $_.tag_name }; Descending = $true } |
            Select-Object -First 1

            if ($latestSnapshot) {
                return $latestSnapshot.tag_name
            }
        }

        if ($i -lt ($ApiUrls.Count - 1)) {
            Log-Warning "Failed to resolve snapshot releases through GitHub proxy, retrying directly."
        }
    }

    throw "No snapshot release contains asset $AssetName."
}

$versionToInstall = ""
if ($InstallVersion -ne "") {
    Log-Info "Attempting to install specified version: $InstallVersion"
    if ($InstallVersion -ieq "snapshot") {
        Log-Info "Resolving the latest snapshot version..."
        try {
            $versionToInstall = Get-LatestSnapshotVersion -AssetName $BinaryName
            Log-Success "Latest snapshot version fetched: $versionToInstall"
        }
        catch {
            Log-Error "Failed to resolve the latest snapshot version: $_"
            exit 1
        }
    }
    else {
        $versionToInstall = $InstallVersion
    }
}
else {
    $ApiUrl = "$GitHubApiBase/repos/$RepoSlug/releases/latest"
    try {
        Log-Step "Fetching latest release version from GitHub API..."
        $release = Invoke-RestMethod -Uri $ApiUrl -UseBasicParsing
        $versionToInstall = $release.tag_name
        Log-Success "Latest version fetched: $versionToInstall"
    }
    catch {
        Log-Error "Failed to fetch latest version: $_"
        exit 1
    }
}
Log-Success "Installing Komari Agent version: $versionToInstall"

# Construct download URL
$BinaryName = "komari-agent-windows-$arch.exe"
$DownloadUrl = if ($GitHubProxy) { "$GitHubProxy/$GitHubReleaseBase/$RepoSlug/releases/download/$versionToInstall/$BinaryName" } else { "$GitHubReleaseBase/$RepoSlug/releases/download/$versionToInstall/$BinaryName" }

# Download and install (fail closed)
#
# The binary is downloaded to a temporary file and only moved to its final path
# after its SHA256 has been verified against the checksum assets of the same
# release. A missing, malformed or mismatching checksum aborts the installation
# and leaves an already installed agent untouched.
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Log-Info "URL: $DownloadUrl"

$ChecksumBaseUrl = $DownloadUrl.Substring(0, $DownloadUrl.LastIndexOf("/"))
$DownloadTemp = "$AgentPath.download"

function Get-ExpectedChecksum {
    param([string]$Base, [string]$Asset)

    $tmp = Join-Path $env:TEMP ("komari-checksum-" + [guid]::NewGuid().ToString("N"))
    try {
        # 1) <asset>.sha256
        try {
            Invoke-WebRequest -Uri "$Base/$Asset.sha256" -OutFile $tmp -UseBasicParsing -ErrorAction Stop
            $lines = @(Get-Content -Path $tmp -ErrorAction Stop | Where-Object { $_.Trim() -ne "" })
            if ($lines.Count -eq 1) {
                $parts = $lines[0].Trim() -split '\s+'
                if ($parts[0] -match '^[0-9a-fA-F]{64}$') {
                    if ($parts.Count -eq 1 -or $parts[1].TrimStart('*') -eq $Asset) {
                        return $parts[0].ToLower()
                    }
                }
            }
        }
        catch { }

        # 2) SHA256SUMS, matched by exact file name
        try {
            Invoke-WebRequest -Uri "$Base/SHA256SUMS" -OutFile $tmp -UseBasicParsing -ErrorAction Stop
            $found = $null
            foreach ($entry in (Get-Content -Path $tmp -ErrorAction Stop)) {
                $trimmed = $entry.Trim()
                if ($trimmed -eq "") { continue }
                $parts = $trimmed -split '\s+'
                if ($parts.Count -lt 2) { return $null }
                if ($parts[0] -notmatch '^[0-9a-fA-F]{64}$') { return $null }
                if ($parts[1].TrimStart('*') -ne $Asset) { continue }
                $candidate = $parts[0].ToLower()
                if ($found -and $found -ne $candidate) { return $null }
                $found = $candidate
            }
            if ($found) { return $found }
        }
        catch { }

        return $null
    }
    finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

$ExpectedChecksum = Get-ExpectedChecksum -Base $ChecksumBaseUrl -Asset $BinaryName
if (-not $ExpectedChecksum) {
    Log-Error "No usable checksum for $BinaryName in $ChecksumBaseUrl"
    Log-Error "Refusing to install an unverified binary; an existing installation is unchanged"
    exit 1
}

try {
    Remove-Item $DownloadTemp -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $DownloadTemp -UseBasicParsing
    if (-not (Test-Path $DownloadTemp)) { throw "the download produced no file" }
}
catch {
    Log-Error "Download failed: $_"
    Remove-Item $DownloadTemp -Force -ErrorAction SilentlyContinue
    exit 1
}

$ActualChecksum = (Get-FileHash -Path $DownloadTemp -Algorithm SHA256).Hash.ToLower()
if ($ActualChecksum -ne $ExpectedChecksum) {
    Log-Error "Checksum mismatch for ${BinaryName}: expected $ExpectedChecksum, got $ActualChecksum"
    Remove-Item $DownloadTemp -Force -ErrorAction SilentlyContinue
    Log-Error "Nothing was installed: an existing agent binary and its service are unchanged"
    exit 1
}
Log-Success "Checksum verified (SHA256 $ActualChecksum)"

# Only now, with a verified binary in hand, is the previous installation torn
# down: a checksum failure above leaves the running agent and its service intact.
Uninstall-Previous

Move-Item -Path $DownloadTemp -Destination $AgentPath -Force
Log-Success "Downloaded and saved to $AgentPath"

# Register and start service
Log-Step "Configuring Windows service with nssm..."

# Apply the remote control decision to the service arguments. The flag name
# falls back to the historical spelling when the installed binary does not know
# the newer alias yet.
$argsLine = $KomariArgs -join ' '
if ($RemoteControlDecision -eq "disabled" -and -not ($argsLine -match '--disable-web-ssh' -or $argsLine -match '--disable-remote-control')) {
    $flag = "--disable-web-ssh"
    $helpOutput = ""
    if (Test-Path $AgentPath) {
        $helpOut = Join-Path $env:TEMP "komari-agent-help-out.txt"
        $helpErr = Join-Path $env:TEMP "komari-agent-help-err.txt"
        try {
            $proc = Start-Process -FilePath $AgentPath -ArgumentList '--help' -NoNewWindow -PassThru -RedirectStandardOutput $helpOut -RedirectStandardError $helpErr
            if (-not $proc.WaitForExit(15000)) {
                try { $proc.Kill() } catch { }
            }
            $helpOutput = (Get-Content $helpOut -Raw -ErrorAction SilentlyContinue) + (Get-Content $helpErr -Raw -ErrorAction SilentlyContinue)
        }
        catch { }
        Remove-Item $helpOut, $helpErr -Force -ErrorAction SilentlyContinue
    }
    if ($helpOutput -match '--disable-remote-control') {
        $flag = "--disable-remote-control"
    }
    $KomariArgs += $flag
    Log-Config "Remote control: disabled via $flag ($RemoteControlSource)"
}
else {
    Log-Config "Remote control: $RemoteControlDecision ($RemoteControlSource)"
}

$argString = $KomariArgs -join ' '
# Ensure InstallDir and AgentPath are quoted if they contain spaces
$quotedAgentPath = "`"$AgentPath`""
nssm install $ServiceName $quotedAgentPath $argString
# Set display name and startup type using nssm
nssm set $ServiceName DisplayName "Komari Agent Service"
nssm set $ServiceName Start SERVICE_AUTO_START
nssm set $ServiceName AppExit Default Restart
nssm set $ServiceName AppRestartDelay 5000
# Start the service using nssm
nssm start $ServiceName
Log-Success "Service $ServiceName installed and started using nssm."

Log-Success "Komari Agent installation completed!"
Log-Config "Service name: $ServiceName"
Log-Config "Arguments: $argString"
