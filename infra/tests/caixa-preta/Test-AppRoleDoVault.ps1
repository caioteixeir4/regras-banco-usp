# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: o papel AppRole de cada aplicacao (criar-approle.ps1) so le os segredos
    dela, no ambiente dela, e nao escreve nada.

.DESCRIPTION
    No Vault de verdade (conteiner kawashi-vault), ambiente TESTE_INFRA:
      - criar-approle.ps1 cria o papel e a politica do BFF e da API (sem -Ligar: nao mexe em .env);
      - entrando com o papel do BFF: le kawashi-secrets/bff/TESTE_INFRA; NAO le as chaves de cifra,
        nem o segredo de outro ambiente, nem a senha de conta nenhuma; NAO escreve;
      - entrando com o papel da API: le cifra, bff e a senha das DUAS contas informadas; NAO le a
        senha de outra conta nem o segredo de outro ambiente;
      - o token do papel dura no maximo 5 minutos.
    Os segredos de teste sao criados e apagados pelo teste (valores aleatorios, nunca mostrados).
#>
[CmdletBinding()]
param(
    [string]$EnvFile
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Continue'
if (-not $EnvFile) { $EnvFile = Join-Path $PSScriptRoot '..\..\.env' }

Write-Host "== [CAIXA-PRETA] AppRole do Vault: cada aplicacao so le o que e dela ==" -ForegroundColor Cyan

$criar = Join-Path $PSScriptRoot '..\..\scripts\criar-approle.ps1'
$VaultToken = Get-VaultToken -EnvFile $EnvFile
$results = @()
$sufixo = Get-Random -Maximum 999999
$exec = "TST_ARE_$sufixo"
$mig = "TST_ARM_$sufixo"
$outra = "TST_ARO_$sufixo"
$criados = @("bff/TESTE_INFRA", "cifra/TESTE_INFRA", "bff/TESTE_DEV_X$sufixo", "api/$exec", "api/$mig", "api/$outra")
$jaExistiam = @()

function Invoke-VaultRoot {
    param([string]$Comando)
    $env:VAULT_TOKEN = $VaultToken
    try { return ((docker exec -e VAULT_TOKEN kawashi-vault sh -c $Comando 2>&1 | ForEach-Object { "$_" }) -join "`n") }
    finally { Remove-Item Env:\VAULT_TOKEN -ErrorAction SilentlyContinue }
}
function Get-TokenDoPapel {
    param([string]$Papel)
    $roleId = (Invoke-VaultRoot "vault read -field=role_id auth/approle/role/$Papel/role-id").Trim()
    $secretId = (Invoke-VaultRoot "vault write -f -field=secret_id auth/approle/role/$Papel/secret-id").Trim()
    $env:KW_ROLE = $roleId; $env:KW_SECRET = $secretId
    try { return ((docker exec -e KW_ROLE -e KW_SECRET kawashi-vault sh -c 'vault write -field=token auth/approle/login role_id=$KW_ROLE secret_id=$KW_SECRET' 2>&1) -join '').Trim() }
    finally { Remove-Item Env:\KW_ROLE, Env:\KW_SECRET -ErrorAction SilentlyContinue }
}
function Invoke-ComoPapel {
    param([string]$Token, [string]$Comando)
    $env:VAULT_TOKEN = $Token
    try { return ((docker exec -e VAULT_TOKEN kawashi-vault sh -c $Comando 2>&1 | ForEach-Object { "$_" }) -join "`n") }
    finally { Remove-Item Env:\VAULT_TOKEN -ErrorAction SilentlyContinue }
}
function Test-Le {
    param([string]$Token, [string]$Caminho)
    $s = Invoke-ComoPapel $Token "vault kv get kawashi-secrets/$Caminho >/dev/null 2>&1 && echo LEU || echo NEGADO"
    return ($s -match 'LEU')
}

try {
    # Segredos de teste so onde ainda nao ha nada: os de verdade nao sao tocados (nem lidos para a tela).
    foreach ($c in $criados) {
        $existe = Invoke-VaultRoot "vault kv get kawashi-secrets/$c >/dev/null 2>&1 && echo SIM || echo NAO"
        if ($existe -match 'SIM') { $jaExistiam += $c }
        else { Invoke-VaultRoot "vault kv put kawashi-secrets/$c marca=teste-$sufixo" | Out-Null }
    }

    $saidaBff = (& powershell -NoProfile -ExecutionPolicy Bypass -File $criar -Aplicacao bff -Ambiente TESTE_INFRA -EnvFile $EnvFile 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $saidaApi = (& powershell -NoProfile -ExecutionPolicy Bypass -File $criar -Aplicacao api -Ambiente TESTE_INFRA -ContaExecucao $exec -ContaMigracao $mig -EnvFile $EnvFile 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $results += New-TestResult -Name "criar-approle.ps1 cria os papeis kawashi-bff-teste-infra (1 caminho) e kawashi-api-teste-infra (4 caminhos), sem mexer em .env (sem -Ligar)" -Passed (($saidaBff -match 'kawashi-bff-teste-infra pronto: so le 1 caminho') -and ($saidaApi -match 'kawashi-api-teste-infra pronto: so le 4 caminho') -and ($saidaBff -match 'ainda NAO usa')) -Details "$saidaBff`n$saidaApi"

    $tBff = Get-TokenDoPapel 'kawashi-bff-teste-infra'
    $bffLe = Test-Le $tBff 'bff/TESTE_INFRA'
    $bffNao = @('cifra/TESTE_INFRA', "bff/TESTE_DEV_X$sufixo", "api/$exec") | Where-Object { Test-Le $tBff $_ }
    # So tenta escrever onde o proprio teste criou o segredo: se a politica falhasse, nada de verdade seria sobrescrito.
    $bffEscreve = if ($jaExistiam -contains 'bff/TESTE_INFRA') { 'NEGADO (nao testado: segredo real)' } else { Invoke-ComoPapel $tBff "vault kv put kawashi-secrets/bff/TESTE_INFRA marca=sobrescrito >/dev/null 2>&1 && echo ESCREVEU || echo NEGADO" }
    $results += New-TestResult -Name "Papel do BFF: le o proprio segredo; NAO le chave de cifra, segredo de outro ambiente nem senha de conta; NAO escreve" -Passed ($tBff -and $bffLe -and (@($bffNao).Count -eq 0) -and ($bffEscreve -match 'NEGADO')) -Details "le=$bffLe lidos-indevidos=$($bffNao -join ',') escrita=$bffEscreve"

    $tApi = Get-TokenDoPapel 'kawashi-api-teste-infra'
    $apiLe = @('cifra/TESTE_INFRA', 'bff/TESTE_INFRA', "api/$exec", "api/$mig") | Where-Object { -not (Test-Le $tApi $_) }
    $apiNao = @("api/$outra", "bff/TESTE_DEV_X$sufixo") | Where-Object { Test-Le $tApi $_ }
    $results += New-TestResult -Name "Papel da API: le cifra, bff e a senha das DUAS contas dela; NAO le a senha de outra conta nem o segredo de outro ambiente" -Passed ($tApi -and (@($apiLe).Count -eq 0) -and (@($apiNao).Count -eq 0)) -Details "nao-leu=$($apiLe -join ',') lidos-indevidos=$($apiNao -join ',')"

    $ttl = Invoke-ComoPapel $tApi 'vault token lookup -format=json'
    $segundos = [int]([regex]::Match($ttl, '"ttl":\s*(\d+)').Groups[1].Value)
    $results += New-TestResult -Name "O token do papel dura no maximo 5 minutos (so serve para a subida da aplicacao)" -Passed ($segundos -gt 0 -and $segundos -le 300) -Details "ttl=$segundos s"
}
finally {
    Write-Host "-> Limpando: segredos de teste e papeis de teste..."
    foreach ($c in $criados) {
        if ($jaExistiam -notcontains $c) { Invoke-VaultRoot "vault kv metadata delete kawashi-secrets/$c" | Out-Null }
    }
    foreach ($p in 'kawashi-bff-teste-infra', 'kawashi-api-teste-infra') {
        Invoke-VaultRoot "vault delete auth/approle/role/$p" | Out-Null
        Invoke-VaultRoot "vault policy delete $p" | Out-Null
    }
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
