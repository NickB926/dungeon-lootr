@echo off
cd /d "%~dp0"
echo.
echo  Dungeon Lootr publish (like PlayerTools)
echo  Bumps version, stages files + Ataraxia, pushes GitHub.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Publish-DungeonLootr.ps1" %*
set ERR=%ERRORLEVEL%
echo.
if %ERR% NEQ 0 (
  echo FAILED exit %ERR%
) else (
  echo Done.
)
pause
exit /b %ERR%
