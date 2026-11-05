@echo off
title Subir a GitHub - Floreria Muniz
echo ======================================================
echo   Subiendo cambios a https://github.com/Ihan243/FLORER-A-MU-IZ.git
echo ======================================================
"C:\Users\iraul\MinGit\cmd\git.exe" push -u origin main
if %ERRORLEVEL% equ 0 (
    echo.
    echo [EXITO] Archivos subidos correctamente a GitHub!
) else (
    echo.
    echo [ERROR] No se pudo subir. Verifica tu inicio de sesion en GitHub.
)
echo ======================================================
pause
