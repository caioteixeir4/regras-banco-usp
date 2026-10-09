# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: confirma que o perfil HomologViewer e REALMENTE
    somente-leitura - consegue SELECT numa tabela existente de Homologacao,
    mas nao consegue INSERT/UPDATE/DELETE nela, nem CREATE TABLE em canto
    nenhum (nem no proprio schema, nem em Homologacao).

.DESCRIPTION
    Antes deste teste, so validavamos que o HomologViewer nao tem proxy pra
    lugar nenhum (Test-MatrizAcessoPorPerfil.ps1). Isso prova a AUSENCIA de
    proxy, mas nao prova a PRESENCA do acesso de leitura que e o proprio
    motivo do perfil existir - alguem podia ter quebrado o
    ROLE_KAWASHI_HOMOLOG_VIEWER (por exemplo, revogado o SELECT por engano) e
    nenhum teste existente acusaria isso. Cria uma tabela descartavel em
    KAWASHI_ENV_HOMOLOG (via um Desenvolvedor proxyado, do mesmo jeito que
    aconteceria na vida real) e usa um HomologViewer descartavel para tentar
    ler e escrever nela, direto (sem proxy - este perfil nunca usa proxy).
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [CAIXA-PRETA] HomologViewer e realmente somente-leitura ==" -ForegroundColor Cyan

$createScript = Join-Path $PSScriptRoot '..\..\scripts\create-team-member.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken = Get-VaultToken -EnvFile $EnvFile
$results = @()
$createdUsers = @()
$tabela = "TESTE_RO_$((New-ThrowawayUsername -Prefix '').TrimStart('_'))"

function Get-SenhaDefinitiva {
    param([string]$Username)
    $senha = New-StrongPassword -Length 16 -AvoidSubstring $Username
    $out = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nALTER USER $Username IDENTIFIED BY `"$senha`";`nEXIT;`n") -join "`n"
    if ($out -match 'ORA-\d{5}') { throw "Falha definindo senha definitiva de '$Username':`n$out" }
    return $senha
}

try {
    # Fixture: uma tabela real em HOMOLOG, criada do jeito que aconteceria na
    # pratica (Dev proxyado), com uma linha dentro pra ter algo pra ler.
    $devUser = New-ThrowawayUsername -Prefix 'TST_RO_DEV'
    $createdUsers += [PSCustomObject]@{ Username = $devUser }
    & $createScript -Username $devUser -Profile 'Desenvolvedor' -EnvFile $EnvFile *> $null
    $devPwd = Get-SenhaDefinitiva -Username $devUser
    $devProxy = "$devUser[KAWASHI_ENV_HOMOLOG]/$devPwd@//localhost:1521/FREEPDB1"
    Invoke-SqlPlus -ConnectString $devProxy -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nCREATE TABLE $tabela (id NUMBER, nota VARCHAR2(50));`nINSERT INTO $tabela VALUES (1, 'dado de homologacao');`nCOMMIT;`nEXIT;`n" | Out-Null

    # Da tempo do job assincrono do trigger de auto-grant conceder o SELECT ao
    # QA (ver Test-HomologAutograntTrigger.ps1 e item 8 de bugs-primeiro-teste.md).
    Start-Sleep -Seconds 3

    $qaUser = New-ThrowawayUsername -Prefix 'TST_RO_QA'
    $createdUsers += [PSCustomObject]@{ Username = $qaUser }
    & $createScript -Username $qaUser -Profile 'HomologViewer' -EnvFile $EnvFile *> $null
    $qaPwd = Get-SenhaDefinitiva -Username $qaUser
    $qaConn = "$qaUser/$qaPwd@//localhost:1521/FREEPDB1"

    $outSelect = (Invoke-SqlPlus -ConnectString $qaConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT nota FROM KAWASHI_ENV_HOMOLOG.$tabela WHERE id = 1;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "HomologViewer CONSEGUE ler (SELECT) uma tabela existente em Homologacao" -Passed ($outSelect -match 'dado de homologacao') -Details $(if ($outSelect -notmatch 'dado de homologacao') { $outSelect })

    # Oracle 23ai tem codigos de erro mais especificos que o generico ORA-01031
    # ("insufficient privileges") para falta de privilegio OBJETO a objeto em
    # DML: ORA-41900 ("missing INSERT/UPDATE/DELETE privilege"). Aceitamos os
    # dois formatos pra nao prender o teste a uma versao especifica do Oracle.
    $negadoPorPrivilegio = 'ORA-01031|ORA-41900'

    $outInsert = (Invoke-SqlPlus -ConnectString $qaConn -Sql "INSERT INTO KAWASHI_ENV_HOMOLOG.$tabela VALUES (2, 'tentativa indevida');`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "HomologViewer NAO consegue INSERT em Homologacao" -Passed ($outInsert -match $negadoPorPrivilegio) -Details $(if ($outInsert -notmatch $negadoPorPrivilegio) { $outInsert })

    $outUpdate = (Invoke-SqlPlus -ConnectString $qaConn -Sql "UPDATE KAWASHI_ENV_HOMOLOG.$tabela SET nota = 'alterado' WHERE id = 1;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "HomologViewer NAO consegue UPDATE em Homologacao" -Passed ($outUpdate -match $negadoPorPrivilegio) -Details $(if ($outUpdate -notmatch $negadoPorPrivilegio) { $outUpdate })

    $outDelete = (Invoke-SqlPlus -ConnectString $qaConn -Sql "DELETE FROM KAWASHI_ENV_HOMOLOG.$tabela WHERE id = 1;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "HomologViewer NAO consegue DELETE em Homologacao" -Passed ($outDelete -match $negadoPorPrivilegio) -Details $(if ($outDelete -notmatch $negadoPorPrivilegio) { $outDelete })

    $outCreate = (Invoke-SqlPlus -ConnectString $qaConn -Sql "CREATE TABLE TESTE_NAO_DEVERIA_EXISTIR (id NUMBER);`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "HomologViewer NAO consegue CREATE TABLE em canto nenhum (ORA-01031)" -Passed ($outCreate -match 'ORA-01031') -Details $(if ($outCreate -notmatch 'ORA-01031') { $outCreate })

    $outAlter = (Invoke-SqlPlus -ConnectString $qaConn -Sql "ALTER TABLE KAWASHI_ENV_HOMOLOG.$tabela ADD coluna_indevida VARCHAR2(10);`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "HomologViewer NAO consegue ALTER TABLE em Homologacao" -Passed ($outAlter -match $negadoPorPrivilegio) -Details $(if ($outAlter -notmatch $negadoPorPrivilegio) { $outAlter })

    $outDropAlheio = (Invoke-SqlPlus -ConnectString $qaConn -Sql "DROP TABLE KAWASHI_ENV_HOMOLOG.$tabela;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "HomologViewer NAO consegue DROP TABLE em Homologacao" -Passed ($outDropAlheio -match $negadoPorPrivilegio) -Details $(if ($outDropAlheio -notmatch $negadoPorPrivilegio) { $outDropAlheio })
}
finally {
    Write-Host "-> Limpando tabela de teste, usuarios descartaveis e artefatos no Vault..."
    # Nao precisa limpar "TESTE_NAO_DEVERIA_EXISTIR" separadamente: se o CREATE
    # TABLE tivesse (indevidamente) funcionado, o objeto nasceria no proprio
    # schema do $qaUser, e o DROP USER ... CASCADE abaixo ja remove tudo que
    # esse usuario possui.
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP TABLE KAWASHI_ENV_HOMOLOG.$tabela;`nEXIT;`n" | Out-Null
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
