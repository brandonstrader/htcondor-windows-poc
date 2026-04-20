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

    # ── Stage 2: done ────────────────────────────────────────────────────────
    # At v2 the CM is fully domain-joined and idle. HTCondor install + CM/CREDD
    # configuration come in at v3.
    2 {
        Log "Stage 2: domain-join complete; CM is idle at v2 (no HTCondor yet)."
        Set-Stage 99
        Unregister-ScheduledTask -TaskName "HTCondorSetup" -Confirm:$false -ErrorAction SilentlyContinue
        "CM v2 setup complete $(Get-Date)" | Set-Content "C:\SetupComplete.txt"
        Log "=== CM setup COMPLETE (v2) ==="
    }

    default {
        Log "Stage ${stage}: nothing to do."
    }
}
