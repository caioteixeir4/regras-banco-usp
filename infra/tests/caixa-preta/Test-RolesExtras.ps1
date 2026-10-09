# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: confirma que o parametro -Roles do
    infra/scripts/create-team-member.ps1 (excecoes pontuais alem do -Profile)
    realmente concede a(s) role(s) extra(s) - este recurso nunca tinha sido
    exercitado por nenhum teste ate agora.

.DESCRIPTION
    Cria um Estagiario (perfil mais restrito) pedindo uma role extra
    (ROLE_KAWASHI_DEVELOPER) e confirma, de fora, que o usuario consegue fazer
    algo que o perfil Estagiario sozinho NAO permitiria (CREATE TABLE fora de
    qualquer ambiente/proxy), mas que a role extra concede diretamente.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [CAIXA-PRETA] Parametro -Roles concede excecao pontual ==" -ForegroundColor Cyan

$createScript = Join-Path $PSScriptRoot '..\..\scripts\create-team-member.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken = Get-VaultToken -EnvFile $EnvFile
$results = @()

$semRole = New-ThrowawayUsername -Prefix 'TST_NOROLE'
$comRole = New-ThrowawayUsername -Prefix 'TST_EXTRAROLE'

function Limpar-Usuario {
    param([string]$Username)
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $Username CASCADE;`nEXIT;`n" | Out-Null
    $policyName = "engineer-$($Username.ToLower())"
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault policy delete $policyName 2>&1 | Out-Null
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault delete "auth/userpass/users/$Username" 2>&1 | Out-Null
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv delete "kawashi-secrets/onboarding/$Username" 2>&1 | Out-Null
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv delete "kawashi-secrets/engineers/$Username" 2>&1 | Out-Null
}

function Get-SenhaDefinitiva {
    param([string]$Username)
    $senha = New-StrongPassword -Length 16 -AvoidSubstring $Username
    $out = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nALTER USER $Username IDENTIFIED BY `"$senha`";`nEXIT;`n") -join "`n"
    if ($out -match 'ORA-\d{5}') { throw "Falha definindo senha definitiva de '$Username':`n$out" }
    return $senha
}

try {
    & $createScript -Username $semRole -Profile 'EstagiarioDev' -EnvFile $EnvFile *> $null
    & $createScript -Username $comRole -Profile 'EstagiarioDev' -Roles @('ROLE_KAWASHI_DEVELOPER') -EnvFile $EnvFile *> $null

    $senhaSemRole = Get-SenhaDefinitiva -Username $semRole
    $senhaComRole = Get-SenhaDefinitiva -Username $comRole

    $tabelaSemRole = "TESTE_ROLES_A_$((New-ThrowawayUsername -Prefix '').TrimStart('_'))"
    $tabelaComRole = "TESTE_ROLES_B_$((New-ThrowawayUsername -Prefix '').TrimStart('_'))"

    $outSemRole = (Invoke-SqlPlus -ConnectString "$semRole/$senhaSemRole@//localhost:1521/FREEPDB1" -Sql "CREATE TABLE $tabelaSemRole (id NUMBER);`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Estagiario SEM -Roles extra nao consegue CREATE TABLE no proprio schema (ORA-01031)" -Passed ($outSemRole -match 'ORA-01031') -Details $(if ($outSemRole -notmatch 'ORA-01031') { $outSemRole })

    $outComRole = (Invoke-SqlPlus -ConnectString "$comRole/$senhaComRole@//localhost:1521/FREEPDB1" -Sql "CREATE TABLE $tabelaComRole (id NUMBER);`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Estagiario COM -Roles ROLE_KAWASHI_DEVELOPER consegue CREATE TABLE no proprio schema" -Passed ($outComRole -match 'Table created') -Details $(if ($outComRole -notmatch 'Table created') { $outComRole })

    Invoke-SqlPlus -ConnectString "$comRole/$senhaComRole@//localhost:1521/FREEPDB1" -Sql "DROP TABLE $tabelaComRole;`nEXIT;`n" | Out-Null
}
finally {
    Write-Host "-> Limpando usuarios descartaveis e artefatos no Vault..."
    Limpar-Usuario -Username $semRole
    Limpar-Usuario -Username $comRole
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
