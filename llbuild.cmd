@echo off
where bash >nul 2>nul
if errorlevel 1 goto missing_bash
bash "%~dp0llbuild" %*
exit /b %errorlevel%

:missing_bash
>&2 echo llbuild.cmd: bash was not found. Install Git for Windows and ensure bash is on PATH.
exit /b 127
