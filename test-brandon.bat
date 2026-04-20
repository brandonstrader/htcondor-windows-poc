@echo off
:: test-brandon.bat — runs on compute-0 as the impersonated user 'brandon'
::
:: This file is placed on compute-0 by the execute-setup.ps1 script
:: (downloaded from S3 alongside the submit file).
:: It verifies three things:
::   1. whoami shows FORTWOW\brandon (not SYSTEM or Administrator)
::   2. hostname shows compute-0 (the execute node)
::   3. The FSx share is accessible under brandon's credentials

setlocal

echo ============================================================
echo  HTCondor run_as_owner Test
echo  $(date /t) $(time /t)
echo ============================================================
echo.

echo --- Identity ---
whoami /all
echo.

echo --- Machine ---
hostname
echo.

echo --- FSx Share Access ---
:: Read FSx DNS from the file written during execute-node setup
set FSX_FILE=C:\HTCondorConfig\fsx-dns.txt
if not exist %FSX_FILE% (
    echo ERROR: %FSX_FILE% not found. FSx DNS unknown.
    goto :eof
)
set /p FSX_DNS=<%FSX_FILE%
echo FSx DNS: %FSX_DNS%
echo.

:: Map the share under brandon's AD credentials (automatic via Kerberos)
net use S: \\%FSX_DNS%\share 2>nul
if %errorlevel% neq 0 (
    echo WARNING: 'net use' returned %errorlevel% — share may already be mapped.
)

echo --- FSx Root Contents ---
dir S:\ 2>&1
echo.

echo --- Writing proof file to FSx ---
echo Written by %USERNAME% on %COMPUTERNAME% at %DATE% %TIME% > S:\brandon-test.txt
echo Proof file written to S:\brandon-test.txt
echo.

net use S: /delete /y 2>nul

echo ============================================================
echo  Test COMPLETE. Check S:\brandon-test.txt to confirm write.
echo ============================================================
endlocal
