@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem Remember the console codepage so the window is left as we found it.
for /f "tokens=2 delims=:" %%C in ('chcp') do set "OLD_CP=%%C"
set "OLD_CP=%OLD_CP: =%"
chcp 65001 >nul 2>&1

rem ============================================================================
rem  OpenDesign Go for DSH - Windows installer
rem  Version : 0.1.11
rem  Package : @jiqfu/dsh-opendesign-go
rem
rem  What this does
rem    1. Verifies the tarball's SHA-256 against the published release asset.
rem    2. Installs it into the DSH "web" profile via `dsh plugin add`.
rem    3. Tells you to restart `dsh web` - the plugin does NOT load before that.
rem
rem  Must run with the tarball AND this .bat in the same folder, or pass the
rem  tarball path as the first argument.
rem ============================================================================

set "TAG=v0.1.11"
set "PKG=@jiqfu/dsh-opendesign-go"
set "VERSION=0.1.11"
set "TARBALL_NAME=jiqfu-dsh-opendesign-go-0.1.11.tgz"

rem SHA-256 of the asset currently attached to the GitHub Release.
rem It is the CI-built tarball, not a hand-packed one: the two differ because
rem tar records file modes, so their hashes differ even with identical content.
rem Source of truth: https://api.github.com/repos/jiqfu/dsh-opendesign-go/releases/assets/669910693 -> digest
set "EXPECTED_SHA256=a77e65b8668d54ee803935e147a2d80f0e89410cf0d6e85ef262f1d2100cd185"
set "EXPECTED_SIZE=447471"

set "PROFILE=web"
set "EXITCODE=0"

echo ============================================================
echo  %PKG% %VERSION%  ^|  DSH profile: %PROFILE%
echo ============================================================
echo.

rem ---------------------------------------------------------------- locate tgz
if not "%~1"=="" (
  set "TGZ=%~f1"
) else (
  set "TGZ=%~dp0%TARBALL_NAME%"
)

if not exist "!TGZ!" (
  echo [FAIL] Tarball not found:
  echo        !TGZ!
  echo.
  echo        Put %TARBALL_NAME% next to this .bat,
  echo        or drag the .tgz onto the .bat to pass its path.
  goto :fail
)
echo [ok]   Tarball: !TGZ!

for %%F in ("!TGZ!") do set "ACTUAL_SIZE=%%~zF"

rem ------------------------------------------------------------- verify sha256
where certutil >nul 2>&1
if errorlevel 1 (
  echo [warn] certutil not available - skipping the SHA-256 check.
  echo        This is unusual on Windows; verify the file manually.
  goto :checksum_done
)

echo        computing SHA-256, this may take a few seconds...
set "HASH_FILE=%TEMP%\odg_hash_%RANDOM%%RANDOM%.txt"
certutil -hashfile "!TGZ!" SHA256 > "!HASH_FILE!" 2>&1
if errorlevel 1 (
  echo [warn] certutil could not hash the file - skipping the check.
  del /q "!HASH_FILE!" >nul 2>&1
  goto :checksum_done
)

rem certutil prints 3 lines: header / hash / trailing note. Line 2 is the hash.
set "ACTUAL_SHA256="
set "_n=0"
for /f "usebackq delims=" %%L in ("!HASH_FILE!") do (
  set /a _n+=1
  if !_n!==2 set "ACTUAL_SHA256=%%L"
)
del /q "!HASH_FILE!" >nul 2>&1

rem certutil 的第二行是哈希，可能带前导空格；清掉空格再比较
set "ACTUAL_SHA256=!ACTUAL_SHA256: =!"
set "EXPECTED_LOWER=!EXPECTED_SHA256: =!"

if /i "!ACTUAL_SHA256!"=="!EXPECTED_LOWER!" (
  echo [ok]   SHA-256 matches the published asset.
) else (
  echo [FAIL] SHA-256 mismatch - this tarball is NOT the published one.
  echo        expected: !EXPECTED_LOWER!
  echo        actual  : !ACTUAL_SHA256!
  if not "!ACTUAL_SIZE!"=="%EXPECTED_SIZE%" (
    echo        size expected %EXPECTED_SIZE% bytes, got !ACTUAL_SIZE! bytes
  )
  echo.
  echo        Re-download from:
  echo        https://github.com/jiqfu/dsh-opendesign-go/releases/download/%TAG%/%TARBALL_NAME%
  goto :fail
)
:checksum_done
echo.

rem ------------------------------------------------------------- check pnpm
rem `dsh plugin` forwards to pnpm inside the profile directory. Without pnpm the
rem command still exits 0 in some dsh versions - it only prints an error - so we
rem check up front instead of trusting the exit code.
where pnpm >nul 2>&1
if errorlevel 1 (
  echo [warn] pnpm was not found on PATH.
  echo        `dsh plugin add` forwards to pnpm and will fail without it.
  echo        Install it with:  npm install -g pnpm
  echo.
  set "PNPM_MISSING=1"
) else (
  for /f "delims=" %%V in ('pnpm -v 2^>nul') do set "PNPM_VERSION=%%V"
  echo [ok]   pnpm !PNPM_VERSION!
  echo.
)

rem ------------------------------------------------------------------ install
echo [..]   Running: npx -y @deepseek-ai/dsh plugin --profile %PROFILE% add "!TGZ!"
echo ------------------------------------------------------------
rem Redirect to a file rather than piping through Tee-Object: a pipeline makes
rem %errorlevel% report the last stage's status, not npx's, and PowerShell's
rem default encoding mangles non-ASCII output. Reading the file back keeps both
rem the real exit code and the raw bytes intact.
set "LOG_FILE=%TEMP%\odg_install_%RANDOM%%RANDOM%.log"
call npx -y @deepseek-ai/dsh plugin --profile %PROFILE% add "!TGZ!" > "!LOG_FILE!" 2>&1
set "EXITCODE=!errorlevel!"
type "!LOG_FILE!"
echo ------------------------------------------------------------
echo.

rem dsh has been observed to exit 0 while printing "plugin command failed".
rem Trust the output, not the exit code.
set "INSTALL_OK=0"
findstr /i /c:"plugin command failed" /c:"pnpm was not found" /c:"ERR_" /c:"installation rejected" "!LOG_FILE!" >nul 2>&1
if errorlevel 1 (
  if "!EXITCODE!"=="0" set "INSTALL_OK=1"
)

if "!INSTALL_OK!"=="1" (
  echo [ok]   Install reported success.
) else (
  echo [FAIL] Install did not report success. Raw output follows.
  echo ------------------------------------------------------------
  type "!LOG_FILE!"
  echo ------------------------------------------------------------
  echo exit code: !EXITCODE!
  echo full log : !LOG_FILE!
  if defined PNPM_MISSING (
    echo.
    echo Likely cause: pnpm is missing. Run  npm install -g pnpm  and retry.
  )
  goto :fail
)

rem ------------------------------------------------------------- verify bundle
echo [..]   Verifying the plugin was registered in the profile...
set "VERIFY_LOG=%TEMP%\odg_dump_%RANDOM%%RANDOM%.txt"
call npx -y @deepseek-ai/dsh --profile %PROFILE% --dump-config > "!VERIFY_LOG!" 2>&1

rem Built as variables so the "@" and "/" in the package name are passed to
rem findstr as a literal /c: argument rather than parsed as switches.
set "NEEDLE_PKG=%PKG%"
set "NEEDLE_LAYER=# == %PKG%"

findstr /i /c:"!NEEDLE_PKG!" "!VERIFY_LOG!" >nul 2>&1
if errorlevel 1 (
  echo [warn] The composed config does not mention %PKG%.
  echo        Install returned success but the bundle layer is missing.
  echo        Full dump: !VERIFY_LOG!
  echo        Re-run this script and send the output if the plugin still
  echo        does not appear after a restart.
) else (
  findstr /i /c:"!NEEDLE_LAYER!" "!VERIFY_LOG!" >nul 2>&1
  if errorlevel 1 (
    echo [warn] Package is a dependency but no "# == %PKG%" layer was found.
    echo        Check that its package.json declares dsh.bundle.patch.
    echo        Full dump: !VERIFY_LOG!
  ) else (
    echo [ok]   Bundle layer "# == %PKG%" is present in the composed config.
  )
)
del /q "!VERIFY_LOG!" >nul 2>&1
echo.

if exist "!LOG_FILE!" del /q "!LOG_FILE!" >nul 2>&1

rem ------------------------------------------------------------------ restart
echo ============================================================
echo  DONE. One more step is required.
echo ============================================================
echo.
echo  The plugin does NOT take effect until dsh web is restarted.
echo  If it is running now, close it completely, then start it again:
echo.
echo      dsh web
echo.
echo  Then open Settings and look for the "OpenDesign Go" section.
echo  The provider is registered as: llm-opendesign-go
echo.
echo  If it still does not appear after the restart, check:
echo    - you restarted the same profile (--profile %PROFILE%)
echo    - DSH_HOME, if you set it, points at the home you expect
echo.
if defined OLD_CP chcp %OLD_CP% >nul 2>&1
pause
exit /b 0

:fail
echo.
echo Installation aborted. Nothing was changed beyond what the output above shows.
echo.
if defined OLD_CP chcp %OLD_CP% >nul 2>&1
pause
exit /b 1
