# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA (seguranca, achado critico ja corrigido): confirma
    que o parametro -Roles de infra/scripts/create-team-member.ps1 REJEITA
    roles nativas/perigosas do Oracle (DBA e afins) - nao deixa quem roda o
    script se auto-conceder (ou conceder a outra pessoa) privilegio total na
    hora da criacao.

.DESCRIPTION
    ACHADO REAL (nao hipotetico - testado ao vivo ANTES da correcao existir):
    rodar "create-team-member.ps1 -Username X -Profile EstagiarioDev -Roles
    @('DBA')" funcionava sem nenhuma resistencia - um Estagiario novo saia da
    criacao com DBA completo. Isso quebrava TODO o modelo de RBAC deste
    projeto: qualquer pessoa capaz de rodar o script de onboarding (ou seja,
    com acesso ao .env) podia conceder privilegio administrativo total pra
    qualquer username, sem precisar de nenhum passo a mais.

    Corrigido com um ValidateSet restringindo -Roles as roles PROPRIAS da
    Kawashi (nenhuma delas chega perto de poder administrativo). Este teste
    confirma que a rejeicao acontece no PARAMETRO do PowerShell (antes de
    qualquer conexao com o Oracle/Vault - igual a defesa contra
    -Username/-Profile maliciosos em Test-InjecaoUsernamePerfil.ps1), e que
    roles legitimas continuam funcionando normalmente.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [CAIXA-PRETA/SEGURANCA] -Roles rejeita privilegio administrativo ==" -ForegroundColor Cyan

$createScript = Join-Path $PSScriptRoot '..\..\scripts\create-team-member.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken = Get-VaultToken -EnvFile $EnvFile
$results = @()

$rolesPerigosas = @('DBA', 'SYSDBA', 'IMP_FULL_DATABASE', 'EXP_FULL_DATABASE', 'ROLE_KAWASHI_INFRA; GRANT DBA TO PUBLIC')

foreach ($rolePerigosa in $rolesPerigosas) {
    $username = New-ThrowawayUsername -Prefix 'TST_PERIG'
    $foiRejeitado = $false
    try {
        & $createScript -Username $username -Profile 'EstagiarioDev' -Roles @($rolePerigosa) -EnvFile $EnvFile *> $null
    } catch {
        $foiRejeitado = $true
    }
    $results += New-TestResult -Name "-Roles @('$rolePerigosa') e rejeitado pelo parametro (nunca chega a montar SQL)" -Passed $foiRejeitado -Details $(if (-not $foiRejeitado) { 'nenhuma excecao foi lancada - o script tentou prosseguir' })

    if (-not $foiRejeitado) {
        # Rede de seguranca: se por algum motivo a validacao nao pegou,
        # confirma que o usuario NAO saiu com a role perigosa de verdade, e
        # limpa o que sobrou.
        $outRoles = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT granted_role FROM dba_role_privs WHERE grantee = '$username';`nEXIT;`n") -join "`n"
        $results += New-TestResult -Name "[REDE DE SEGURANCA] '$username' nao recebeu a role perigosa de verdade" -Passed ($outRoles -notmatch [regex]::Escape($rolePerigosa.Split(';')[0].Trim())) -Details $outRoles
        Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $username CASCADE;`nEXIT;`n" | Out-Null
        $policyName = "engineer-$($username.ToLower())"
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault policy delete $policyName 2>&1 | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault delete "auth/userpass/users/$username" 2>&1 | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv delete "kawashi-secrets/onboarding/$username" 2>&1 | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv delete "kawashi-secrets/engineers/$username" 2>&1 | Out-Null
    }
}

# Controle positivo: uma role legitima da propria Kawashi continua funcionando.
$usernameValido = New-ThrowawayUsername -Prefix 'TST_ROLEVALIDA'
try {
    & $createScript -Username $usernameValido -Profile 'EstagiarioDev' -Roles @('ROLE_KAWASHI_DEVELOPER') -EnvFile $EnvFile *> $null
    $outRolesValidas = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT granted_role FROM dba_role_privs WHERE grantee = '$usernameValido';`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "(controle positivo) -Roles @('ROLE_KAWASHI_DEVELOPER') (role legitima da Kawashi) continua funcionando" -Passed ($outRolesValidas -match 'ROLE_KAWASHI_DEVELOPER') -Details $(if ($outRolesValidas -notmatch 'ROLE_KAWASHI_DEVELOPER') { $outRolesValidas })
} finally {
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $usernameValido CASCADE;`nEXIT;`n" | Out-Null
    $policyName = "engineer-$($usernameValido.ToLower())"
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault policy delete $policyName 2>&1 | Out-Null
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault delete "auth/userpass/users/$usernameValido" 2>&1 | Out-Null
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv delete "kawashi-secrets/onboarding/$usernameValido" 2>&1 | Out-Null
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv delete "kawashi-secrets/engineers/$usernameValido" 2>&1 | Out-Null
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
