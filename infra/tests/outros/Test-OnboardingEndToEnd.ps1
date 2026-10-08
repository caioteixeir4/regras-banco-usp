# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de INTEGRACAO: roda o fluxo real de onboarding
    (infra/scripts/create-team-member.ps1) de ponta a ponta e confere os
    efeitos colaterais nos DOIS sistemas que ele toca - Oracle e Vault.

.DESCRIPTION
    Diferente dos testes de caixa-preta (que validam COMPORTAMENTO de acesso)
    ou de caixa-branca (que validam mecanismos internos isolados), este teste
    valida que a AUTOMACAO DE ONBOARDING em si deixa o sistema no estado
    esperado nos dois lados que ela integra:
      - Oracle: usuario criado, com o profile de seguranca certo, e com o
        grant de proxy correspondente ao perfil escolhido.
      - Vault: segredo de onboarding gravado e recuperavel, policy e login
        userpass criados.

    Limpa os dois lados ao final (Oracle: DROP USER; Vault: delete de policy,
    login userpass e segredos).
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [INTEGRACAO] Onboarding ponta a ponta (Oracle + Vault) ==" -ForegroundColor Cyan

$createScript = Join-Path $PSScriptRoot '..\..\scripts\create-team-member.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken = Get-VaultToken -EnvFile $EnvFile
$username = New-ThrowawayUsername -Prefix 'TST_E2E'
$results = @()

try {
    & $createScript -Username $username -Profile 'Desenvolvedor' -EnvFile $EnvFile *> $null

    # --- Lado Oracle -------------------------------------------------------
    $sqlOracle = @'
SET PAGESIZE 0
SET FEEDBACK OFF
SELECT 'PROFILE=' || profile FROM dba_users WHERE username = '__USER__';
SELECT 'PROXY_DEV=' || CASE WHEN EXISTS (
    SELECT 1 FROM proxy_users WHERE proxy = '__USER__' AND client = 'KAWASHI_ENV_DEV'
) THEN 'SIM' ELSE 'NAO' END FROM dual;
SELECT 'PROXY_HOMOLOG=' || CASE WHEN EXISTS (
    SELECT 1 FROM proxy_users WHERE proxy = '__USER__' AND client = 'KAWASHI_ENV_HOMOLOG'
) THEN 'SIM' ELSE 'NAO' END FROM dual;
EXIT;
'@ -replace '__USER__', $username
    $outOracle = (Invoke-SqlPlus -ConnectString $engineerConn -Sql $sqlOracle) -join "`n"

    $results += New-TestResult -Name "Usuario Oracle '$username' criado com PROFILE=KAWASHI_SECURE_PROFILE" -Passed ($outOracle -match 'PROFILE=KAWASHI_SECURE_PROFILE') -Details $(if ($outOracle -notmatch 'PROFILE=KAWASHI_SECURE_PROFILE') { $outOracle })
    $results += New-TestResult -Name "Proxy concedido para KAWASHI_ENV_DEV (perfil Desenvolvedor)" -Passed ($outOracle -match 'PROXY_DEV=SIM') -Details $(if ($outOracle -notmatch 'PROXY_DEV=SIM') { $outOracle })
    $results += New-TestResult -Name "Proxy concedido para KAWASHI_ENV_HOMOLOG (perfil Desenvolvedor)" -Passed ($outOracle -match 'PROXY_HOMOLOG=SIM') -Details $(if ($outOracle -notmatch 'PROXY_HOMOLOG=SIM') { $outOracle })

    # --- Lado Vault ----------------------------------------------------------
    $kvJson = (docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv get -format=json "kawashi-secrets/onboarding/$username" 2>&1) -join "`n"
    $kvObj = $kvJson | ConvertFrom-Json -ErrorAction SilentlyContinue
    $results += New-TestResult -Name "Segredo de onboarding gravado e legivel em kawashi-secrets/onboarding/$username" -Passed ([bool]$kvObj.data.data.db_password) -Details $(if (-not $kvObj.data.data.db_password) { $kvJson })

    $policyList = (docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault policy list 2>&1) -join "`n"
    $policyName = "engineer-$($username.ToLower())"
    $results += New-TestResult -Name "Policy '$policyName' criada no Vault" -Passed ($policyList -match [regex]::Escape($policyName)) -Details $(if ($policyList -notmatch [regex]::Escape($policyName)) { $policyList })

    $authListJson = (docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault list -format=json "auth/userpass/users" 2>&1) -join "`n"
    $results += New-TestResult -Name "Login userpass '$username' criado no Vault" -Passed ($authListJson -match [regex]::Escape($username)) -Details $(if ($authListJson -notmatch [regex]::Escape($username)) { $authListJson })
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

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
