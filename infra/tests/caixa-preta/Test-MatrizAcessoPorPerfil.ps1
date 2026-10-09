# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: valida a matriz de acesso por perfil (EstagiarioDev,
    EstagiarioInfra, Desenvolvedor, Infra, HomologViewer) documentada em
    infra/oracle-init/09_environments.sql, observando SOMENTE login/proxy
    aceito ou negado - nunca consulta DBA_TAB_PRIVS, PROXY_USERS ou qualquer
    outra tabela de catalogo para decidir o resultado.

.DESCRIPTION
    E essencialmente um ensaio automatizado dos "cenarios controlados de
    acesso legitimo e de tentativas de acesso nao autorizado" descritos no
    Projeto de Pesquisa do TCC: para cada perfil, cria um usuario descartavel
    de verdade via infra/scripts/create-team-member.ps1 (o mesmo script usado
    em producao - nao reimplementa a logica de GRANT aqui, para o teste nunca
    divergir do que o onboarding real faz), recupera a senha temporaria do
    proprio Vault (onde o onboarding a guarda) e tenta autenticar via PROXY em
    cada um dos 6 ambientes. Ao final, remove os usuarios Oracle e os
    artefatos criados no Vault (policy, login userpass, segredos).

.NOTES
    CORRIGIDO (achado rodando este teste pela primeira vez): toda conta nova
    sai do create-team-member.ps1 com "PASSWORD EXPIRE" (de proposito - forca
    a pessoa a escolher a propria senha definitiva, ver infra/docs/onboarding-novo-membro.md
    Passo 3). O Oracle, porem, REJEITA login via PROXY com senha expirada
    (ORA-28013) - diferente de um login direto, nao existe negociacao
    interativa de "troca de senha" no meio de uma conexao de proxy. Isso nao e
    um bug do sistema: e exatamente por isso que o onboarding real exige login
    DIRETO (Passo 3) antes de qualquer uso de ambiente via proxy. Este teste
    simula esse primeiro-login-obrigatorio definindo uma senha definitiva via
    ENGINEER_USER logo apos a criacao, antes de tentar qualquer proxy.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [CAIXA-PRETA] Matriz de acesso por perfil (proxy authentication) ==" -ForegroundColor Cyan

$createScript = Join-Path $PSScriptRoot '..\..\scripts\create-team-member.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken = Get-VaultToken -EnvFile $EnvFile

$environments = 'TESTE_DEV', 'TESTE_INFRA', 'DEV', 'INFRA', 'HOMOLOG', 'PROD'
# Matriz esperada - ver racional completo nos comentarios da secao 3 de
# infra/oracle-init/09_environments.sql. TESTE_DEV/TESTE_INFRA sao a divisao
# do antigo ambiente TESTE unico por time (ver item correspondente de
# bugs-primeiro-teste.md).
$matrizEsperada = [ordered]@{
    'EstagiarioDev'   = @{ TESTE_DEV = $true;  TESTE_INFRA = $false; DEV = $false; INFRA = $false; HOMOLOG = $false; PROD = $false }
    'EstagiarioInfra' = @{ TESTE_DEV = $false; TESTE_INFRA = $true;  DEV = $false; INFRA = $false; HOMOLOG = $false; PROD = $false }
    'Desenvolvedor'   = @{ TESTE_DEV = $false; TESTE_INFRA = $false; DEV = $true;  INFRA = $false; HOMOLOG = $true;  PROD = $false }
    'Infra'           = @{ TESTE_DEV = $false; TESTE_INFRA = $false; DEV = $false; INFRA = $true;  HOMOLOG = $true;  PROD = $false }
    'HomologViewer'   = @{ TESTE_DEV = $false; TESTE_INFRA = $false; DEV = $false; INFRA = $false; HOMOLOG = $false; PROD = $false }
}

$results = @()
$createdUsers = @()

try {
    foreach ($profile in $matrizEsperada.Keys) {
        # CORRIGIDO: com EstagiarioDev/EstagiarioInfra, os primeiros 4
        # caracteres ("ESTA") colidiam entre os dois - usa o nome completo do
        # perfil (ainda cabe dentro do limite de 30 caracteres do username
        # Oracle, mesmo com o sufixo aleatorio de New-ThrowawayUsername).
        $prefixo = "TST_$($profile.ToUpper())"
        $username = New-ThrowawayUsername -Prefix $prefixo
        Write-Host "-> Criando usuario descartavel '$username' (perfil $profile) via create-team-member.ps1..."
        # Registrado ANTES de chamar o script: create-team-member.ps1 cria o
        # usuario Oracle no primeiro passo e so DEPOIS mexe no Vault - se a
        # parte do Vault falhar, o usuario Oracle ja existe e precisa ser
        # limpo no finally mesmo assim (achado ao vivo: uma falha no Vault por
        # falta do engine/auth method, nao relacionada a este teste, deixou um
        # usuario orfao porque esta linha so rodava DEPOIS da chamada).
        $createdUsers += [PSCustomObject]@{ Username = $username; Profile = $profile }
        & $createScript -Username $username -Profile $profile -EnvFile $EnvFile *> $null

        $kvJson = (docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv get -format=json "kawashi-secrets/onboarding/$username" 2>&1) -join "`n"
        $tempPassword = ($kvJson | ConvertFrom-Json).data.data.db_password
        if (-not $tempPassword) { throw "Nao consegui recuperar a senha temporaria de '$username' no Vault. Saida: $kvJson" }

        # Simula o "Passo 3" obrigatorio do onboarding (ver .NOTES acima): sem
        # isto, toda tentativa de proxy falharia com ORA-28013 por senha
        # expirada, nao pela regra de acesso que este teste quer validar.
        $senhaDefinitiva = New-StrongPassword -Length 16 -AvoidSubstring $username
        $outTrocaSenha = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nALTER USER $username IDENTIFIED BY `"$senhaDefinitiva`";`nEXIT;`n") -join "`n"
        if ($outTrocaSenha -match 'ORA-\d{5}') { throw "Falha simulando a troca de senha obrigatoria de '$username':`n$outTrocaSenha" }

        foreach ($env in $environments) {
            $schemaAlvo = "KAWASHI_ENV_$env"
            $connectString = "$username[$schemaAlvo]/$senhaDefinitiva@//localhost:1521/FREEPDB1"
            $output = (Invoke-SqlPlus -ConnectString $connectString -Sql "SELECT SYS_CONTEXT('USERENV','SESSION_USER') FROM DUAL;`nEXIT;`n") -join "`n"
            $sucesso = ($output -match [regex]::Escape($schemaAlvo)) -and ($output -notmatch 'ORA-\d{5}')
            $esperado = $matrizEsperada[$profile][$env]
            $passou = ($sucesso -eq $esperado)
            $rotulo = if ($esperado) { 'deveria ter acesso' } else { 'NAO deveria ter acesso' }
            $detalhe = if ($passou) { '' } else { "esperado=$esperado observado=$sucesso; saida:`n$output" }
            $results += New-TestResult -Name "Perfil $profile -> ambiente $env ($rotulo)" -Passed $passou -Details $detalhe
        }
    }
}
finally {
    Write-Host "-> Limpando usuarios descartaveis e artefatos no Vault..."
    foreach ($u in $createdUsers) {
        Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $($u.Username) CASCADE;`nEXIT;`n" | Out-Null
        $policyName = "engineer-$($u.Username.ToLower())"
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault policy delete $policyName 2>&1 | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault delete "auth/userpass/users/$($u.Username)" 2>&1 | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv delete "kawashi-secrets/onboarding/$($u.Username)" 2>&1 | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv delete "kawashi-secrets/engineers/$($u.Username)" 2>&1 | Out-Null
    }
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
