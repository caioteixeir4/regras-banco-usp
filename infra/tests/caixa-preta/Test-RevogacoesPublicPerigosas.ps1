# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: confirma que um usuario comum realmente NAO consegue
    chamar os pacotes perigosos que infra/oracle-init/10_advanced_hardening.sql
    revoga de PUBLIC (UTL_HTTP, UTL_TCP, UTL_SMTP, UTL_INADDR, UTL_FILE,
    DBMS_JAVA) - classicamente usados em escalonamento de privilegio e
    exfiltracao via SQL Injection em Oracle.

.DESCRIPTION
    So observa o resultado de tentar EXECUTAR cada pacote (ORA-06550/PLS-00201,
    que e o que aparece quando falta privilegio de EXECUTE) - nunca consulta
    DBA_TAB_PRIVS ou DBA_SYS_PRIVS pra decidir.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [CAIXA-PRETA] Pacotes perigosos revogados de PUBLIC ==" -ForegroundColor Cyan

$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$username = New-ThrowawayUsername -Prefix 'TST_PUBCHK'
$senha = New-StrongPassword -Length 16 -AvoidSubstring $username
$results = @()

$pacotes = @(
    @{ Nome = 'UTL_HTTP';  Chamada = "UTL_HTTP.REQUEST('http://127.0.0.1')" }
    @{ Nome = 'UTL_TCP';   Chamada = "UTL_TCP.OPEN_CONNECTION('127.0.0.1', 80)" }
    @{ Nome = 'UTL_SMTP';  Chamada = "UTL_SMTP.OPEN_CONNECTION('127.0.0.1', 25)" }
    @{ Nome = 'UTL_INADDR';Chamada = "UTL_INADDR.GET_HOST_NAME('127.0.0.1')" }
    @{ Nome = 'UTL_FILE';  Chamada = "UTL_FILE.FOPEN('TMP', 'x', 'r')" }
    @{ Nome = 'DBMS_JAVA'; Chamada = "DBMS_JAVA.LONGNAME('x')" }
)

try {
    Invoke-SqlPlus -ConnectString $engineerConn -Sql @"
ALTER SESSION SET CONTAINER = FREEPDB1;
CREATE USER $username IDENTIFIED BY "$senha" PROFILE KAWASHI_SECURE_PROFILE DEFAULT TABLESPACE TS_KAWASHI_DATA;
GRANT CREATE SESSION TO $username;
EXIT;
"@ | Out-Null

    $userConn = "$username/$senha@//localhost:1521/FREEPDB1"

    foreach ($pacote in $pacotes) {
        $sql = "DECLARE V_RESULTADO VARCHAR2(100); BEGIN V_RESULTADO := TO_CHAR($($pacote.Chamada)); EXCEPTION WHEN OTHERS THEN NULL; END;`n/`nEXIT;`n"
        # Chamada generica que compila (ou nao) - o que importa e se o PL/SQL
        # ACEITA referenciar o pacote, nao o resultado da chamada em si (que
        # pode falhar por outros motivos - rede indisponivel, arquivo
        # inexistente - sem relacao com privilegio).
        $out = (Invoke-SqlPlus -ConnectString $userConn -Sql "BEGIN $($pacote.Chamada); EXCEPTION WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('CHAMOU'); END;`n/`nEXIT;`n") -join "`n"
        $semPrivilegio = $out -match 'PLS-00201'
        $results += New-TestResult -Name "Usuario comum NAO consegue referenciar $($pacote.Nome) (PLS-00201, sem privilegio EXECUTE)" -Passed $semPrivilegio -Details $(if (-not $semPrivilegio) { $out })
    }
}
finally {
    Write-Host "-> Limpando usuario descartavel..."
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $username CASCADE;`nEXIT;`n" | Out-Null
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
