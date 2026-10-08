# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: confirma a distincao documentada em
    infra/oracle-init/01_setup_kawashi.sql para ROLE_KAWASHI_INFRA -
    SELECT ANY DICTIONARY da acesso a ESTRUTURA (quais tabelas existem, em
    qual schema) mas NAO ao CONTEUDO (os dados dentro delas).

.DESCRIPTION
    Cria uma tabela com um dado sensivel (via Desenvolvedor proxyado em DEV,
    fluxo real) e usa um usuario Infra descartavel para: (1) confirmar que ele
    ENXERGA a existencia da tabela via DBA_TABLES/ALL_TABLES (metadado), e (2)
    confirmar que ele NAO consegue ler o conteudo dela com um SELECT direto
    (teria que receber um GRANT SELECT objeto a objeto pra isso, que ninguem
    deu). So observa respostas de SQL - a consulta a DBA_TABLES e o PROPRIO
    comportamento sob teste aqui (e nao uma forma de decidir o resultado por
    fora, como caixa-branca faria).
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [CAIXA-PRETA] Infra ve metadado mas nao conteudo de tabelas alheias ==" -ForegroundColor Cyan

$createScript = Join-Path $PSScriptRoot '..\..\scripts\create-team-member.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$results = @()
$createdUsers = @()
$tabela = "TESTE_META_$((New-ThrowawayUsername -Prefix '').TrimStart('_'))"

function Get-SenhaDefinitiva {
    param([string]$Username)
    $senha = New-StrongPassword -Length 16 -AvoidSubstring $Username
    $out = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nALTER USER $Username IDENTIFIED BY `"$senha`";`nEXIT;`n") -join "`n"
    if ($out -match 'ORA-\d{5}') { throw "Falha definindo senha definitiva de '$Username':`n$out" }
    return $senha
}

try {
    $devUser = New-ThrowawayUsername -Prefix 'TST_META_DEV'
    $createdUsers += [PSCustomObject]@{ Username = $devUser }
    & $createScript -Username $devUser -Profile 'Desenvolvedor' -EnvFile $EnvFile *> $null
    $devPwd = Get-SenhaDefinitiva -Username $devUser
    $devProxy = "$devUser[KAWASHI_ENV_DEV]/$devPwd@//localhost:1521/FREEPDB1"
    Invoke-SqlPlus -ConnectString $devProxy -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nCREATE TABLE $tabela (segredo VARCHAR2(50));`nINSERT INTO $tabela VALUES ('DADO_CONFIDENCIAL_XYZ');`nCOMMIT;`nEXIT;`n" | Out-Null

    $infraUser = New-ThrowawayUsername -Prefix 'TST_META_INF'
    $createdUsers += [PSCustomObject]@{ Username = $infraUser }
    & $createScript -Username $infraUser -Profile 'Infra' -EnvFile $EnvFile *> $null
    $infraPwd = Get-SenhaDefinitiva -Username $infraUser
    $infraConn = "$infraUser/$infraPwd@//localhost:1521/FREEPDB1"

    $outMetadado = (Invoke-SqlPlus -ConnectString $infraConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT owner FROM DBA_TABLES WHERE table_name = '$tabela';`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Infra ENXERGA (metadado) que a tabela existe em KAWASHI_ENV_DEV, via DBA_TABLES" -Passed ($outMetadado -match 'KAWASHI_ENV_DEV') -Details $(if ($outMetadado -notmatch 'KAWASHI_ENV_DEV') { $outMetadado })

    # Oracle responde "ORA-00942: table or view does not exist" (nao ORA-01031)
    # quando falta SELECT numa tabela especifica - esconde de proposito se o
    # problema foi "nao existe" ou "existe mas voce nao pode ver", igual ja
    # confirmado em Test-PermissoesCrudPorAmbiente.ps1.
    $outConteudo = (Invoke-SqlPlus -ConnectString $infraConn -Sql "SELECT * FROM KAWASHI_ENV_DEV.$tabela;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Infra NAO consegue ler o CONTEUDO da mesma tabela (ORA-00942 - sem GRANT SELECT objeto a objeto)" -Passed ($outConteudo -match 'ORA-00942') -Details $(if ($outConteudo -notmatch 'ORA-00942') { $outConteudo })
}
finally {
    Write-Host "-> Limpando tabela de teste, usuarios descartaveis e artefatos no Vault..."
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP TABLE KAWASHI_ENV_DEV.$tabela;`nEXIT;`n" | Out-Null
    $VaultToken = Get-VaultToken -EnvFile $EnvFile
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
