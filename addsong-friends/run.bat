@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

rem Required packages (dfpwm, adm-zip, tar) already ship inside node_modules
rem in this folder - no "npm install" step, so a broken/missing npm on this
rem PC can't break this. All that's needed is node.exe itself.

set "NODE_VERSION=20.11.1"
set "TOOLS_DIR=%~dp0tools"
set "NODE_DIR=%TOOLS_DIR%\node"
set "PORTABLE_NODE=%NODE_DIR%\node.exe"

where node >nul 2>nul
if %errorlevel%==0 (
    set "NODE=node"
) else (
    if not exist "%PORTABLE_NODE%" (
        echo Node.js isn't installed on this PC.
        echo Downloading a portable copy from nodejs.org ^(one-time, ~30MB^)...
        if not exist "%TOOLS_DIR%" mkdir "%TOOLS_DIR%"
        powershell -NoProfile -Command "try { Invoke-WebRequest -Uri 'https://nodejs.org/dist/v%NODE_VERSION%/node-v%NODE_VERSION%-win-x64.zip' -OutFile '%TOOLS_DIR%\node.zip' -UseBasicParsing } catch { exit 1 }"
        if not exist "%TOOLS_DIR%\node.zip" (
            echo.
            echo Download failed - check your internet connection and run this again.
            pause
            exit /b 1
        )
        echo Extracting...
        powershell -NoProfile -Command "Expand-Archive -Path '%TOOLS_DIR%\node.zip' -DestinationPath '%TOOLS_DIR%' -Force"
        del "%TOOLS_DIR%\node.zip"
        if exist "%NODE_DIR%" rmdir /s /q "%NODE_DIR%"
        ren "%TOOLS_DIR%\node-v%NODE_VERSION%-win-x64" node
        echo Portable Node.js ready.
        echo.
    )
    set "NODE=%PORTABLE_NODE%"
)

if not exist "node_modules\dfpwm" (
    echo.
    echo node_modules is missing or incomplete - this folder isn't set up right.
    echo Re-download and fully extract the zip ^(don't just open it, extract it^), then try again.
    pause
    exit /b 1
)

"%NODE%" cli.js
echo.
echo ================================
echo Done. Press any key to close.
echo ================================
pause >nul
