@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

rem Pinned Node.js version for the portable fallback below. Only used if this
rem PC doesn't already have Node installed - doesn't need to be the newest.
set "NODE_VERSION=20.11.1"
set "TOOLS_DIR=%~dp0tools"
set "NODE_DIR=%TOOLS_DIR%\node"
set "PORTABLE_NODE=%NODE_DIR%\node.exe"

where node >nul 2>nul
if %errorlevel%==0 (
    set "NODE=node"
    set "NPM=npm"
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
    set "NPM=%NODE_DIR%\npm.cmd"
)

if not exist "node_modules" (
    echo Setting up ^(first run only^), this can take a minute...
    call "%NPM%" install --silent
)

"%NODE%" cli.js
echo.
echo ================================
echo Done. Press any key to close.
echo ================================
pause >nul
