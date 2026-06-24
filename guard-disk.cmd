@echo off
rem ============================================================
rem guard-disk.cmd - Aborta a instalacao se houver mais de 1 disco fixo.
rem ============================================================
rem A maquina-alvo tem 1 disco SO. Se houver mais de um, o DiskID=0 do
rem autounattend.xml nao e' deterministico e pode apagar o disco errado.
rem Este guard conta os discos e, se > 1, DESLIGA a maquina antes do wipe.
rem
rem Roda no Windows PE (pass windowsPE). Usa diskpart porque, no boot.wim
rem padrao do Setup, PowerShell e WMIC NAO estao disponiveis (verificado).
rem wpeutil shutdown desliga a sessao WinPE de forma limpa (nao instala nada).
rem
rem >>> NAO esta habilitado por padrao. Ver README ("Guard de disco") para
rem     wiring no autounattend.xml. ANTES de confiar, TESTAR em VM com 2 discos:
rem       - a letra da midia no WinPE nao e' fixa (onde este .cmd e' chamado);
rem       - o parsing depende do idioma do WinPE (PT-BR "Disco" / EN "Disk");
rem       - a ordem RunSynchronous vs wipe nao e' garantida pela Microsoft.
rem ============================================================
setlocal
set "TMP_LD=%TEMP%\guard_ld.txt"
set "TMP_OUT=%TEMP%\guard_out.txt"

echo list disk> "%TMP_LD%"
diskpart /s "%TMP_LD%" > "%TMP_OUT%"

rem Conta linhas que sao um disco: "Disco N" (PT-BR) ou "Disk N" (EN).
set "COUNT=0"
for /f %%C in ('findstr /i /r /c:"Disco [0-9][0-9]*" /c:"Disk [0-9][0-9]*" "%TMP_OUT%" ^| find /c /v ""') do set "COUNT=%%C"

if %COUNT% GTR 1 (
    echo.
    echo ====================================================
    echo  ABORTANDO: %COUNT% discos fixos encontrados. Esperado: 1.
    echo  Risco de apagar o disco errado. Desligando a maquina...
    echo ====================================================
    wpeutil shutdown
    exit /b 1
)

echo guard-disk: %COUNT% disco(s) detectado(s) - OK, seguindo a instalacao.
exit /b 0
