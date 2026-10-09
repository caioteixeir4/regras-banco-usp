# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA (achado arquitetural importante, nao um bug de
    codigo): confirma que, DENTRO do mesmo ambiente de ciclo de vida
    (TESTE_DEV, TESTE_INFRA, DEV, INFRA ou HOMOLOG), QUALQUER pessoa com
    acesso aquele ambiente pode alterar/apagar QUALQUER objeto la dentro -
    mesmo um criado por OUTRA pessoa - porque autenticacao por proxy faz todo
    mundo "virar" a MESMA identidade de schema (ex: KAWASHI_ENV_TESTE_DEV), e
    posse de objeto no Oracle e por SCHEMA, nao por pessoa.

.DESCRIPTION
    Pergunta que motivou este teste: "nao e por que o usuario criou a tabela
    que ele vai poder deletar ou fazer qualquer coisa nela - vai que pedimos
    pro estagiario criar uma tabela simples que sera usada em algum ponto do
    projeto, ele nao pode ter toda essa liberdade nunca". A resposta curta,
    confirmada aqui: hoje, QUALQUER estagiario de Dev proxyado em TESTE_DEV
    pode mexer livremente em QUALQUER tabela de TESTE_DEV, nao so na que ele
    mesmo criou - "dono do objeto" aqui e o AMBIENTE (schema
    KAWASHI_ENV_TESTE_DEV), nao a pessoa. Isso vale pros ambientes que usam
    proxy (TESTE_DEV/TESTE_INFRA/DEV/INFRA/HOMOLOG) por igual.

    Isto NAO e um bug nos scripts da Kawashi - e uma caracteristica de como o
    Oracle (e qualquer RDBMS tradicional) modela posse: dono de um objeto e
    sempre o SCHEMA que criou, nunca a sessao/pessoa que estava conectada na
    hora. Nao da pra "consertar" isso so revogando um privilegio - exigiria
    redesenhar o modelo (schema individual por pessoa com grants pontuais, em
    vez de schema compartilhado por ambiente via proxy), uma decisao de
    arquitetura que caberia a quem mantem o projeto tomar, nao a este teste.

    O fator que CONTEM esse risco hoje: ele fica limitado AO PROPRIO AMBIENTE
    - confirmado abaixo que o mesmo Estagiario continua sem acesso nenhum a
    DEV/INFRA/HOMOLOG/PROD (ja provado em outros testes, reafirmado aqui). Ou
    seja, "promover" algo de TESTE_DEV pra DEV/HOMOLOG (saindo do alcance de
    quem criou em TESTE_DEV) e, hoje, a unica protecao real contra esse tipo
    de perda - nao existe protecao DENTRO do mesmo ambiente.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [CAIXA-PRETA] Controle coletivo dentro do mesmo ambiente (achado arquitetural) ==" -ForegroundColor Cyan

$createScript = Join-Path $PSScriptRoot '..\..\scripts\create-team-member.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken = Get-VaultToken -EnvFile $EnvFile
$results = @()
$criadores = @()
$tabela = "TESTE_COLETIVO_$((New-ThrowawayUsername -Prefix '').TrimStart('_'))"

function Get-SenhaDefinitiva {
    param([string]$Username)
    $senha = New-StrongPassword -Length 16 -AvoidSubstring $Username
    $out = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nALTER USER $Username IDENTIFIED BY `"$senha`";`nEXIT;`n") -join "`n"
    if ($out -match 'ORA-\d{5}') { throw "Falha definindo senha definitiva de '$Username':`n$out" }
    return $senha
}

try {
    $estagiarioA = New-ThrowawayUsername -Prefix 'TST_COLA'
    $criadores += $estagiarioA
    & $createScript -Username $estagiarioA -Profile 'EstagiarioDev' -EnvFile $EnvFile *> $null
    $senhaA = Get-SenhaDefinitiva -Username $estagiarioA
    $proxyA = "$estagiarioA[KAWASHI_ENV_TESTE_DEV]/$senhaA@//localhost:1521/FREEPDB1"

    $estagiarioB = New-ThrowawayUsername -Prefix 'TST_COLB'
    $criadores += $estagiarioB
    & $createScript -Username $estagiarioB -Profile 'EstagiarioDev' -EnvFile $EnvFile *> $null
    $senhaB = Get-SenhaDefinitiva -Username $estagiarioB
    $proxyB = "$estagiarioB[KAWASHI_ENV_TESTE_DEV]/$senhaB@//localhost:1521/FREEPDB1"

    $outCreate = (Invoke-SqlPlus -ConnectString $proxyA -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nCREATE TABLE $tabela (id NUMBER);`nINSERT INTO $tabela VALUES (1);`nCOMMIT;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Estagiario A cria uma tabela em TESTE_DEV (fixture)" -Passed ($outCreate -match 'Table created') -Details $(if ($outCreate -notmatch 'Table created') { $outCreate })

    $outInsertB = (Invoke-SqlPlus -ConnectString $proxyB -Sql "INSERT INTO $tabela VALUES (2);`nCOMMIT;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "[CONFIRMADO - nao e bug] Estagiario B (OUTRA pessoa) CONSEGUE inserir na tabela que A criou - posse e do schema TESTE_DEV, nao de A" -Passed ($outInsertB -match '1 row created') -Details $(if ($outInsertB -notmatch '1 row created') { $outInsertB })

    $outDropB = (Invoke-SqlPlus -ConnectString $proxyB -Sql "DROP TABLE $tabela;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "[CONFIRMADO - nao e bug] Estagiario B (OUTRA pessoa) CONSEGUE apagar a tabela que A criou" -Passed ($outDropB -match 'Table dropped') -Details $(if ($outDropB -notmatch 'Table dropped') { $outDropB })

    # --- O fator de contencao: isso NAO escapa do ambiente TESTE_DEV ---------
    $outForaDoAmbiente = (Invoke-SqlPlus -ConnectString $proxyB -Sql "SELECT * FROM KAWASHI_ENV_DEV.QUALQUER_COISA;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Mesmo com controle total dentro de TESTE_DEV, Estagiario B continua SEM NENHUM acesso a DEV (ORA-01031/ORA-00942) - o risco fica contido ao proprio ambiente" -Passed ($outForaDoAmbiente -match 'ORA-01031|ORA-00942') -Details $(if ($outForaDoAmbiente -notmatch 'ORA-01031|ORA-00942') { $outForaDoAmbiente })
}
finally {
    Write-Host "-> Limpando (a tabela ja foi derrubada pelo proprio teste) usuarios descartaveis e artefatos no Vault..."
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP TABLE KAWASHI_ENV_TESTE_DEV.$tabela;`nEXIT;`n" | Out-Null
    foreach ($u in $criadores) {
        Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $u CASCADE;`nEXIT;`n" | Out-Null
        $policyName = "engineer-$($u.ToLower())"
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault policy delete $policyName 2>&1 | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault delete "auth/userpass/users/$u" 2>&1 | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv delete "kawashi-secrets/onboarding/$u" 2>&1 | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv delete "kawashi-secrets/engineers/$u" 2>&1 | Out-Null
    }
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
