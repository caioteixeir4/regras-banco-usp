# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: confirma que tentar criar o MESMO usuario duas vezes
    falha de forma limpa (nao cria estado parcial/corrompido no Vault), e que
    o mesmo nome pode ser reusado normalmente depois que o primeiro e removido.

.DESCRIPTION
    Observa apenas o comportamento externo de infra/scripts/create-team-member.ps1:
    se ele lanca erro (e nao finge sucesso) na segunda tentativa, e se o Vault
    fica sem "lixo" (policy/login userpass criados por uma tentativa que falhou
    no meio). Nao inspeciona o codigo do script, so roda ele duas vezes e olha
    o resultado.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [CAIXA-PRETA] Criacao de usuario duplicado ==" -ForegroundColor Cyan

$createScript = Join-Path $PSScriptRoot '..\..\scripts\create-team-member.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken = Get-VaultToken -EnvFile $EnvFile
$username = New-ThrowawayUsername -Prefix 'TST_DUP'
$results = @()

try {
    & $createScript -Username $username -Profile 'EstagiarioDev' -EnvFile $EnvFile *> $null
    $outCriados = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT username FROM dba_users WHERE username = '$username';`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Primeira criacao de '$username' funciona" -Passed ($outCriados -match [regex]::Escape($username)) -Details $(if ($outCriados -notmatch [regex]::Escape($username)) { $outCriados })

    $segundaFalhou = $false
    $erroSegunda = ''
    try {
        & $createScript -Username $username -Profile 'Desenvolvedor' -EnvFile $EnvFile *> $null
    } catch {
        $segundaFalhou = $true
        $erroSegunda = $_.Exception.Message
    }
    $results += New-TestResult -Name "Segunda criacao do MESMO usuario lanca erro (nao finge sucesso)" -Passed $segundaFalhou -Details $(if (-not $segundaFalhou) { 'nenhuma excecao foi lancada' })
    $results += New-TestResult -Name "Erro da segunda tentativa menciona ORA-01920 (nome ja existe)" -Passed ($erroSegunda -match 'ORA-01920') -Details $(if ($erroSegunda -notmatch 'ORA-01920') { $erroSegunda })

    # A tentativa que falhou foi a de perfil "Desenvolvedor" - confirma que o
    # usuario continua com o PERFIL ORIGINAL (EstagiarioDev: so proxy pra
    # TESTE_DEV), ou seja, a tentativa fracassada nao alterou o estado do
    # usuario existente.
    $outProxy = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT client FROM proxy_users WHERE proxy = '$username';`nEXIT;`n") -join "`n"
    # "KAWASHI_ENV_DEV" nao e substring de "KAWASHI_ENV_TESTE_DEV" (tem
    # "_TESTE_" no meio) - os dois matches nao colidem entre si.
    $manteveOriginal = ($outProxy -match 'KAWASHI_ENV_TESTE_DEV') -and ($outProxy -notmatch 'KAWASHI_ENV_DEV')
    $results += New-TestResult -Name "Usuario existente mantem o perfil original (EstagiarioDev) - tentativa duplicada nao alterou nada" -Passed $manteveOriginal -Details $(if (-not $manteveOriginal) { $outProxy })

    # Nao deve ter sobrado policy/login userpass no Vault de uma tentativa que
    # nem chegou a mexer no Vault (CREATE USER falha ANTES do passo de Vault).
    $policyName = "engineer-$($username.ToLower())"
    $policyList = (docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault policy list 2>&1) -join "`n"
    $policyCount = ([regex]::Matches($policyList, [regex]::Escape($policyName))).Count
    $results += New-TestResult -Name "Policy '$policyName' existe exatamente uma vez no Vault (sem duplicata/lixo da tentativa que falhou)" -Passed ($policyCount -eq 1) -Details $(if ($policyCount -ne 1) { "contagem=$policyCount" })
}
finally {
    Write-Host "-> Limpando usuario descartavel e artefatos no Vault..."
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $username CASCADE;`nEXIT;`n" | Out-Null
    $policyName = "engineer-$($username.ToLower())"
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault policy delete $policyName 2>&1 | Out-Null
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault delete "auth/userpass/users/$username" 2>&1 | Out-Null
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv delete "kawashi-secrets/onboarding/$username" 2>&1 | Out-Null
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv delete "kawashi-secrets/engineers/$username" 2>&1 | Out-Null
}

# Confirma que, depois de removido, o mesmo nome pode ser usado de novo sem
# nenhum resquicio da primeira conta atrapalhar.
try {
    & $createScript -Username $username -Profile 'EstagiarioDev' -EnvFile $EnvFile *> $null
    $outRecriado = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT username FROM dba_users WHERE username = '$username';`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Apos remover, o mesmo nome de usuario pode ser recriado sem erro" -Passed ($outRecriado -match [regex]::Escape($username)) -Details $(if ($outRecriado -notmatch [regex]::Escape($username)) { $outRecriado })
}
finally {
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $username CASCADE;`nEXIT;`n" | Out-Null
    $policyName = "engineer-$($username.ToLower())"
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault policy delete $policyName 2>&1 | Out-Null
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault delete "auth/userpass/users/$username" 2>&1 | Out-Null
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv delete "kawashi-secrets/onboarding/$username" 2>&1 | Out-Null
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv delete "kawashi-secrets/engineers/$username" 2>&1 | Out-Null
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
