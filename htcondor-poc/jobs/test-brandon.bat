@echo off
:: test-brandon.bat — runs on compute-0 as the impersonated user 'brandon'
::
:: This file is placed on compute-0 by the execute-setup.ps1 script
:: (downloaded from S3 alongside the submit file).
:: It verifies three things:
::   1. whoami shows FORTWOW\brandon (not SYSTEM or Administrator)
::   2. hostname shows compute-0 (the execute node)
::   3. The SMB share on the CM is accessible under brandon's credentials

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

echo --- Share Access ---
:: Read share host from the file written during execute-node setup
set SHARE_FILE=C:\HTCondorConfig\share-host.txt
if not exist %SHARE_FILE% (
    echo ERROR: %SHARE_FILE% not found. Share host unknown.
    goto :eof
)
set /p SHARE_HOST=<%SHARE_FILE%
echo Share host: %SHARE_HOST%
echo.

:: Map the share under brandon's AD credentials (automatic via Kerberos)
net use S: \\%SHARE_HOST%\share 2>nul
if %errorlevel% neq 0 (
    echo WARNING: 'net use' returned %errorlevel% — share may already be mapped.
)

echo --- Share Root Contents ---
dir S:\ 2>&1
echo.

echo --- Writing proof file to share ---
echo Written by %USERNAME% on %COMPUTERNAME% at %DATE% %TIME% > S:\brandon-test.txt
echo Proof file written to S:\brandon-test.txt
echo.

net use S: /delete /y 2>nul

echo ============================================================
echo  Test COMPLETE. Check S:\brandon-test.txt to confirm write.
echo ============================================================
endlocal
