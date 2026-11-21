# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: rotate-api-password.ps1 troca a senha de uma conta de API no Oracle, no
    Vault e no .env da API, sem derrubar quem ainda usa a antiga, e sem mostrar a senha.

.DESCRIPTION
    Cria uma conta de API com um .env de teste e confere, por fora:
      - depois da troca, a senha do Vault e a do .env sao a mesma, e diferente da antiga;
      - so a linha da senha mudou no .env;
      - durante a troca gradual a antiga E a nova entram (a API rodando nao cai), e o painel mostra a
        pendencia; uma segunda troca no meio e recusada;
      - -EncerrarSenhaAntiga: a antiga para de entrar, a nova continua, a pendencia some;
      - -Imediata: a antiga para na hora;
      - Vault reiniciado (segredo sumiu): a troca grava o segredo de novo, completo;
      - recusas: .env de outra conta (e nada e trocado), conta de pessoa;
      - nenhuma senha aparece na saida do script.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
# O Vault escreve no stderr quando um segredo nao existe, o que e esperado em parte dos casos.
$ErrorActionPreference = 'Continue'

Write-Host "== [CAIXA-PRETA] Troca da senha da conta de API sem derrubar a aplicacao ==" -ForegroundColor Cyan

$scripts    = Join-Path $PSScriptRoot '..\..\scripts'
$createApi  = Join-Path $scripts 'create-api-account.ps1'
$createTeam = Join-Path $scripts 'create-team-member.ps1'
$rotate     = Join-Path $scripts 'rotate-api-password.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken   = Get-VaultToken -EnvFile $EnvFile
$results = @()
$api = $null; $outraApi = $null; $pessoa = $null
$pasta = Join-Path $env:TEMP ("kawashi-rot-" + (Get-Random -Maximum 999999))
New-Item -ItemType Directory -Path $pasta | Out-Null
$envApi = Join-Path $pasta 'api.env'
$envOutra = Join-Path $pasta 'outra.env'

function Invoke-Rotate {
    param([string]$Argumentos)
    $cmd = "& '$rotate' $Argumentos -EnvFile '$EnvFile'"
    $saida = (powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return [pscustomobject]@{ Codigo = $LASTEXITCODE; Saida = $saida }
}

function Get-SenhaNoVault {
    param([string]$Conta)
    $argCampo = '-field=db_password'
    return ((docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv get $argCampo "kawashi-secrets/api/$Conta" 2>$null) -join '').Trim()
}

function Get-DoEnv {
    param([string]$Arquivo, [string]$Chave)
    foreach ($l in [IO.File]::ReadAllLines($Arquivo)) { $p = $l.Split('=', 2); if ($p.Count -eq 2 -and $p[0].Trim() -eq $Chave) { return $p[1].Trim() } }
    return $null
}

function Test-Entra {
    param([string]$Conta, [string]$Senha)
    $out = (Invoke-SqlPlus -ConnectString "$Conta/$Senha@//localhost:1521/FREEPDB1" -Sql "SELECT 'ENTROU' FROM dual;`nEXIT;`n") -join ' '
    return ($out -match 'ENTROU')
}

function Get-Pendencia {
    param([string]$Conta)
    $out = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nALTER SESSION SET CONTAINER = FREEPDB1;`nSELECT 'P=' || NVL(PENDENCIA, '-') || '|S=' || SITUACAO_DA_SENHA FROM SYS.V_KAWASHI_CONTAS WHERE USERNAME = '$Conta';`nEXIT;`n") -join ' '
    return $out.Trim()
}

try {
    $api = New-ThrowawayUsername -Prefix 'TST_ROTA'
    $outraApi = New-ThrowawayUsername -Prefix 'TST_ROTB'
    & $createApi -Username $api -Ambiente 'TESTE_INFRA' -OutEnvFile $envApi -EnvFile $EnvFile *> $null
    & $createApi -Username $outraApi -Ambiente 'TESTE_INFRA' -OutEnvFile $envOutra -EnvFile $EnvFile *> $null
    # Uma linha a mais, que a troca nao pode mexer.
    Add-Content -Path $envApi -Value 'OUTRA_CONFIG=valor-que-nao-muda' -Encoding ASCII
    $antigas = [IO.File]::ReadAllLines($envApi)
    $senhaAntiga = Get-DoEnv $envApi 'DB_PASSWORD'

    $results += New-TestResult -Name "Precondicao: a conta de API entra com a senha que esta no .env" -Passed (Test-Entra $api $senhaAntiga) -Details ''

    # --- a troca -------------------------------------------------------------------
    $r = Invoke-Rotate "-Username $api -OutEnvFile '$envApi'"
    $senhaNova = Get-DoEnv $envApi 'DB_PASSWORD'
    $results += New-TestResult -Name "A troca termina com sucesso e o .env passa a ter uma senha nova, diferente da antiga" -Passed (($r.Codigo -eq 0) -and $senhaNova -and ($senhaNova -ne $senhaAntiga)) -Details "codigo=$($r.Codigo)`n$($r.Saida)"

    $results += New-TestResult -Name "A senha do Vault e a mesma do .env (as duas copias foram trocadas juntas)" -Passed ((Get-SenhaNoVault $api) -eq $senhaNova) -Details ''

    $novas = [IO.File]::ReadAllLines($envApi)
    $diferentes = @(0..([Math]::Max($antigas.Count, $novas.Count) - 1) | Where-Object { $antigas[$_] -ne $novas[$_] })
    $results += New-TestResult -Name "No .env so a linha DB_PASSWORD mudou; as outras (inclusive uma que a API nao conhece) ficaram iguais" -Passed (($novas.Count -eq $antigas.Count) -and ($diferentes.Count -eq 1) -and ($novas[$diferentes[0]] -like 'DB_PASSWORD=*')) -Details "linhas diferentes: $($diferentes -join ',')"

    $results += New-TestResult -Name "Nenhuma senha (nem a antiga nem a nova) aparece na saida do script" -Passed (($r.Saida -notmatch [regex]::Escape($senhaNova)) -and ($r.Saida -notmatch [regex]::Escape($senhaAntiga))) -Details ''

    # --- troca gradual: a API que esta rodando nao cai ---------------------------------
    $results += New-TestResult -Name "Durante a troca gradual a senha ANTIGA ainda entra (a API que esta rodando nao cai) e a nova tambem" -Passed ((Test-Entra $api $senhaAntiga) -and (Test-Entra $api $senhaNova)) -Details ''

    $p = Get-Pendencia $api
    $results += New-TestResult -Name "O painel mostra a pendencia 'senha antiga ainda vale' enquanto a troca nao e encerrada, com a senha EM DIA" -Passed (($p -match 'senha antiga ainda vale') -and ($p -match 'S=EM DIA')) -Details $p

    $r2 = Invoke-Rotate "-Username $api -OutEnvFile '$envApi'"
    $results += New-TestResult -Name "Uma segunda troca no meio da primeira e recusada, e o .env nao muda" -Passed (($r2.Codigo -ne 0) -and ($r2.Saida -match 'troca em andamento') -and ((Get-DoEnv $envApi 'DB_PASSWORD') -eq $senhaNova)) -Details "codigo=$($r2.Codigo)`n$($r2.Saida)"

    # --- encerrar a antiga -------------------------------------------------------------
    $r3 = Invoke-Rotate "-Username $api -EncerrarSenhaAntiga"
    $p = Get-Pendencia $api
    $results += New-TestResult -Name "-EncerrarSenhaAntiga: a antiga para de entrar, a nova continua, e a pendencia some" -Passed (($r3.Codigo -eq 0) -and -not (Test-Entra $api $senhaAntiga) -and (Test-Entra $api $senhaNova) -and ($p -match 'P=-')) -Details "codigo=$($r3.Codigo) $p`n$($r3.Saida)"

    # --- -Imediata e Vault reiniciado ----------------------------------------------------
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv metadata delete "kawashi-secrets/api/$api" 2>&1 | Out-Null
    $r4 = Invoke-Rotate "-Username $api -OutEnvFile '$envApi' -Imediata"
    $senhaImediata = Get-DoEnv $envApi 'DB_PASSWORD'
    $results += New-TestResult -Name "-Imediata: a senha anterior para de entrar na hora e so a nova entra" -Passed (($r4.Codigo -eq 0) -and -not (Test-Entra $api $senhaNova) -and (Test-Entra $api $senhaImediata)) -Details "codigo=$($r4.Codigo)`n$($r4.Saida)"

    $argCampo = '-field=jdbc_user'
    $jdbc = ((docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv get $argCampo "kawashi-secrets/api/$api" 2>$null) -join '').Trim()
    $results += New-TestResult -Name "Com o segredo sumido do Vault (Vault reiniciado), a troca grava o segredo de novo, completo (senha e usuario JDBC)" -Passed (((Get-SenhaNoVault $api) -eq $senhaImediata) -and ($jdbc -eq "$api[KAWASHI_ENV_TESTE_INFRA_APP]")) -Details "jdbc_user=$jdbc"

    # --- recusas -------------------------------------------------------------------------
    $vaultAntes = Get-SenhaNoVault $api
    $r5 = Invoke-Rotate "-Username $api -OutEnvFile '$envOutra'"
    $results += New-TestResult -Name "Um .env de OUTRA conta e recusado antes de trocar: a senha da conta, o Vault e os dois .env continuam iguais" -Passed (($r5.Codigo -ne 0) -and ($r5.Saida -match 'nao e desta conta') -and (Test-Entra $api $senhaImediata) -and ((Get-SenhaNoVault $api) -eq $vaultAntes) -and ((Get-DoEnv $envApi 'DB_PASSWORD') -eq $senhaImediata)) -Details "codigo=$($r5.Codigo)`n$($r5.Saida)"

    $pessoa = New-ThrowawayUsername -Prefix 'TST_ROTP'
    & $createTeam -Username $pessoa -Profile 'EstagiarioDev' -Nome 'Pessoa' -Cargo 'Teste' -EnvFile $EnvFile *> $null
    $r6 = Invoke-Rotate "-Username $pessoa"
    $results += New-TestResult -Name "Conta de pessoa e recusada (a senha dela e trocada por ela mesma)" -Passed (($r6.Codigo -ne 0) -and ($r6.Saida -match 'nao e de API')) -Details "codigo=$($r6.Codigo)`n$($r6.Saida)"
}
finally {
    Write-Host "-> Limpando: contas de teste, segredos e arquivos temporarios..."
    foreach ($u in @($api, $outraApi, $pessoa)) {
        if (-not $u) { continue }
        Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $u CASCADE;`nEXIT;`n" | Out-Null
        Invoke-SqlPlus -ConnectString '/ as sysdba' -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDELETE FROM SYS.KAWASHI_CONTA WHERE USERNAME = '$u' AND USERNAME LIKE 'TST\_%' ESCAPE '\';`nCOMMIT;`nEXIT;`n" | Out-Null
        foreach ($a in @(@('kv', 'metadata', 'delete', "kawashi-secrets/api/$u"), @('kv', 'metadata', 'delete', "kawashi-secrets/onboarding/$u"),
                         @('delete', "auth/userpass/users/$u"), @('policy', 'delete', "engineer-$($u.ToLower())"))) {
            docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault @a 2>&1 | Out-Null
        }
    }
    Remove-Item -Recurse -Force $pasta -ErrorAction SilentlyContinue
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
