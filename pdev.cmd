@echo off
setlocal

REM This script is used to set uo and environment for building and testing Particle on Windows. It assumes that 
REM Git Bash, LLVM, and GnuWin32 are installed in their default locations.  If not please refer to GettingStarted.md
REM for what is required for this project

set "BASH_EXE=C:\Program Files\Git\bin\bash.exe"
set "LLVM_BIN=C:\Program Files\LLVM\bin"
set "GNUWIN_BIN=C:\Program Files (x86)\GnuWin32\bin"

if not exist "%BASH_EXE%" (
    echo Git Bash not found: "%BASH_EXE%"
    exit /b 1
)

if not exist "%LLVM_BIN%\." (
    echo LLVM tools directory not found: "%LLVM_BIN%"
    exit /b 1
)

if not exist "%GNUWIN_BIN%\." (
    echo GnuWin32 tools directory not found: "%GNUWIN_BIN%"
    exit /b 1
)

set "PATH=%LLVM_BIN%;%GNUWIN_BIN%;%PATH%"

cd /d "%~dp0"
if errorlevel 1 (
    echo Could not change to the project directory.
    exit /b 1
)

"%BASH_EXE%" --login -i
exit /b %ERRORLEVEL%