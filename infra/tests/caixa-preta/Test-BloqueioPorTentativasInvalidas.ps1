# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: confirma que uma conta trava apos tentativas
    repetidas de senha invalida, observando SOMENTE o comportamento externo de
    login - nunca consulta DBA_USERS.ACCOUNT_STATUS nem qualquer outra tabela
    de catalogo (isso seria um teste de caixa-branca).

.DESCRIPTION
    Cria um usuario descartavel com KAWASHI_SECURE_PROFILE (FAILED_LOGIN_ATTEMPTS=5,
    ver infra/oracle-init/02_global_hardening.sql), tenta logar com senha
    errada 5 vezes seguidas (cada tentativa numa conexao nova, para nao
    esbarrar no limite de protocolo SEC_MAX_FAILED_LOGIN_ATTEMPTS=3, que e por
    conexao e nao e o alvo deste teste) e entao tenta logar com a senha
    CORRETA - o unico sinal observado e a mensagem de erro do proprio
    SQL*Plus (ORA-01017 = credencial invalida, conta ainda ativa; ORA-28000 =
    conta bloqueada).
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [CAIXA-PRETA] Bloqueio de conta por tentativas invalidas ==" -ForegroundColor Cyan

$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$username = New-ThrowawayUsername -Prefix 'TST_LOCK'
$senhaCorreta = 'C0rrectHorse!Battery9'
$results = @()

try {
    $sqlCriar = "ALTER SESSION SET CONTAINER = FREEPDB1;`nCREATE USER $username IDENTIFIED BY `"$senhaCorreta`" PROFILE KAWASHI_SECURE_PROFILE DEFAULT TABLESPACE TS_KAWASHI_DATA;`nGRANT CREATE SESSION TO $username;`nEXIT;`n"
    $outCriar = (Invoke-SqlPlus -ConnectString $engineerConn -Sql $sqlCriar) -join "`n"
    if ($outCriar -match 'ORA-\d{5}') { throw "Falha ao criar usuario descartavel:`n$outCriar" }

    for ($i = 1; $i -le 5; $i++) {
        $output = (Invoke-SqlPlus -ConnectString "$username/SenhaErrada_$($i)!@//localhost:1521/FREEPDB1" -Sql "EXIT;") -join "`n"
        $passou = $output -match 'ORA-01017'
        $results += New-TestResult -Name "Tentativa invalida $i de 5 e rejeitada sem travar a conta ainda" -Passed $passou -Details $(if (-not $passou) { $output })
    }

    $outputBloqueado = (Invoke-SqlPlus -ConnectString "$username/$senhaCorreta@//localhost:1521/FREEPDB1" -Sql "EXIT;") -join "`n"
    $bloqueou = $outputBloqueado -match 'ORA-28000'
    $results += New-TestResult -Name 'Apos 5 tentativas invalidas seguidas, a conta trava mesmo com a senha correta (ORA-28000)' -Passed $bloqueou -Details $(if (-not $bloqueou) { $outputBloqueado })
}
finally {
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $username CASCADE;`nEXIT;`n" | Out-Null
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
