# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de INTEGRACAO: confirma que a conta de aplicacao (SPRING_APP_USER)
    realmente CONECTA e tem permissao de ciclo de vida completo (CREATE
    TABLE/INSERT/SELECT/UPDATE/DELETE/DROP) no seu tablespace dedicado - e que
    ela NAO consegue ler os ambientes de ciclo de vida (KAWASHI_ENV_*), que
    nao sao dela.

.DESCRIPTION
    E "integracao" (nao caixa-preta pura) porque mistura as duas lentes de
    proposito: confirma o COMPORTAMENTO de conexao/CRUD de fora (o que o
    futuro microsservico Spring Boot vai realmente fazer via JDBC), e tambem
    fecha o ciclo com o teste de caixa-branca irmao
    (Test-SpringAppUserHardeningInternals.ps1) que ja confere a configuracao
    interna dessa mesma conta. Cria e remove uma tabela descartavel dentro do
    proprio schema da aplicacao - nao mexe em nenhum dado de aplicacao real
    (porque nenhum existe ainda; o schema de negocio sera criado pelo
    microsservico, nao por este projeto de infra).
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [INTEGRACAO] Conexao e CRUD da conta de aplicacao (Spring) ==" -ForegroundColor Cyan

$appConn = Get-SpringAppConnectString -EnvFile $EnvFile
$appUser = (Get-SpringAppCredentials -EnvFile $EnvFile).User
$tabela = "TESTE_APP_$((New-ThrowawayUsername -Prefix '').TrimStart('_'))"
$results = @()

try {
    $outConexao = (Invoke-SqlPlus -ConnectString $appConn -Sql "SELECT SYS_CONTEXT('USERENV','SESSION_USER') FROM DUAL;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Conta de aplicacao '$appUser' conecta diretamente (sem proxy, como o pool JDBC faria)" -Passed ($outConexao -match [regex]::Escape($appUser)) -Details $(if ($outConexao -notmatch [regex]::Escape($appUser)) { $outConexao })

    $outCreate = (Invoke-SqlPlus -ConnectString $appConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nCREATE TABLE $tabela (id NUMBER, nota VARCHAR2(50));`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Consegue CREATE TABLE no proprio schema (TS_KAWASHI_DATA)" -Passed ($outCreate -match 'Table created') -Details $(if ($outCreate -notmatch 'Table created') { $outCreate })

    $outInsert = (Invoke-SqlPlus -ConnectString $appConn -Sql "INSERT INTO $tabela VALUES (1, 'registro de aplicacao');`nCOMMIT;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Consegue INSERT na propria tabela" -Passed ($outInsert -match '1 row created') -Details $(if ($outInsert -notmatch '1 row created') { $outInsert })

    $outUpdate = (Invoke-SqlPlus -ConnectString $appConn -Sql "UPDATE $tabela SET nota = 'atualizado' WHERE id = 1;`nCOMMIT;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Consegue UPDATE na propria tabela" -Passed ($outUpdate -match '1 row updated') -Details $(if ($outUpdate -notmatch '1 row updated') { $outUpdate })

    $outSelect = (Invoke-SqlPlus -ConnectString $appConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT nota FROM $tabela WHERE id = 1;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "SELECT confirma o UPDATE anterior" -Passed ($outSelect -match 'atualizado') -Details $(if ($outSelect -notmatch 'atualizado') { $outSelect })

    $outDelete = (Invoke-SqlPlus -ConnectString $appConn -Sql "DELETE FROM $tabela WHERE id = 1;`nCOMMIT;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Consegue DELETE na propria tabela" -Passed ($outDelete -match '1 row deleted') -Details $(if ($outDelete -notmatch '1 row deleted') { $outDelete })

    # A conta de aplicacao nao tem (e nao deve ter) nenhum papel nos ambientes
    # de ciclo de vida (TESTE/DEV/INFRA/HOMOLOG/PROD) - isso e territorio de
    # pessoas (via create-team-member.ps1), nao da aplicacao em si.
    $outIsolamento = (Invoke-SqlPlus -ConnectString $appConn -Sql "SELECT * FROM KAWASHI_ENV_DEV.QUALQUER_COISA;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "NAO alcanca os schemas de ambiente (KAWASHI_ENV_*) - territorio de pessoas, nao de aplicacao (ORA-00942)" -Passed ($outIsolamento -match 'ORA-00942') -Details $(if ($outIsolamento -notmatch 'ORA-00942') { $outIsolamento })
}
finally {
    Write-Host "-> Limpando tabela de teste..."
    Invoke-SqlPlus -ConnectString $appConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP TABLE $tabela;`nEXIT;`n" | Out-Null
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
