# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: confirma que KAWASHI_SECURE_PROFILE (PASSWORD_REUSE_TIME=365,
    PASSWORD_REUSE_MAX=10, ver 02_global_hardening.sql) realmente impede reusar
    uma senha recem-trocada - nao so "esta declarado no profile".

.DESCRIPTION
    Nao da pra esperar 365 dias nem trocar de senha 10 vezes num teste
    automatizado - mas o caso mais simples e universal (tentar voltar pra senha
    ATUAL/mais recente, sem nenhum dia ter passado) ja e suficiente: com
    PASSWORD_REUSE_TIME e PASSWORD_REUSE_MAX os dois definidos (nao UNLIMITED),
    o Oracle exige as DUAS condicoes satisfeitas pra permitir reuso - nenhuma
    delas vale ainda no instante seguinte a troca. So observa a resposta do
    ALTER USER (ORA-28007), nunca consulta nenhuma tabela de historico de senha.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [CAIXA-PRETA] Reuso imediato de senha e bloqueado ==" -ForegroundColor Cyan

$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$username = New-ThrowawayUsername -Prefix 'TST_REUSE'
$senhaOriginal = New-StrongPassword -Length 16 -AvoidSubstring $username
$senhaNova = New-StrongPassword -Length 16 -AvoidSubstring $username
$results = @()

try {
    Invoke-SqlPlus -ConnectString $engineerConn -Sql @"
ALTER SESSION SET CONTAINER = FREEPDB1;
CREATE USER $username IDENTIFIED BY "$senhaOriginal" PROFILE KAWASHI_SECURE_PROFILE DEFAULT TABLESPACE TS_KAWASHI_DATA;
GRANT CREATE SESSION TO $username;
EXIT;
"@ | Out-Null

    $outReuso = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nALTER USER $username IDENTIFIED BY `"$senhaOriginal`";`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Tentar 'trocar' para a MESMA senha atual e rejeitado (ORA-28007)" -Passed ($outReuso -match 'ORA-28007') -Details $(if ($outReuso -notmatch 'ORA-28007') { $outReuso })

    $outTrocaValida = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nALTER USER $username IDENTIFIED BY `"$senhaNova`";`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "(controle positivo) Trocar para uma senha REALMENTE nova e aceito" -Passed ($outTrocaValida -match 'User altered') -Details $(if ($outTrocaValida -notmatch 'User altered') { $outTrocaValida })

    $outVoltarAntiga = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nALTER USER $username IDENTIFIED BY `"$senhaOriginal`";`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Voltar para a senha ORIGINAL (ainda no historico recente) tambem e rejeitado (ORA-28007)" -Passed ($outVoltarAntiga -match 'ORA-28007') -Details $(if ($outVoltarAntiga -notmatch 'ORA-28007') { $outVoltarAntiga })
}
finally {
    Write-Host "-> Limpando usuario descartavel..."
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $username CASCADE;`nEXIT;`n" | Out-Null
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
