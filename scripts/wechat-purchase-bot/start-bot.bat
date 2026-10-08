@echo off
rem TECHM8 WeChat purchasing helper: sets up its own Python environment on first run, then starts.
chcp 65001 >nul
cd /d "%~dp0"
if not exist ".venv\Scripts\python.exe" (
  echo 第一次运行，正在安装……
  py -3 -m venv .venv || python -m venv .venv
  ".venv\Scripts\python.exe" -m pip install --disable-pip-version-check -q -r requirements.txt
)
if not exist "local\config.json" (
  ".venv\Scripts\python.exe" bot.py --init
  echo.
  echo 把上面的令牌指纹复制到 采购跟单 - 设置 - 微信自动登记 - 助手电脑 登记，然后再运行一次 start-bot.bat。
  pause
  exit /b
)
".venv\Scripts\python.exe" bot.py %*
pause
