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
        Log "SSM read failed for $name`: $_" "WARN"
        return $null
    }
}

function Get-Stage { if (Test-Path $StageFile) { return [int](Get-Content $StageFile -Raw) }; return 0 }
function Set-Stage { param([int]$s); Set-Content $StageFile $s; Log "Stage -> $s" }

function Restart-AndContinue {
    Log "Rebooting to continue setup at next stage..."
    Start-Sleep 3
    Restart-Computer -Force
    Start-Sleep 60   # block until reboot takes effect
}

# ── Main ─────────────────────────────────────────────────────────────────────
$stage = Get-Stage
Log "=== DC setup starting at stage $stage ==="

switch ($stage) {

    # ── Stage 0: rename computer, reboot ────────────────────────────────────
    0 {
        Log "Stage 0: Rename computer to 'dc'"

        # Ensure we can reach S3 for future downloads (AmazonDNS)
        $nic = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback' } | Select-Object -First 1
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses "169.254.169.253"

        if ($env:COMPUTERNAME -ne "DC") {
            Rename-Computer -NewName "DC" -Force
            Set-Stage 1
            Restart-AndContinue
        } else {
            Log "Already named DC, skipping rename reboot"
            Set-Stage 1
        }
    }

    # ── Stage 1: Install AD DS role + create forest (auto-reboots) ──────────
    1 {
        Log "Stage 1: Install AD DS role and create forest"

        $domainName = Get-SsmParam "domain-name"
        $netbios    = Get-SsmParam "domain-netbios"
        $adminPw    = Get-SsmParam "admin-password" -Secure

        if (-not $domainName) { $domainName = "fort.wow.dev" }
        if (-not $netbios)    { $netbios    = "FORTWOW" }

        Log "Installing AD-Domain-Services role..."
        Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
        Log "AD DS role installed."

        # Set stage to 2 BEFORE calling Install-ADDSForest because
        # that cmdlet auto-reboots and we must already have the stage set.
        Set-Stage 2

        $safePw = ConvertTo-SecureString $adminPw -AsPlainText -Force

        Log "Promoting DC: domain=$domainName netbios=$netbios"
        Import-Module ADDSDeployment
        Install-ADDSForest `
            -DomainName              $domainName `
            -DomainNetbiosName       $netbios `
            -ForestMode              "WinThreshold" `
            -DomainMode              "WinThreshold" `
            -SafeModeAdministratorPassword $safePw `
            -InstallDns              `
            -NoRebootOnCompletion:$false `
            -Force

        # Code below only runs if -NoRebootOnCompletion:$true; left for safety
        Restart-AndContinue
    }

    # ── Stage 2: Post-forest config — users, OUs, DNS forwarder ─────────────
    2 {
        Log "Stage 2: Post-forest AD configuration"
        Import-Module ActiveDirectory

        $adminPw    = Get-SsmParam "admin-password" -Secure
        $brandonPw  = Get-SsmParam "brandon-password" -Secure
        $domainName = Get-SsmParam "domain-name"
        if (-not $domainName) { $domainName = "fort.wow.dev" }

        # Set domain Administrator password to match SSM (used by other nodes for domain join)
        Log "Setting Administrator password..."
        Set-ADAccountPassword -Identity "Administrator" -NewPassword (ConvertTo-SecureString $adminPw -AsPlainText -Force) -Reset

        $dcParts = ($domainName -split '\.') | ForEach-Object { "DC=$_" }
        $dcPath  = $dcParts -join ','   # e.g. DC=fort,DC=wow,DC=dev

        # Wait briefly for AD services to fully initialise after forest reboot
        Log "Waiting 60s for AD services to stabilise..."
        Start-Sleep 60

        # Create OU structure
        Log "Creating OUs..."
        try { New-ADOrganizationalUnit -Name "HTCondorPoc" -Path $dcPath -ProtectedFromAccidentalDeletion $false } catch { Log "OU HTCondorPoc: $_" "WARN" }
        try { New-ADOrganizationalUnit -Name "Users"      -Path "OU=HTCondorPoc,$dcPath" -ProtectedFromAccidentalDeletion $false } catch { Log "OU Users: $_" "WARN" }
        try { New-ADOrganizationalUnit -Name "Computers"  -Path "OU=HTCondorPoc,$dcPath" -ProtectedFromAccidentalDeletion $false } catch { Log "OU Computers: $_" "WARN" }

        # Create test user 'brandon' — regular domain user, NOT admin.
        # run_as_owner impersonation should work for any domain user.
        Log "Creating domain user 'brandon'..."
        $secPw = ConvertTo-SecureString $brandonPw -AsPlainText -Force
        try {
            New-ADUser `
                -Name              "brandon" `
                -SamAccountName    "brandon" `
                -UserPrincipalName "brandon@$domainName" `
                -Path              "OU=Users,OU=HTCondorPoc,$dcPath" `
                -AccountPassword   $secPw `
                -Enabled           $true `
                -PasswordNeverExpires $true
            Log "User 'brandon' created."
        } catch { Log "Create brandon: $_" "WARN" }

        # Configure DNS conditional forwarder so instances can resolve
        # public names (e.g. AWS service endpoints) via AmazonProvidedDNS.
        Log "Configuring DNS forwarder -> 169.254.169.253"
        try {
            Add-DnsServerForwarder -IPAddress "169.254.169.253" -PassThru
        } catch { Log "DNS forwarder: $_" "WARN" }

        # Allow dynamic DNS updates from domain-joined machines
        Set-DnsServerPrimaryZone -Name $domainName -DynamicUpdate "Secure" -ErrorAction SilentlyContinue

        Set-Stage 99
        Unregister-ScheduledTask -TaskName "HTCondorSetup" -Confirm:$false -ErrorAction SilentlyContinue
        "DC setup complete $(Get-Date)" | Set-Content "C:\SetupComplete.txt"
        Log "=== DC setup COMPLETE ==="
    }

    default {
        Log "Stage ${stage}: nothing to do (setup already complete)."
    }
}
