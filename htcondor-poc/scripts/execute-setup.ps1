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
        "CONDORHOST=$condorHost", "NEWPOOL=N", "RUNJOBS=ALWAYS",
        "TARGETDIR=C:\condor\",
        "/l*v", "C:\condor-install.log"
    ) -Wait -PassThru
    Log "MSI exit: $($proc.ExitCode)"
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + $env:PATH
    return ($proc.ExitCode -in @(0,3010))
}

function Get-UserSid {
    param([string]$DomainNetbios, [string]$SamAccount)
    try {
        $acct = New-Object System.Security.Principal.NTAccount($DomainNetbios, $SamAccount)
        return $acct.Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch {
        Log "Get-UserSid ${DomainNetbios}\${SamAccount} failed: $_" "WARN"
        return $null
    }
}

function Grant-SeBatchLogonRight {
    # Adds the given SID to SeBatchLogonRight so that user can run scheduled tasks.
    # This is required for the self-store-as-user credential pattern below.
    param([string]$Sid)
    $inf = "$env:TEMP\sec.inf"
    $sdb = "$env:TEMP\sec.sdb"
    Remove-Item $inf,$sdb -Force -ErrorAction SilentlyContinue
    & secedit /export /cfg $inf /areas USER_RIGHTS | Out-Null
    $lines = Get-Content $inf
    $hit   = $false
    $out   = foreach ($line in $lines) {
        if ($line -match '^SeBatchLogonRight\s*=') {
            $hit = $true
            if ($line -notmatch [regex]::Escape($Sid)) { "$line,*$Sid" } else { $line }
        } else { $line }
    }
    if (-not $hit) { $out += "SeBatchLogonRight = *$Sid" }
    $out | Set-Content $inf
    & secedit /import /cfg $inf /db $sdb | Out-Null
    & secedit /configure /db $sdb /areas USER_RIGHTS | Out-Null
    Remove-Item $inf,$sdb -Force -ErrorAction SilentlyContinue
    Log "SeBatchLogonRight granted to $Sid"
}

function Grant-CondorReadToUsers {
    # Without this, a scheduled task running as a regular domain user cannot read
    # C:\condor\condor_config or the config.d, and condor_store_cred fails with
    # "Couldn't read config file".
    & icacls 'C:\condor\condor_config' /grant 'BUILTIN\Users:(R)' 2>&1 | Out-Null
    & icacls 'C:\ProgramData\HTCondor\config.d' /grant 'BUILTIN\Users:(R)' /T 2>&1 | Out-Null
    Log "Granted BUILTIN\Users:(R) on condor_config + config.d"
}

function Store-CredAsUser {
    # HTCondor's store_cred_handler enforces that the authenticated user base-name
    # equals the target user base-name (admin rights do NOT bypass). So we must
    # store brandon's credential while AUTHENTICATED AS brandon, which SSM/SYSTEM
    # cannot do directly. Workaround: register a short-lived scheduled task that
    # runs as the target user and invokes condor_store_cred. Poll for completion
    # via Get-ScheduledTaskInfo; result surfaces through a text file in Public.
    param(
        [string]$UserUpn,              # brandon@fort.wow.dev
        [string]$Password,             # cleartext — must not go through bash double-quotes
        [string[]]$TargetForms,        # @("brandon@FORTWOW","brandon@fort.wow.dev")
        [string]$CreddSinful           # full sinful string, see 04-localcredd.conf
    )
    $resultFile = 'C:\Users\Public\cred-store-result.txt'
    $scriptFile = 'C:\CredStoreAsUser.ps1'
    Remove-Item $resultFile -Force -ErrorAction SilentlyContinue

    # Password is embedded in the script (single-quoted to preserve `$` in passwords).
    # Script file is readable by BUILTIN\Users so the scheduled task can read it —
    # this is acceptable for a PoC but means the password is discoverable by any
    # domain user logged into this host. See DEPLOY.md "Security caveats".
    $pwLiteral = "'" + ($Password -replace "'", "''") + "'"
    $storeLines = ($TargetForms | ForEach-Object {
        "`"-- $_ --`" | Add-Content `$result; (& condor_store_cred add -u '$_' -p $pwLiteral 2>&1 | Out-String) | Add-Content `$result"
    }) -join "`r`n"

    $body = @"
`$ErrorActionPreference = 'Continue'
`$env:CONDOR_CONFIG       = 'C:\condor\condor_config'
`$env:PATH                = 'C:\condor\bin;' + `$env:PATH
`$env:_CONDOR_CREDD_HOST  = '$CreddSinful'
`$result = '$resultFile'
'run as ' + `$env:USERNAME + ' @ ' + (Get-Date) | Set-Content `$result
$storeLines
"@
    $body | Set-Content $scriptFile -Encoding ASCII
    & icacls $scriptFile /grant 'BUILTIN\Users:(R)' | Out-Null

    $taskName = "HTCondorCredStore"
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    $action  = New-ScheduledTaskAction  -Execute 'powershell.exe' `
               -Argument "-NoProfile -ExecutionPolicy Bypass -File $scriptFile"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(15)
    Register-ScheduledTask -TaskName $taskName `
        -Action $action -Trigger $trigger `
        -User $UserUpn -Password $Password -RunLevel Highest -Force | Out-Null
    Log "Scheduled cred-store task as $UserUpn (fires in 15s)"

    # Poll up to ~3 minutes
    $ok = $false
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep 3
        $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
        if ($info -and $info.LastRunTime -gt (Get-Date).AddMinutes(-5) -and $info.LastTaskResult -ne 267045) {
            $ok = $true; break
        }
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path $resultFile) { Get-Content $resultFile | ForEach-Object { Log $_ } }
    if (-not $ok) { Log "cred-store task did not complete cleanly" "WARN" }
}

# ── Main ─────────────────────────────────────────────────────────────────────
$stage = Get-Stage
Log "=== Execute (compute-0) setup at stage $stage ==="

switch ($stage) {

    0 {
        Log "Stage 0: Rename to compute-0, set DNS"
        $dcIp = Get-SsmParam "dc-ip"; if (-not $dcIp) { $dcIp = "10.0.1.10" }
        $nic = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback' } | Select-Object -First 1
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses @($dcIp, "169.254.169.253")

        if ($env:COMPUTERNAME -ne "COMPUTE-0") { Rename-Computer -NewName "COMPUTE-0" -Force }
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
        Log "Stage 2: Install HTCondor (execute/startd role), store pool password + brandon's cred"

        $bucket      = Get-SsmParam "s3-bucket";         if (-not $bucket)    { $bucket    = $Bucket }
        $msiKey      = Get-SsmParam "htcondor-msi-key";  if (-not $msiKey)    { $msiKey    = "installers/condor-23.4.0-Windows-x64.msi" }
        $domain      = Get-SsmParam "domain-name";       if (-not $domain)    { $domain    = "fort.wow.dev" }
        $netbios     = Get-SsmParam "domain-netbios";    if (-not $netbios)   { $netbios   = "FORTWOW" }
        $poolPw      = Get-SsmParam "htcondor-pool-password" -Secure
        $brandonPw   = Get-SsmParam "brandon-password" -Secure
        $shareHost   = Get-SsmParam "share-host";        if (-not $shareHost) { $shareHost = "mgr.$domain" }
        $mgrHostName = "mgr.$domain"

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
        Copy-Item "$configDir\02-execute.conf" "$configDir\01-role.conf" -Force

        # Write 04-localcredd.conf with the environment-specific CM CREDD sinful
        # string. HTCondor 23.4 on Windows does not auto-publish LocalCredd from
        # the collector CREDD ad, so run_as_owner jobs never match without this.
        $mgrIp = $null
        try {
            $mgrIp = (Resolve-DnsName $mgrHostName -Type A -ErrorAction Stop | Select-Object -First 1).IPAddress
        } catch { Log "Resolve-DnsName $mgrHostName failed: $_" "WARN" }
        if (-not $mgrIp) { $mgrIp = "10.0.1.11" }
        $aliasUpper = ($mgrHostName.Substring(0,1).ToUpper() + $mgrHostName.Substring(1))
        $sinful = "<${mgrIp}:9620?addrs=${mgrIp}-9620&alias=$aliasUpper>"
        @"
## 04-localcredd.conf — generated by execute-setup.ps1
## Environment-specific sinful string for the CM's CREDD. Published into the
## STARTD ad via STARTD_ATTRS in 02-execute.conf.
LocalCredd = "$sinful"
"@ | Set-Content "$configDir\04-localcredd.conf" -Encoding ASCII
        Log "Wrote 04-localcredd.conf with LocalCredd = $sinful"

        # Write share host (read by test-brandon.bat)
        $htcDir = "C:\HTCondorConfig"
        New-Item -ItemType Directory $htcDir -Force | Out-Null
        $shareHost | Set-Content "$htcDir\share-host.txt"
        Log "Share host written: $shareHost"

        # Download test job files
        Get-S3Folder $bucket "jobs/" $htcDir

        # Create HTCondor log directory
        New-Item -ItemType Directory "C:\HTCondorLogs" -Force | Out-Null

        # Restart HTCondor
        Stop-Service condor -Force -ErrorAction SilentlyContinue; Start-Sleep 5
        Start-Service condor; Start-Sleep 15

        # Store pool password (required for execute node to contact credd)
        Log "Storing pool password..."
        & condor_store_cred add -c -p $poolPw 2>&1 | ForEach-Object { Log $_ }

        # Grant access + SeBatchLogonRight to brandon so the self-store scheduled
        # task can run as brandon and read HTCondor's config.
        Grant-CondorReadToUsers
        $brandonSid = Get-UserSid $netbios 'brandon'
        if ($brandonSid) { Grant-SeBatchLogonRight $brandonSid }

        # Store brandon's credential on THIS node's local CREDD under both
        # NetBIOS and DNS forms. Starters on this node query the local CREDD
        # (CREDD_CACHE_LOCALLY=True) using whatever form the schedd sent, so
        # both must be present.
        $localSinful = "<127.0.0.1:9620?addrs=127.0.0.1-9620&alias=COMPUTE-0.$domain>"
        if ($brandonPw) {
            Store-CredAsUser -UserUpn "brandon@$domain" `
                             -Password $brandonPw `
                             -TargetForms @("brandon@$netbios","brandon@$domain") `
                             -CreddSinful $localSinful
        } else {
            Log "brandon-password SSM parameter not set — skipping local cred store" "WARN"
        }

        & condor_reconfig 2>&1 | ForEach-Object { Log $_ }
        Start-Sleep 10

        Log "Startd status:"
        & condor_status 2>&1 | ForEach-Object { Log $_ }

        Log "Checking LocalCredd advertisement..."
        & condor_status -f "%s\n" Name -f "LocalCredd: %s\n" LocalCredd 2>&1 | ForEach-Object { Log $_ }

        Set-Stage 99
        Unregister-ScheduledTask -TaskName "HTCondorSetup" -Confirm:$false -ErrorAction SilentlyContinue
        "Execute setup complete $(Get-Date)" | Set-Content "C:\SetupComplete.txt"
        Log "=== Execute (compute-0) setup COMPLETE ==="
    }

    default { Log "Stage ${stage}: nothing to do." }
}
