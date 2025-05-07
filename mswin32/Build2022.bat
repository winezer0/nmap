@echo off
set TARGET=%1
set VCCONFIG=%2

:: 查找 VS2022 安装路径并设置编译环境
for /f "usebackq delims=#" %%a in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere" -version 17 -property installationPath`) do call "%%a\VC\Auxiliary\Build\vcvarsall.bat" x86 && goto :next
:next

@echo on
if "%TARGET%" == "Vars" ( goto :vars )

:: 构建 PCRE2（使用 VS2022 的生成器）
mkdir build-pcre2
cd build-pcre2
cmake.exe -A Win32 -G "Visual Studio 17 2022" ..\..\libpcre\ || goto :QUIT
cd ..

:: 使用 MSBuild 构建 Nmap 解决方案
msbuild -nologo nmap.sln -m -t:%TARGET% -p:Configuration="%VCCONFIG%" -p:Platform="Win32" -fl
goto :QUIT

:vars
cl.exe /nologo /EP make-vars.h > make-vars.make

:QUIT
exit /b %errorlevel%
