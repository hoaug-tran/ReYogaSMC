@echo off
cd /d "%~dp0"
where py >nul 2>&1
if %errorlevel% equ 0 (
    py -3 Scripts\hardware_support.py %*
) else (
    python Scripts\hardware_support.py %*
)
if %errorlevel% neq 0 echo ReYoga could not finish every stage. Check the report or install Python 3.9 or newer.
pause
