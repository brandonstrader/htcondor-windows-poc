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
    $a = @("ssm","get-parameter","--name","$SsmPrefix/$name","--region",$Region,"--query","Parameter.Value","--output","text")
    if ($Secure) { $a += "--with-decryption" }
    $v = & aws @a 2>&1
    if ($LASTEXITCODE -ne 0) { Log "SSM $name`: $v" "WARN"; return $null }
    return ($v | Out-String).Trim()
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

function Install-HTCondor {
    param([string]$msiPath, [string]$condorHost)
    Log "Installing HTCondor..."
    $proc = Start-Process msiexec -ArgumentList @(
        "/i", $msiPath, "/quiet", "/norestart",
        "CONDORHOST=$condorHost", "NEWPOOL=N", "RUNJOBS=NEVER",
        "/l*v", "C:\condor-install.log"
    ) -Wait -PassThru
    Log "MSI exit: $($proc.ExitCode)"
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
        $dcIp    = Get-SsmParam "dc-ip";             if (-not $dcIp)    { $dcIp    = "10.0.1.10" }
        $domain  = Get-SsmParam "domain-name";       if (-not $domain)  { $domain  = "fort.wow.dev" }
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

        $bucket     = Get-SsmParam "s3-bucket";                  if (-not $bucket)     { $bucket     = $Bucket }
        $msiKey     = Get-SsmParam "htcondor-msi-key";           if (-not $msiKey)     { $msiKey     = "installers/condor-23.4.0-Windows-x64.msi" }
        $domain     = Get-SsmParam "domain-name";                if (-not $domain)     { $domain     = "fort.wow.dev" }
        $poolPw     = Get-SsmParam "htcondor-pool-password" -Secure
        $brandonPw  = Get-SsmParam "brandon-password" -Secure
        $fsxDns     = $null

        # Wait for FSx DNS to appear in SSM (set by Terraform after FSx creation)
        Log "Waiting for FSx DNS in SSM Parameter Store..."
        for ($i = 1; $i -le 30; $i++) {
            $fsxDns = Get-SsmParam "fsx-dns"
            if ($fsxDns -and $fsxDns -notmatch "None") { Log "FSx DNS: $fsxDns"; break }
            Log "  FSx not ready yet (attempt $i/30)..."
            Start-Sleep 60
        }

        $msiLocal = "C:\condor-install.msi"
        $ok = $false
        for ($i = 1; $i -le 10; $i++) {
            aws s3 cp "s3://$bucket/$msiKey" $msiLocal --region $Region 2>&1 | ForEach-Object { Log $_ }
            if (Test-Path $msiLocal) { $ok = $true; break }
            Log "MSI not in S3 yet (attempt $i/10)..."; Start-Sleep 60
        }
        if (-not $ok) { Log "MSI not found" "ERROR"; exit 1 }

        if (-not (Install-HTCondor $msiLocal "mgr.$domain")) { exit 1 }
        Start-Sleep 15

        # Place config files
        $configDir = "C:\ProgramData\HTCondor\config.d"
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        aws s3 cp "s3://$bucket/htcondor/" $configDir --recursive --region $Region 2>&1 | ForEach-Object { Log $_ }
        Copy-Item "$configDir\03-submit.conf" "$configDir\01-role.conf" -Force

        # Store FSx DNS for the test job wrapper script
        $htcDir = "C:\HTCondorConfig"
        New-Item -ItemType Directory $htcDir -Force | Out-Null
        if ($fsxDns) { $fsxDns | Set-Content "$htcDir\fsx-dns.txt" }

        # Download test job files from S3
        aws s3 cp "s3://$bucket/jobs/" $htcDir --recursive --region $Region 2>&1 | ForEach-Object { Log $_ }

        # Restart HTCondor
        Stop-Service condor -Force -ErrorAction SilentlyContinue; Start-Sleep 5
        Start-Service condor; Start-Sleep 15

        # Store pool password
        Log "Storing pool password..."
        & condor_store_cred add -c -p $poolPw 2>&1 | ForEach-Object { Log $_ }

        # Store brandon's user password so run_as_owner works
        # -u flag lets Administrator store credentials for another domain user
        Log "Storing brandon's user password in credd..."
        & condor_store_cred add -u "brandon@$domain" -p $brandonPw 2>&1 | ForEach-Object { Log $_ }

        & condor_reconfig 2>&1 | ForEach-Object { Log $_ }
        Start-Sleep 10

        Log "Daemon status:"
        & condor_status -any 2>&1 | ForEach-Object { Log $_ }

        Set-Stage 99
        schtasks /delete /tn "HTCondorSetup" /f 2>$null
        "Submit setup complete $(Get-Date)" | Set-Content "C:\SetupComplete.txt"
        Log "=== Submit (ws-0) setup COMPLETE ==="
    }

    default { Log "Stage $stage: nothing to do." }
}
