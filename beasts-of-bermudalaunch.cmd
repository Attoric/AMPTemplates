@echo off
setlocal
set ROOT=%~dp0
set GAME_INI=%ROOT%WindowsServer\BeastsOfBermuda\Saved\Config\WindowsServer\Game.ini
set PY=%ROOT%beasts-of-bermuda-preserve-game-ini.py
set EXE=%ROOT%WindowsServer\BeastsOfBermuda\Binaries\Win64\BeastsOfBermudaServer.exe
if exist "%PY%" (
  python3 "%PY%" --game-ini "%GAME_INI%" --keep 10
  if errorlevel 1 py -3 "%PY%" --game-ini "%GAME_INI%" --keep 10
)
"%EXE%" %*
