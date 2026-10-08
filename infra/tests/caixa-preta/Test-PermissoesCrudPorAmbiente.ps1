# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: confirma que um usuario proxyado num ambiente
    realmente tem permissao de LER E ESCREVER la (nao so "conseguir conectar"),
    e que os dados de um ambiente ficam ISOLADOS de outro ambiente - nenhum
    deles consegue enxergar o que o outro criou.

.DESCRIPTION
    Usa um usuario Desenvolvedor descartavel (proxy em DEV e HOMOLOG) para o
    ciclo de vida completo (CREATE/INSERT/SELECT/DROP) e um usuario Infra
    descartavel (proxy em INFRA e HOMOLOG) so pra confirmar que ele NAO
    enxerga a tabela criada pelo Dev em KAWASHI_ENV_DEV. So observa respostas
    de SQL (sucesso, ORA-00942 "table or view does not exist", etc.) - nunca
    consulta DBA_TAB_PRIVS ou qualquer catalogo pra decidir o resultado.

    Isso e um ensaio direto do criterio "preservacao do isolamento de dados
    entre organizacoes distintas" do Projeto de Pesquisa do TCC, aplicado aos
    5 ambientes de ciclo de vida que ja existem hoje (o isolamento entre
    EMPRESAS de verdade ainda depende do esquema multiempresa que sera
    construido no microsservico de autenticacao).
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [CAIXA-PRETA] CRUD completo + isolamento entre ambientes ==" -ForegroundColor Cyan

$createScript = Join-Path $PSScriptRoot '..\..\scripts\create-team-member.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken = Get-VaultToken -EnvFile $EnvFile
$results = @()
$createdUsers = @()
$tabelaDev = "TESTE_CRUD_$((New-ThrowawayUsername -Prefix '').TrimStart('_'))"

function Get-SenhaDefinitiva {
    param([string]$Username)
    $senha = New-StrongPassword -Length 16 -AvoidSubstring $Username
    $out = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nALTER USER $Username IDENTIFIED BY `"$senha`";`nEXIT;`n") -join "`n"
    if ($out -match 'ORA-\d{5}') { throw "Falha definindo senha definitiva de '$Username':`n$out" }
    return $senha
}

try {
    $devUser = New-ThrowawayUsername -Prefix 'TST_CRUD_DEV'
    $createdUsers += [PSCustomObject]@{ Username = $devUser }
    & $createScript -Username $devUser -Profile 'Desenvolvedor' -EnvFile $EnvFile *> $null
    $devPwd = Get-SenhaDefinitiva -Username $devUser
    $devProxy = "$devUser[KAWASHI_ENV_DEV]/$devPwd@//localhost:1521/FREEPDB1"

    $infraUser = New-ThrowawayUsername -Prefix 'TST_CRUD_INF'
    $createdUsers += [PSCustomObject]@{ Username = $infraUser }
    & $createScript -Username $infraUser -Profile 'Infra' -EnvFile $EnvFile *> $null
    $infraPwd = Get-SenhaDefinitiva -Username $infraUser
    $infraProxy = "$infraUser[KAWASHI_ENV_INFRA]/$infraPwd@//localhost:1521/FREEPDB1"

    # --- Ciclo de vida completo em DEV, como Desenvolvedor -------------------
    $outCreate = (Invoke-SqlPlus -ConnectString $devProxy -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nCREATE TABLE $tabelaDev (id NUMBER, nota VARCHAR2(50));`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Desenvolvedor consegue CREATE TABLE em DEV via proxy" -Passed ($outCreate -match 'Table created') -Details $(if ($outCreate -notmatch 'Table created') { $outCreate })

    $outInsert = (Invoke-SqlPlus -ConnectString $devProxy -Sql "INSERT INTO $tabelaDev VALUES (1, 'registro de teste');`nCOMMIT;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Desenvolvedor consegue INSERT na propria tabela em DEV" -Passed ($outInsert -match '1 row created') -Details $(if ($outInsert -notmatch '1 row created') { $outInsert })

    $outSelect = (Invoke-SqlPlus -ConnectString $devProxy -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT nota FROM $tabelaDev WHERE id = 1;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Desenvolvedor consegue SELECT de volta o que inseriu" -Passed ($outSelect -match 'registro de teste') -Details $(if ($outSelect -notmatch 'registro de teste') { $outSelect })

    # --- Isolamento: Infra (outro ambiente) NAO enxerga a tabela do Dev ------
    $outIsolamento = (Invoke-SqlPlus -ConnectString $infraProxy -Sql "SELECT * FROM KAWASHI_ENV_DEV.$tabelaDev;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Infra NAO consegue ler a tabela que o Dev criou em outro ambiente (ORA-00942)" -Passed ($outIsolamento -match 'ORA-00942') -Details $(if ($outIsolamento -notmatch 'ORA-00942') { $outIsolamento })

    # --- DROP no final, de volta pelo proprio Desenvolvedor -------------------
    $outDrop = (Invoke-SqlPlus -ConnectString $devProxy -Sql "DROP TABLE $tabelaDev;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Desenvolvedor consegue DROP da propria tabela em DEV" -Passed ($outDrop -match 'Table dropped') -Details $(if ($outDrop -notmatch 'Table dropped') { $outDrop })
}
finally {
    Write-Host "-> Limpando (garantindo que a tabela de teste nao sobra, mesmo se algum passo falhou)..."
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP TABLE KAWASHI_ENV_DEV.$tabelaDev;`nEXIT;`n" | Out-Null

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
