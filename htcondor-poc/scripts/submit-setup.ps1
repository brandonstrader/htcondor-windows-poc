param(
    [string]$Bucket,
    [string]$Region    = "us-east-1",
    [string]$SsmPrefix = "/htcondor-poc"
)
$ErrorActionPreference = "Continue"
Set-ExecutionPolicy Bypass -Scope Process -Force

$LogFile   = "C:\HTCondorSetup.log"
$StageFile = "C:\SetupStage.txt"

function Log {
    param([string]$m, [string]$lvl = "INFO")
    $line = "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') [$lvl] $m"
    $line | Tee-Object $LogFile -Append
}

function Get-SsmParam {
    param([string]$name, [switch]$Secure)
    try {
        Import-Module AWSPowerShell -ErrorAction Stop
        $p = Get-SSMParameter -Name "$SsmPrefix/$name" -Region $Region -WithDecryption:($Secure.IsPresent) -ErrorAction Stop
        return $p.Value
    } catch {
        Log "SSM $name`: $_" "WARN"
        return $null
    }
}

function Get-Stage { if (Test-Path $StageFile) { return [int](Get-Content $StageFile -Raw) }; return 0 }
function Set-Stage { param([int]$s); Set-Content $StageFile $s; Log "Stage -> $s" }

function Wait-ForPort {
    param([string]$h, [int]$p, [int]$maxMin = 40)
    Log "Waiting for $h`:$p ..."
    $d = (Get-Date).AddMinutes($maxMin)
    while ((Get-Date) -lt $d) {
        try {
            $t = New-Object System.Net.Sockets.TcpClient
            $ar = $t.BeginConnect($h, $p, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne(5000,$false)) { $t.EndConnect($ar); $t.Close(); Log "$h`:$p ready."; return $true }
            $t.Close()
        } catch { }
        Start-Sleep 30
    }
    Log "$h`:$p not reachable." "ERROR"; return $false
}

function Get-S3File {
    param([string]$BucketName, [string]$Key, [string]$LocalPath)
    Import-Module AWSPowerShell -ErrorAction Stop
    Read-S3Object -BucketName $BucketName -Key $Key -File $LocalPath -Region $Region -ErrorAction Stop | Out-Null
    Log "Downloaded s3://$BucketName/$Key -> $LocalPath"
}

function Get-S3Folder {
    param([string]$BucketName, [string]$KeyPrefix, [string]$LocalDir)
    Import-Module AWSPowerShell -ErrorAction Stop
    $objects = Get-S3Object -BucketName $BucketName -KeyPrefix $KeyPrefix -Region $Region
    foreach ($obj in $objects) {
        if ($obj.Key -match '/$') { continue }
        $fileName = Split-Path $obj.Key -Leaf
        $dest = Join-Path $LocalDir $fileName
        Read-S3Object -BucketName $BucketName -Key $obj.Key -File $dest -Region $Region | Out-Null
        Log "Downloaded: $($obj.Key)"
    }
}

function Install-HTCondor {
    param([string]$msiPath, [string]$condorHost)
    Log "Installing HTCondor..."
    $proc = Start-Process msiexec -ArgumentList @(
        "/i", $msiPath, "/quiet", "/norestart",
        "CONDORHOST=$condorHost", "NEWPOOL=N", "RUNJOBS=NEVER",
        "TARGETDIR=C:\condor\",
        "/l*v", "C:\condor-install.log"
    ) -Wait -PassThru
    Log "MSI exit: $($proc.ExitCode)"
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + $env:PATH
    return ($proc.ExitCode -in @(0,3010))
}

# ── Main ─────────────────────────────────────────────────────────────────────
$stage = Get-Stage
Log "=== Submit (ws-0) setup at stage $stage ==="

switch ($stage) {

    0 {
        Log "Stage 0: Rename to ws-0, set DNS"
        $dcIp = Get-SsmParam "dc-ip"; if (-not $dcIp) { $dcIp = "10.0.1.10" }
        $nic = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback' } | Select-Object -First 1
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses @($dcIp, "169.254.169.253")

        if ($env:COMPUTERNAME -ne "WS-0") { Rename-Computer -NewName "WS-0" -Force }
        Set-Stage 1
        Start-Sleep 3; Restart-Computer -Force; Start-Sleep 60
    }

    1 {
        Log "Stage 1: Join domain"
        $dcIp    = Get-SsmParam "dc-ip";       if (-not $dcIp)    { $dcIp    = "10.0.1.10" }
        $domain  = Get-SsmParam "domain-name"; if (-not $domain)  { $domain  = "fort.wow.dev" }
        $adminPw = Get-SsmParam "admin-password" -Secure

        $nic = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback' } | Select-Object -First 1
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses @($dcIp, "169.254.169.253")

        if (-not (Wait-ForPort $dcIp 389 40)) { exit 1 }

        $cred = New-Object System.Management.Automation.PSCredential(
            "Administrator@$domain",
            (ConvertTo-SecureString $adminPw -AsPlainText -Force)
        )
        Log "Joining $domain..."
        Add-Computer -DomainName $domain -Credential $cred -Force -ErrorAction SilentlyContinue
        Set-Stage 2
        Start-Sleep 3; Restart-Computer -Force; Start-Sleep 60
    }

    2 {
        Log "Stage 2: Install HTCondor (submit/schedd role), store credentials"

        $bucket    = Get-SsmParam "s3-bucket";               if (-not $bucket)    { $bucket    = $Bucket }
        $msiKey    = Get-SsmParam "htcondor-msi-key";        if (-not $msiKey)    { $msiKey    = "installers/condor-23.4.0-Windows-x64.msi" }
        $domain    = Get-SsmParam "domain-name";             if (-not $domain)    { $domain    = "fort.wow.dev" }
        $poolPw    = Get-SsmParam "htcondor-pool-password" -Secure
        $brandonPw = Get-SsmParam "brandon-password" -Secure
        $shareHost = Get-SsmParam "share-host";              if (-not $shareHost) { $shareHost = "mgr.$domain" }

        $msiLocal = "C:\condor-install.msi"
        $ok = $false
        for ($i = 1; $i -le 10; $i++) {
            try {
                Get-S3File $bucket $msiKey $msiLocal
                if (Test-Path $msiLocal) { $ok = $true; break }
            } catch { Log "MSI download attempt $i failed: $_" "WARN" }
            Log "MSI not in S3 yet (attempt $i/10)..."; Start-Sleep 60
        }
        if (-not $ok) { Log "MSI not found" "ERROR"; exit 1 }

        if (-not (Install-HTCondor $msiLocal "mgr.$domain")) { exit 1 }
        Start-Sleep 15

        # Place config files
        $configDir = "C:\ProgramData\HTCondor\config.d"
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        Get-S3Folder $bucket "htcondor/" $configDir
        Copy-Item "$configDir\03-submit.conf" "$configDir\01-role.conf" -Force

        # Write share host for the test job batch script
        $htcDir = "C:\HTCondorConfig"
        New-Item -ItemType Directory $htcDir -Force | Out-Null
        $shareHost | Set-Content "$htcDir\share-host.txt"
        Log "Share host written: $shareHost"

        # Download test job files from S3
        Get-S3Folder $bucket "jobs/" $htcDir

        # Restart HTCondor
        Stop-Service condor -Force -ErrorAction SilentlyContinue; Start-Sleep 5
        Start-Service condor; Start-Sleep 15

        # Store pool password
        Log "Storing pool password..."
        & condor_store_cred add -c -p $poolPw 2>&1 | ForEach-Object { Log $_ }

        # Store brandon's user password so run_as_owner works
        Log "Storing brandon's user password in credd..."
        & condor_store_cred add -u "brandon@$domain" -p $brandonPw 2>&1 | ForEach-Object { Log $_ }

        & condor_reconfig 2>&1 | ForEach-Object { Log $_ }
        Start-Sleep 10

        Log "Daemon status:"
        & condor_status -any 2>&1 | ForEach-Object { Log $_ }

        Set-Stage 99
        Unregister-ScheduledTask -TaskName "HTCondorSetup" -Confirm:$false -ErrorAction SilentlyContinue
        "Submit setup complete $(Get-Date)" | Set-Content "C:\SetupComplete.txt"
        Log "=== Submit (ws-0) setup COMPLETE ==="
    }

    default { Log "Stage ${stage}: nothing to do." }
}
