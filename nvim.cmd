@echo off
rem ==========================================================================
rem  nvim.cmd - start the Neovim kit. Double-click it, or run it from a
rem  terminal with files to open:   nvim.cmd notes.org
rem
rem  Neovim ships already unpacked in the nvim-win64 folder next to this
rem  file, so there is nothing to unpack or install. This script only finds
rem  nvim.exe and starts it with the nvim folder next to this file as the
rem  config. It never deletes, moves or unpacks anything.
rem
rem  Where it looks, in order:
rem    1. nvim-win64\bin\nvim.exe next to this file
rem    2. any complete Neovim under this folder or %LOCALAPPDATA%\nvim-kit,
rem       however it is nested (a copy unpacked by hand)
rem    3. nvim.exe on PATH
rem
rem  No ( ) blocks with paths inside on purpose: a folder name with a
rem  parenthesis, like "normal-mode-main (1)", breaks those in cmd.
rem ==========================================================================
setlocal EnableExtensions DisableDelayedExpansion

rem this folder, without the trailing backslash
set "KIT=%~dp0"
set "KIT=%KIT:~0,-1%"
set "EXE="

if exist "%KIT%\nvim-win64\bin\nvim.exe" set "EXE=%KIT%\nvim-win64\bin\nvim.exe"
if defined EXE goto run

rem complete = nvim.exe with the runtime folder beside its bin folder
for /r "%KIT%" %%F in (nvim.exe) do if not defined EXE if exist "%%F" if exist "%%~dpF..\share\nvim\runtime\filetype.lua" set "EXE=%%F"
if defined EXE goto run
if exist "%LOCALAPPDATA%\nvim-kit\" for /r "%LOCALAPPDATA%\nvim-kit" %%F in (nvim.exe) do if not defined EXE if exist "%%F" if exist "%%~dpF..\share\nvim\runtime\filetype.lua" set "EXE=%%F"
if defined EXE goto run
for /f "delims=" %%F in ('where nvim.exe 2^>nul') do if not defined EXE set "EXE=%%F"
if defined EXE goto run
goto missing

:run
title Neovim
rem skip Neovim's terminal color probes: the config sets colors itself, and a
rem console that ignores them gets an E1568 warning at every start
set "NVIM_NOTTYFAST=1"
set "XDG_CONFIG_HOME=%KIT%"
"%EXE%" %*
if errorlevel 1 goto failed
exit /b 0

rem --- failures: say what happened and keep the window open -----------------
:failed
echo.
echo  Neovim stopped with an error (exit code %ERRORLEVEL%).
echo    nvim.exe: %EXE%
echo  If Windows said it is blocked by policy, the kit cannot get around that.
goto hold

:missing
echo.
echo  Could not find Neovim. It should be here:
echo    %KIT%\nvim-win64\bin\nvim.exe
echo  This copy of the repo is incomplete. Download it again (GitHub: Code,
echo  Download ZIP), extract everything, and run nvim.cmd from the new copy.
goto hold

:hold
echo.
pause
exit /b 1
