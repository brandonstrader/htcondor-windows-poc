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
    $a = @("ssm","get-parameter","--name","$SsmPrefix/$name","--region",$Region,"--query","Parameter.Value","--output","text")
    if ($Secure) { $a += "--with-decryption" }
    $v = & aws @a 2>&1
    if ($LASTEXITCODE -ne 0) { Log "SSM $name failed: $v" "WARN"; return $null }
    return ($v | Out-String).Trim()
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

function Install-HTCondor {
    param([string]$msiPath, [string]$condorHost, [string]$isNewPool)
    Log "Installing HTCondor from $msiPath ..."
    $logPath = "C:\condor-install.log"
    $args    = @(
        "/i", $msiPath,
        "/quiet", "/norestart",
        "CONDORHOST=$condorHost",
        "NEWPOOL=$isNewPool",
        "RUNJOBS=ALWAYS",
        "/l*v", $logPath
    )
    $proc = Start-Process msiexec -ArgumentList $args -Wait -PassThru
    Log "MSI exit code: $($proc.ExitCode)"
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

        $dcIp      = Get-SsmParam "dc-ip"
        $domain    = Get-SsmParam "domain-name"
        $adminPw   = Get-SsmParam "admin-password" -Secure
        if (-not $dcIp)   { $dcIp   = "10.0.1.10"      }
        if (-not $domain) { $domain = "fort.wow.dev"    }

        # Ensure DNS is set (might survive reboot already, but re-set to be safe)
        $nic = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback' } | Select-Object -First 1
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses @($dcIp, "169.254.169.253")

        # Wait for DC LDAP port (389)
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
        if ($LASTEXITCODE -eq 0 -or $?) {
            Log "Domain join succeeded."
        } else {
            # Try default Computers OU as fallback
            Add-Computer -DomainName $domain -Credential $cred -Force
        }

        Set-Stage 2
        Start-Sleep 3; Restart-Computer -Force; Start-Sleep 60
    }

    # ── Stage 2: install HTCondor, configure as CM+CREDD, store pool PW ─────
    2 {
        Log "Stage 2: Install and configure HTCondor (CM + CREDD)"

        $bucket   = Get-SsmParam "s3-bucket"
        $msiKey   = Get-SsmParam "htcondor-msi-key"
        $poolPw   = Get-SsmParam "htcondor-pool-password" -Secure
        $domain   = Get-SsmParam "domain-name"
        if (-not $bucket) { $bucket = $Bucket }
        if (-not $msiKey) { $msiKey = "installers/condor-23.4.0-Windows-x64.msi" }
        if (-not $domain) { $domain = "fort.wow.dev" }

        $msiLocal = "C:\condor-install.msi"

        # Download HTCondor MSI from S3
        Log "Downloading HTCondor MSI from s3://$bucket/$msiKey ..."
        $ok = $false
        for ($i = 1; $i -le 10; $i++) {
            aws s3 cp "s3://$bucket/$msiKey" $msiLocal --region $Region 2>&1 | ForEach-Object { Log $_ }
            if (Test-Path $msiLocal) { $ok = $true; break }
            Log "MSI not yet in S3 (attempt $i/10) — waiting 60s"
            Start-Sleep 60
        }
        if (-not $ok) { Log "HTCondor MSI not found in S3 after 10 attempts" "ERROR"; exit 1 }

        # Install — Y = this is the new pool, CM is itself
        if (-not (Install-HTCondor $msiLocal "mgr.$domain" "Y")) { exit 1 }

        # Brief pause for service registration
        Start-Sleep 15

        # Download HTCondor config files
        $configDir = "C:\ProgramData\HTCondor\config.d"
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        Log "Downloading HTCondor config files from S3..."
        aws s3 cp "s3://$bucket/htcondor/" $configDir --recursive --region $Region 2>&1 | ForEach-Object { Log $_ }

        # Copy role config
        Copy-Item "$configDir\01-cm.conf" "$configDir\01-role.conf" -Force

        # Restart HTCondor to pick up config
        Log "Restarting HTCondor service..."
        Stop-Service condor -Force -ErrorAction SilentlyContinue; Start-Sleep 5
        Start-Service condor; Start-Sleep 15

        # Store pool password in credd
        # condor_master must be running (service just started above)
        Log "Storing HTCondor pool password..."
        $poolPwFile = "C:\pool_pw_tmp.txt"
        $poolPw | Set-Content $poolPwFile -NoNewline

        # Try -p flag first; fall back to stdin pipe
        & condor_store_cred add -c -p $poolPw 2>&1 | ForEach-Object { Log $_ }
        Remove-Item $poolPwFile -Force -ErrorAction SilentlyContinue

        Log "Running condor_reconfig..."
        & condor_reconfig 2>&1 | ForEach-Object { Log $_ }
        Start-Sleep 10

        # Verify CREDD is listed
        Log "Daemon list:"
        & condor_status -any 2>&1 | ForEach-Object { Log $_ }

        Set-Stage 99
        schtasks /delete /tn "HTCondorSetup" /f 2>$null
        "CM setup complete $(Get-Date)" | Set-Content "C:\SetupComplete.txt"
        Log "=== CM setup COMPLETE ==="
    }

    default { Log "Stage $stage: nothing to do." }
}
