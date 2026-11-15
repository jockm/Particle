@echo off
where bash >nul 2>nul
if errorlevel 1 goto missing_bash
bash "%~dp0pbuild" %*
exit /b %errorlevel%

:missing_bash
>&2 echo pbuild.cmd: bash was not found. Install Git for Windows and ensure bash is on PATH.
exit /b 127
