# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-BRANCA (consistencia/determinismo): confirma que o MESMO
    fluxo de login sempre produz exatamente o mesmo padrao de eventos em
    KAWASHI_SECURITY_LOG - nunca duplicado, nunca perdido, em N tentativas
    repetidas e identicas.

.DESCRIPTION
    Testes anteriores confirmam que um login gera UM SUCCESSFUL_LOGIN. Este
    teste confirma que isso vale de forma ESTAVEL ao longo de varias
    repeticoes - pega regressao do tipo "o trigger disparou duas vezes" (log
    duplicado) ou "funcionou da primeira vez mas nao da segunda" (algum estado
    que deveria ser idempotente e nao e, por exemplo um job/cache/contador que
    o ambiente acumula entre conexoes). Roda 8 logins diretos consecutivos do
    mesmo usuario descartavel e confirma: exatamente 8 SUCCESSFUL_LOGIN, 8
    SESSION_END, nenhum evento de bloqueio inesperado (BLOCKED_OS_USER/
    BLOCKED_TOOL) misturado no meio.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env'),
    [int]$Repeticoes = 8
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [CAIXA-BRANCA] Consistencia do mesmo login repetido $Repeticoes vezes ==" -ForegroundColor Cyan

$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$username = New-ThrowawayUsername -Prefix 'TST_CONSIST'
$senha = New-StrongPassword -Length 16 -AvoidSubstring $username
$results = @()

try {
    Invoke-SqlPlus -ConnectString $engineerConn -Sql @"
ALTER SESSION SET CONTAINER = FREEPDB1;
CREATE USER $username IDENTIFIED BY "$senha" PROFILE KAWASHI_SECURE_PROFILE DEFAULT TABLESPACE TS_KAWASHI_DATA;
GRANT CREATE SESSION TO $username;
EXIT;
"@ | Out-Null

    $userConn = "$username/$senha@//localhost:1521/FREEPDB1"
    $saidasPorTentativa = @()
    for ($i = 1; $i -le $Repeticoes; $i++) {
        $out = (Invoke-SqlPlus -ConnectString $userConn -Sql "SELECT 1 FROM DUAL;`nEXIT;`n") -join "`n"
        $saidasPorTentativa += $out
        $todasOk = $saidasPorTentativa | ForEach-Object { $_ -notmatch 'ORA-\d{5}' }
    }
    $results += New-TestResult -Name "Todas as $Repeticoes tentativas de login conectaram sem erro (precondicao - senao a contagem de eventos abaixo nao faz sentido)" -Passed (($saidasPorTentativa | Where-Object { $_ -match 'ORA-\d{5}' }).Count -eq 0) -Details $(($saidasPorTentativa | Where-Object { $_ -match 'ORA-\d{5}' }) -join "`n---`n")

    $sqlContagem = "ALTER SESSION SET CONTAINER = FREEPDB1;`nSET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT event_type || '=' || COUNT(*) FROM KAWASHI_SECURITY_LOG WHERE db_user = '$username' GROUP BY event_type ORDER BY event_type;`nEXIT;`n"
    $outContagem = (Invoke-SqlPlus -ConnectString '/ as sysdba' -Sql $sqlContagem) -join "`n"

    $results += New-TestResult -Name "Exatamente $Repeticoes SUCCESSFUL_LOGIN registrados (nenhum duplicado, nenhum perdido)" -Passed ($outContagem -match "SUCCESSFUL_LOGIN=$Repeticoes(\D|$)") -Details $(if ($outContagem -notmatch "SUCCESSFUL_LOGIN=$Repeticoes(\D|$)") { $outContagem })
    $results += New-TestResult -Name "Exatamente $Repeticoes SESSION_END registrados" -Passed ($outContagem -match "SESSION_END=$Repeticoes(\D|$)") -Details $(if ($outContagem -notmatch "SESSION_END=$Repeticoes(\D|$)") { $outContagem })
    $results += New-TestResult -Name "Nenhum evento de bloqueio inesperado (BLOCKED_OS_USER/BLOCKED_TOOL) no meio das tentativas" -Passed ($outContagem -notmatch 'BLOCKED_') -Details $(if ($outContagem -match 'BLOCKED_') { $outContagem })
}
finally {
    Write-Host "-> Limpando usuario descartavel..."
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $username CASCADE;`nEXIT;`n" | Out-Null
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
