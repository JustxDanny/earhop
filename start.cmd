@echo off
rem Launch the toggle script. %~dp0 = directory of this .cmd, so this works
rem from any location AND from a Startup-folder copy (since paths resolve
rem relative to the cmd file itself).
start "" "%~dp0bin\AutoHotkey64.exe" "%~dp0toggle.ahk"
