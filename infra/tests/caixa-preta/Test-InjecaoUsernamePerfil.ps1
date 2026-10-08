# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA (seguranca): confirma que -Username/-Profile
    maliciosos sao barrados pelo PARAMETRO do PowerShell, ANTES de qualquer
    SQL rodar contra o Oracle.

.DESCRIPTION
    infra/scripts/create-team-member.ps1 monta o SQL de CREATE USER por
    concatenacao de string (nao parametrizado) - "CREATE USER $Username
    IDENTIFIED BY ...". A unica coisa que impede um -Username malicioso de
    virar SQL Injection e a validacao declarativa do PARAMETRO
    ([ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,29}$')]) e do -Profile
    ([ValidateSet(...)]) - ela precisa rejeitar ANTES de qualquer docker exec/
    sqlplus ser chamado. Este teste confirma isso tentando nomes de usuario
    classicos de injecao e confirmando que o PowerShell lanca
    ParameterBindingValidationException sem nenhuma tentativa de conexao.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [CAIXA-PRETA/SEGURANCA] Defesa contra -Username/-Profile maliciosos ==" -ForegroundColor Cyan

$createScript = Join-Path $PSScriptRoot '..\..\scripts\create-team-member.ps1'
$results = @()

$usernamesMaliciosos = @(
    "JOAO'; DROP USER SYSTEM; --"
    "JOAO/comment/SILVA"
    "1JOAO"
    "JOAO SILVA"
    "JOAO`"; GRANT DBA TO PUBLIC; --"
    ("A" * 31)
)

foreach ($nomeMalicioso in $usernamesMaliciosos) {
    $foiRejeitado = $false
    try {
        & $createScript -Username $nomeMalicioso -Profile 'Estagiario' -EnvFile $EnvFile *> $null
    } catch {
        $foiRejeitado = $true
    }
    $rotulo = if ($nomeMalicioso.Length -gt 40) { $nomeMalicioso.Substring(0, 40) + '...' } else { $nomeMalicioso }
    $results += New-TestResult -Name "-Username '$rotulo' e rejeitado pelo parametro (nunca chega a montar SQL)" -Passed $foiRejeitado -Details $(if (-not $foiRejeitado) { 'nenhuma excecao foi lancada - o script tentou prosseguir' })
}

$perfisInvalidos = @('Administrador', 'Gerente', '')
# NOTA: "estagiario" (minusculo) NAO entra nesta lista de proposito -
# ValidateSet do PowerShell e case-insensitive por padrao, entao e aceito como
# uma grafia alternativa de "Estagiario" (perfil valido), nao uma falha de
# validacao - confirmado ao escrever este teste.
foreach ($perfilInvalido in $perfisInvalidos) {
    $foiRejeitado = $false
    try {
        & $createScript -Username (New-ThrowawayUsername -Prefix 'TST_INVPROF') -Profile $perfilInvalido -EnvFile $EnvFile *> $null
    } catch {
        $foiRejeitado = $true
    }
    $results += New-TestResult -Name "-Profile '$perfilInvalido' (fora do ValidateSet) e rejeitado pelo parametro" -Passed $foiRejeitado -Details $(if (-not $foiRejeitado) { 'nenhuma excecao foi lancada' })
}

# Controle positivo: um nome valido de verdade passa pela validacao (nao fica
# tudo sendo rejeitado por outro motivo, tipo .env ausente).
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$nomeValido = New-ThrowawayUsername -Prefix 'TST_VALIDO'
try {
    & $createScript -Username $nomeValido -Profile 'Estagiario' -EnvFile $EnvFile *> $null
    $outCheck = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT username FROM dba_users WHERE username = '$nomeValido';`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "(controle positivo) um -Username valido passa normalmente e cria o usuario" -Passed ($outCheck -match [regex]::Escape($nomeValido)) -Details $(if ($outCheck -notmatch [regex]::Escape($nomeValido)) { $outCheck })
} finally {
    $VaultToken = Get-VaultToken -EnvFile $EnvFile
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $nomeValido CASCADE;`nEXIT;`n" | Out-Null
    $policyName = "engineer-$($nomeValido.ToLower())"
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault policy delete $policyName 2>&1 | Out-Null
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault delete "auth/userpass/users/$nomeValido" 2>&1 | Out-Null
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv delete "kawashi-secrets/onboarding/$nomeValido" 2>&1 | Out-Null
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv delete "kawashi-secrets/engineers/$nomeValido" 2>&1 | Out-Null
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
