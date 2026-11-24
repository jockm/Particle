@echo off
setlocal

REM This script is used to set up the environment for building and testing Particle on Windows.
REM Git Bash and GnuWin32 are expected in their default locations; LLVM and Dart can be found via WinGet.

set "BASH_EXE=C:\Program Files\Git\bin\bash.exe"
set "LLVM_BIN=C:\Program Files\LLVM\bin"
set "GNUWIN_BIN=C:\Program Files (x86)\GnuWin32\bin"
set "DART_BIN="
set "NODE_BIN="
set "OSS_CAD_BIN=%USERPROFILE%\oss-cad-suite\bin"
set "OSS_CAD_LIB=%USERPROFILE%\oss-cad-suite\lib"
set "RISCV_BIN=%USERPROFILE%\xpack-riscv-none-elf-gcc\bin"

if not exist "%BASH_EXE%" (
    echo Git Bash not found: "%BASH_EXE%"
    exit /b 1
)

if not exist "%LLVM_BIN%\clang.exe" (
    set "LLVM_BIN="
    if defined LOCALAPPDATA (
        for /d %%D in ("%LOCALAPPDATA%\Microsoft\WinGet\Packages\MartinStorsjo.LLVM-MinGW.UCRT_*") do (
            for /f "delims=" %%F in ('where /r "%%~fD" clang.exe 2^>nul') do (
                if not defined LLVM_BIN set "LLVM_BIN=%%~dpF"
            )
        )
    )
)

if not defined LLVM_BIN (
    echo LLVM clang.exe not found. Install it with: winget install --id=MartinStorsjo.LLVM-MinGW.UCRT -e
    exit /b 1
)

if not exist "%GNUWIN_BIN%\." (
    echo GnuWin32 tools directory not found: "%GNUWIN_BIN%"
    exit /b 1
)

if defined LOCALAPPDATA (
    for /d %%D in ("%LOCALAPPDATA%\Microsoft\WinGet\Packages\Google.DartSDK_*") do (
        if not defined DART_BIN if exist "%%~fD\dart-sdk\bin\dart.exe" set "DART_BIN=%%~fD\dart-sdk\bin"
    )

    if exist "%LOCALAPPDATA%\Programs\nodejs\node.exe" if exist "%LOCALAPPDATA%\Programs\nodejs\npm.cmd" (
        set "NODE_BIN=%LOCALAPPDATA%\Programs\nodejs"
    )

    for /d %%D in ("%LOCALAPPDATA%\Microsoft\WinGet\Packages\OpenJS.NodeJS.LTS_*") do (
        for /f "delims=" %%F in ('where /r "%%~fD" node.exe 2^>nul') do (
            if not defined NODE_BIN if exist "%%~dpFnpm.cmd" set "NODE_BIN=%%~dpF"
        )
    )
)

if not defined NODE_BIN if exist "%ProgramFiles%\nodejs\node.exe" if exist "%ProgramFiles%\nodejs\npm.cmd" (
    set "NODE_BIN=%ProgramFiles%\nodejs"
)

if defined DART_BIN (
    set "PATH=%DART_BIN%;%LLVM_BIN%;%GNUWIN_BIN%;%PATH%"
) else (
    where dart >nul 2>nul
    if errorlevel 1 (
        echo Dart SDK not found. Install it with: winget install --id=Google.DartSDK -e
        exit /b 1
    )
    set "PATH=%LLVM_BIN%;%GNUWIN_BIN%;%PATH%"
)

if defined NODE_BIN set "PATH=%NODE_BIN%;%PATH%"
if exist "%OSS_CAD_BIN%\." set "PATH=%OSS_CAD_BIN%;%PATH%"
if exist "%OSS_CAD_LIB%\." set "PATH=%OSS_CAD_LIB%;%PATH%"
if exist "%RISCV_BIN%\riscv-none-elf-gcc.exe" set "PATH=%RISCV_BIN%;%PATH%"

where node >nul 2>nul
if errorlevel 1 (
    echo Node.js not found. Install it with: winget install -e --id OpenJS.NodeJS.LTS
    exit /b 1
)

where npm >nul 2>nul
if errorlevel 1 (
    echo npm not found. Reinstall Node.js with: winget install -e --id OpenJS.NodeJS.LTS
    exit /b 1
)

cd /d "%~dp0"
if errorlevel 1 (
    echo Could not change to the project directory.
    exit /b 1
)

"%BASH_EXE%" --login -i
exit /b %ERRORLEVEL%