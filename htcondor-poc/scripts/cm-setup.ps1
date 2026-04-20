param(
    [string]$Bucket,
    [string]$Region    = "us-east-1",
    [string]$SsmPrefix = "/htcondor-poc"
)
$ErrorActionPreference = "Continue"
Set-ExecutionPolicy Bypass -Scope Process -Force

$LogFile   = "C:\HTCondorSetup.log"
$StageFile = "C:\SetupStage.txt"

# ── Helpers ──────────────────────────────────────────────────────────────────
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
        Log "SSM $name failed: $_" "WARN"
        return $null
    }
}

function Get-Stage { if (Test-Path $StageFile) { return [int](Get-Content $StageFile -Raw) }; return 0 }
function Set-Stage { param([int]$s); Set-Content $StageFile $s; Log "Stage -> $s" }

function Wait-ForPort {
    param([string]$host, [int]$port, [int]$maxMinutes = 30)
    Log "Waiting for $host`:$port (up to $maxMinutes min)..."
    $deadline = (Get-Date).AddMinutes($maxMinutes)
    while ((Get-Date) -lt $deadline) {
        try {
            $t = New-Object System.Net.Sockets.TcpClient
            $ar = $t.BeginConnect($host, $port, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne(5000, $false)) {
                $t.EndConnect($ar); $t.Close()
                Log "$host`:$port is reachable."
                return $true
            }
            $t.Close()
        } catch { }
        Log "  still waiting..."
        Start-Sleep 30
    }
    Log "$host`:$port not reachable after $maxMinutes min." "ERROR"
    return $false
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
    param([string]$msiPath, [string]$condorHost, [string]$isNewPool)
    Log "Installing HTCondor from $msiPath ..."
    $logPath = "C:\condor-install.log"
    $proc = Start-Process msiexec -ArgumentList @(
        "/i", $msiPath, "/quiet", "/norestart",
        "CONDORHOST=$condorHost", "NEWPOOL=$isNewPool", "RUNJOBS=ALWAYS",
        "TARGETDIR=C:\condor\",
        "/l*v", $logPath
    ) -Wait -PassThru
    Log "MSI exit code: $($proc.ExitCode)"
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + $env:PATH
    if ($proc.ExitCode -notin @(0,3010)) {
        Log "MSI failed. See $logPath" "ERROR"
        return $false
    }
    return $true
}

# ── Main ─────────────────────────────────────────────────────────────────────
$stage = Get-Stage
Log "=== CM setup starting at stage $stage ==="

switch ($stage) {

    # ── Stage 0: rename + set DNS + reboot ──────────────────────────────────
    0 {
        Log "Stage 0: Rename to 'mgr', set DNS to DC"

        $dcIp = Get-SsmParam "dc-ip"
        if (-not $dcIp) { $dcIp = "10.0.1.10" }

        $nic = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback' } | Select-Object -First 1
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses @($dcIp, "169.254.169.253")
        Log "DNS set to $dcIp, 169.254.169.253"

        if ($env:COMPUTERNAME -ne "MGR") {
            Rename-Computer -NewName "MGR" -Force
            Set-Stage 1
            Start-Sleep 3; Restart-Computer -Force; Start-Sleep 60
        } else {
            Set-Stage 1
        }
    }

    # ── Stage 1: wait for DC, join domain, reboot ────────────────────────────
    1 {
        Log "Stage 1: Join domain"

        $dcIp    = Get-SsmParam "dc-ip"
        $domain  = Get-SsmParam "domain-name"
        $adminPw = Get-SsmParam "admin-password" -Secure
        if (-not $dcIp)   { $dcIp   = "10.0.1.10"   }
        if (-not $domain) { $domain = "fort.wow.dev" }

        $nic = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback' } | Select-Object -First 1
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses @($dcIp, "169.254.169.253")

        if (-not (Wait-ForPort $dcIp 389 40)) {
            Log "DC not ready after 40 min — will retry on next scheduled task run" "ERROR"
            exit 1
        }

        $cred = New-Object System.Management.Automation.PSCredential(
            "Administrator@$domain",
            (ConvertTo-SecureString $adminPw -AsPlainText -Force)
        )
        Log "Joining domain $domain ..."
        Add-Computer -DomainName $domain -Credential $cred -OUPath "OU=Computers,OU=HTCondorPoc,DC=fort,DC=wow,DC=dev" -Force -ErrorAction SilentlyContinue
        if ($?) {
            Log "Domain join succeeded."
        } else {
            Add-Computer -DomainName $domain -Credential $cred -Force
        }

        Set-Stage 2
        Start-Sleep 3; Restart-Computer -Force; Start-Sleep 60
    }

    # ── Stage 2: install HTCondor, configure as CM+CREDD, create SMB share ──
    2 {
        Log "Stage 2: Install and configure HTCondor (CM + CREDD) + create SMB share"

        $bucket = Get-SsmParam "s3-bucket"
        $msiKey = Get-SsmParam "htcondor-msi-key"
        $poolPw = Get-SsmParam "htcondor-pool-password" -Secure
        $domain = Get-SsmParam "domain-name"
        if (-not $bucket) { $bucket = $Bucket }
        if (-not $msiKey) { $msiKey = "installers/condor-23.4.0-Windows-x64.msi" }
        if (-not $domain) { $domain = "fort.wow.dev" }

        # Create SMB share used by ws-0/compute-0 as S:
        Log "Creating SMB share C:\HTCondorShare -> \\mgr.$domain\share"
        New-Item -ItemType Directory -Path "C:\HTCondorShare" -Force | Out-Null
        $acl = Get-Acl "C:\HTCondorShare"
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "Everyone", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.SetAccessRule($rule)
        Set-Acl "C:\HTCondorShare" $acl
        if (-not (Get-SmbShare -Name "share" -ErrorAction SilentlyContinue)) {
            New-SmbShare -Name "share" -Path "C:\HTCondorShare" -FullAccess "Everyone"
            Log "SMB share 'share' created."
        } else {
            Log "SMB share 'share' already exists."
        }

        # Download HTCondor MSI from S3
        $msiLocal = "C:\condor-install.msi"
        $ok = $false
        for ($i = 1; $i -le 10; $i++) {
            try {
                Get-S3File $bucket $msiKey $msiLocal
                if (Test-Path $msiLocal) { $ok = $true; break }
            } catch { Log "MSI download attempt $i failed: $_" "WARN" }
            Log "MSI not yet in S3 (attempt $i/10) — waiting 60s"
            Start-Sleep 60
        }
        if (-not $ok) { Log "HTCondor MSI not found in S3 after 10 attempts" "ERROR"; exit 1 }

        if (-not (Install-HTCondor $msiLocal "mgr.$domain" "N")) { exit 1 }
        Start-Sleep 15

        # Download HTCondor config files
        $configDir = "C:\ProgramData\HTCondor\config.d"
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        Log "Downloading HTCondor config files from S3..."
        Get-S3Folder $bucket "htcondor/" $configDir

        Copy-Item "$configDir\01-cm.conf" "$configDir\01-role.conf" -Force

        # Restart HTCondor to pick up config
        Log "Restarting HTCondor service..."
        Stop-Service condor -Force -ErrorAction SilentlyContinue; Start-Sleep 5
        Start-Service condor; Start-Sleep 15

        # Store pool password in credd
        Log "Storing HTCondor pool password..."
        & condor_store_cred add -c -p $poolPw 2>&1 | ForEach-Object { Log $_ }

        Log "Running condor_reconfig..."
        & condor_reconfig 2>&1 | ForEach-Object { Log $_ }
        Start-Sleep 10

        Log "Daemon list:"
        & condor_status -any 2>&1 | ForEach-Object { Log $_ }

        Set-Stage 99
        Unregister-ScheduledTask -TaskName "HTCondorSetup" -Confirm:$false -ErrorAction SilentlyContinue
        "CM setup complete $(Get-Date)" | Set-Content "C:\SetupComplete.txt"
        Log "=== CM setup COMPLETE ==="
    }

    default { Log "Stage ${stage}: nothing to do." }
}
