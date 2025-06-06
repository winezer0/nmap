rmdir Release\nmap.tlog /s /q

del Release\*.obj /s
del Release\*.log /s
del Release\*.iobj /s
del Release\*.pdb /s
del Release\*.recipe /s
del Release\nmap.vcxproj.FileListAbsolute.txt /s

xcopy ..\nse_main.lua Release  /q  /y
xcopy ..\nselib Release\nselib /e /i /h /r /y /q
xcopy ..\scripts Release\scripts /e /i /h /r /y /q

xcopy ..\libssh2\win32\Release_dll\libssh2.dll  Release  /q /y
for /r "..\libz\contrib\vstudio" %%f in (zlibwapi.dll) do xcopy "%%f" "Release\" /q /y

xcopy ..\ncat\Release\ca-bundle.crt Release  /q  /y
xcopy ..\ncat\Release\ncat.exe Release  /q  /y
xcopy ..\nping\Release\nping.exe Release  /q  /y

