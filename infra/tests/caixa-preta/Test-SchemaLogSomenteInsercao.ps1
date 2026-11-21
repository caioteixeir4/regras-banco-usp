# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: confirma que o schema de log da aplicacao
    (KAWASHI_ENV_<AMBIENTE>_LOG, criado em oracle-init/11_schema_log.sql) so aceita INSERT e
    SELECT da conta de API, e que o encadeamento por hash de LOG_ALTERACAO acusa adulteracao.

.DESCRIPTION
    A promessa do schema de log e: a API (ou quem a invadir) consegue REGISTRAR, mas nao consegue
    alterar nem apagar o que ja foi registrado, nem escolher a hora, a numeracao ou o hash de uma
    linha. Este teste entra como uma conta de API de verdade (proxy, mesmo caminho da aplicacao) e
    tenta cada uma dessas coisas. E a conta de EXECUCAO (schema _APP), a unica que tem privilegio no
    schema de log; a de migracao e as pessoas nao tem nenhum.

    Depois, como DBA, altera e apaga linhas direto no banco para provar que a view
    V_LOG_ALTERACAO_QUEBRAS enxerga a adulteracao (uma conferencia que nunca acusa nada "passaria"
    mesmo quebrada).

    Usa o ambiente TESTE_INFRA para nao mexer na corrente do TESTE_DEV, que e o da API em
    desenvolvimento. No fim devolve a corrente ao estado em que estava.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')

Write-Host "== [CAIXA-PRETA] Schema de log: so insercao, com encadeamento por hash ==" -ForegroundColor Cyan

$createApi    = Join-Path $PSScriptRoot '..\..\scripts\create-api-account.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken   = Get-VaultToken -EnvFile $EnvFile
$log          = 'KAWASHI_ENV_TESTE_INFRA_LOG'
$marca        = 'TST_LOG_' + (Get-Random -Maximum 999999)
$results = @()
$api = $null
$apiMig = $null
$estadoInicial = $null

function Invoke-Dba {
    param([string]$Sql)
    return (Invoke-SqlPlus -ConnectString $engineerConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSET LINESIZE 300`nALTER SESSION SET CONTAINER = FREEPDB1;`n$Sql`nEXIT;`n") -join "`n"
}

try {
    $api = New-ThrowawayUsername -Prefix 'TST_APIL'
    & $createApi -Username $api -Ambiente 'TESTE_INFRA' -EnvFile $EnvFile *> $null
    $argCampo = '-field=db_password'
    $senha = ((docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv get $argCampo "kawashi-secrets/api/$api" 2>&1) -join '').Trim()
    $conn = "$api[KAWASHI_ENV_TESTE_INFRA_APP]/$senha@//localhost:1521/FREEPDB1"

    function Invoke-Api {
        param([string]$Sql)
        return (Invoke-SqlPlus -ConnectString $conn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSET LINESIZE 300`n$Sql`nEXIT;`n") -join "`n"
    }

    $estadoInicial = (Invoke-Dba "SELECT ULTIMA_ORDEM || '|' || NVL(ULTIMO_HASH, '-') FROM $log.LOG_CADEIA WHERE TABELA = 'LOG_ALTERACAO';").Trim()
    $ordemInicial = [int]($estadoInicial.Split('|')[0])

    # --- inserir funciona, e o que a API tenta forjar e ignorado ------------------
    $insert = "INSERT INTO $log.LOG_ALTERACAO (ORDEM, TABELA, REGISTRO_ID, ACAO, USUARIO, DATA_HORA, HASH_ANTERIOR, HASH) VALUES (999999, 'PESSOA', {0}, 'INSERT', '$marca', TIMESTAMP '2000-01-01 00:00:00', 'forjado', 'forjado');"
    $outInsert = Invoke-Api ((1..3 | ForEach-Object { $insert -f $_ }) -join "`n" | ForEach-Object { "$_`nCOMMIT;" })
    $results += New-TestResult -Name "A conta de API consegue INSERIR em LOG_ALTERACAO (registrar e o trabalho dela)" -Passed ($outInsert -notmatch 'ORA-\d{5}') -Details $outInsert

    $linhas = (Invoke-Api "SELECT ORDEM || '|' || HASH || '|' || NVL(HASH_ANTERIOR, '-') || '|' || TO_CHAR(DATA_HORA, 'YYYY') FROM $log.LOG_ALTERACAO WHERE USUARIO = '$marca' ORDER BY ORDEM;") -split "`n" | Where-Object { $_ -match '\|' }
    $campos = $linhas | ForEach-Object { , ($_.Trim().Split('|')) }
    $ordens = @($campos | ForEach-Object { [int]$_[0] })
    $okOrdem = ($ordens.Count -eq 3) -and ($ordens[0] -eq $ordemInicial + 1) -and ($ordens[1] -eq $ordemInicial + 2) -and ($ordens[2] -eq $ordemInicial + 3)
    $results += New-TestResult -Name "ORDEM e do banco: a API mandou 999999 e as linhas sairam numeradas em sequencia, sem buraco" -Passed $okOrdem -Details ($linhas -join ' ; ')
    $okHash = ($campos.Count -eq 3) -and (@($campos | Where-Object { $_[1] -match '^[0-9a-f]{64}$' }).Count -eq 3) -and ($campos[1][2] -eq $campos[0][1]) -and ($campos[2][2] -eq $campos[1][1])
    $results += New-TestResult -Name "HASH e do banco: a API mandou 'forjado', gravou-se um SHA-256, e cada linha aponta para o hash da anterior" -Passed $okHash -Details ($linhas -join ' ; ')
    $anoAtual = (Get-Date).Year.ToString()
    $okHora = ($campos.Count -eq 3) -and (@($campos | Where-Object { $_[3] -eq $anoAtual }).Count -eq 3)
    $results += New-TestResult -Name "DATA_HORA e a do servidor: a API mandou o ano 2000 e nao conseguiu datar o registro para tras" -Passed $okHora -Details ($linhas -join ' ; ')

    # --- o que a API NAO pode ------------------------------------------------------
    $outUpdate = Invoke-Api "UPDATE $log.LOG_ALTERACAO SET USUARIO = 'outro' WHERE USUARIO = '$marca';"
    $results += New-TestResult -Name "A conta de API NAO consegue ALTERAR uma linha de LOG_ALTERACAO (ORA-01031)" -Passed ($outUpdate -match 'ORA-01031|ORA-41900') -Details $outUpdate
    $outDelete = Invoke-Api "DELETE FROM $log.LOG_ALTERACAO WHERE USUARIO = '$marca';"
    $results += New-TestResult -Name "A conta de API NAO consegue APAGAR linhas de LOG_ALTERACAO (ORA-01031)" -Passed ($outDelete -match 'ORA-01031|ORA-41900') -Details $outDelete
    $outTruncate = Invoke-Api "TRUNCATE TABLE $log.LOG_ALTERACAO;"
    $outDrop     = Invoke-Api "DROP TABLE $log.LOG_ALTERACAO;"
    $results += New-TestResult -Name "A conta de API NAO consegue esvaziar (TRUNCATE) nem remover (DROP) a tabela de log" -Passed (($outTruncate -match 'ORA-\d{5}') -and ($outDrop -match 'ORA-\d{5}')) -Details "$outTruncate | $outDrop"
    $outCadeia = Invoke-Api "SELECT ULTIMA_ORDEM FROM $log.LOG_CADEIA;`nUPDATE $log.LOG_CADEIA SET ULTIMA_ORDEM = 0;"
    $results += New-TestResult -Name "A conta de API nem enxerga a tabela de controle da corrente (LOG_CADEIA): ORA-00942" -Passed (($outCadeia -match 'ORA-00942') -and ($outCadeia -notmatch '^\s*\d+\s*$')) -Details $outCadeia
    $outTrigger = Invoke-Api "ALTER TRIGGER $log.LOG_ALTERACAO_CADEIA_TRG DISABLE;"
    $results += New-TestResult -Name "A conta de API NAO consegue desligar o trigger do encadeamento" -Passed ($outTrigger -match 'ORA-\d{5}') -Details $outTrigger
    $outLogin = (Invoke-SqlPlus -ConnectString "$api[$log]/$senha@//localhost:1521/FREEPDB1" -Sql "SELECT 1 FROM DUAL;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Ninguem entra no schema de log por proxy: a conta de API e recusada (ORA-01017)" -Passed ($outLogin -match 'ORA-01017') -Details $outLogin

    # --- so a conta de EXECUCAO tem acesso: a de migracao (dona das tabelas) nao tem nenhum ---
    $apiMig = New-ThrowawayUsername -Prefix 'TST_APLM'
    & $createApi -Username $apiMig -Ambiente 'TESTE_INFRA' -Papel 'Migracao' -EnvFile $EnvFile *> $null
    $argCampoMig = '-field=db_password'
    $senhaMig = ((docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv get $argCampoMig "kawashi-secrets/api/$apiMig" 2>&1) -join '').Trim()
    $outMig = (Invoke-SqlPlus -ConnectString "$apiMig[KAWASHI_ENV_TESTE_INFRA]/$senhaMig@//localhost:1521/FREEPDB1" -Sql "SELECT COUNT(*) FROM $log.LOG_ALTERACAO;`nINSERT INTO $log.LOG_ACESSO (METODO, CAMINHO, STATUS) VALUES ('GET', '/x', 200);`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "A conta de MIGRACAO (que entra como dona das tabelas de cadastro) nao le nem grava no schema de log: ORA-00942" -Passed (([regex]::Matches($outMig, 'ORA-00942')).Count -ge 2) -Details $outMig

    # --- LOG_ACESSO: mesma regra ---------------------------------------------------
    $outAcesso = Invoke-Api "INSERT INTO $log.LOG_ACESSO (USUARIO, METODO, CAMINHO, STATUS, DATA_HORA) VALUES ('$marca', 'GET', '/teste', 200, TIMESTAMP '2000-01-01 00:00:00');`nCOMMIT;`nSELECT 'ANO=' || TO_CHAR(DATA_HORA, 'YYYY') FROM $log.LOG_ACESSO WHERE USUARIO = '$marca';`nDELETE FROM $log.LOG_ACESSO WHERE USUARIO = '$marca';"
    $results += New-TestResult -Name "LOG_ACESSO: a API insere, a hora gravada e a do servidor, e apagar e recusado (ORA-01031)" -Passed (($outAcesso -match "ANO=$anoAtual") -and ($outAcesso -match 'ORA-01031|ORA-41900')) -Details $outAcesso

    # --- a conferencia acusa adulteracao (feita como DBA, direto no banco) ---------
    $quebras = "SELECT 'QUEBRAS=' || COUNT(*) FROM $log.V_LOG_ALTERACAO_QUEBRAS;"
    $outIntegra = Invoke-Api $quebras
    $results += New-TestResult -Name "Corrente inteira: a view de conferencia nao aponta nenhum problema (e a API consegue consulta-la)" -Passed ($outIntegra -match 'QUEBRAS=0') -Details $outIntegra

    $meio = $ordens[1]
    Invoke-Dba "UPDATE $log.LOG_ALTERACAO SET REGISTRO_ID = 777 WHERE ORDEM = $meio;`nCOMMIT;" | Out-Null
    $outAlterada = Invoke-Dba "SELECT 'P=' || PROBLEMA FROM $log.V_LOG_ALTERACAO_QUEBRAS WHERE ORDEM = $meio;"
    $results += New-TestResult -Name "Adulteracao 1: um DBA altera o conteudo de uma linha e a conferencia acusa exatamente essa linha" -Passed ($outAlterada -match 'P=conteudo alterado') -Details $outAlterada
    Invoke-Dba "UPDATE $log.LOG_ALTERACAO SET REGISTRO_ID = 2 WHERE ORDEM = $meio;`nCOMMIT;" | Out-Null

    Invoke-Dba "DELETE FROM $log.LOG_ALTERACAO WHERE ORDEM = $meio;`nCOMMIT;" | Out-Null
    $outApagada = Invoke-Dba "SELECT 'P=' || PROBLEMA FROM $log.V_LOG_ALTERACAO_QUEBRAS WHERE ORDEM = $($ordens[2]);"
    $results += New-TestResult -Name "Adulteracao 2: um DBA apaga uma linha do meio e a conferencia acusa o buraco na linha seguinte" -Passed ($outApagada -match 'P=falta linha') -Details $outApagada

    Invoke-Dba "DELETE FROM $log.LOG_ALTERACAO WHERE ORDEM = $($ordens[2]);`nCOMMIT;" | Out-Null
    $outFim = Invoke-Dba "SELECT 'P=' || PROBLEMA FROM $log.V_LOG_ALTERACAO_QUEBRAS;"
    $results += New-TestResult -Name "Adulteracao 3: um DBA apaga a ULTIMA linha e a conferencia acusa que faltam linhas no fim" -Passed ($outFim -match 'P=faltam linhas no fim') -Details $outFim
}
finally {
    Write-Host "-> Limpando: linhas do teste, estado da corrente, conta descartavel e segredo no Vault..."
    if ($estadoInicial) {
        $p = $estadoInicial.Split('|')
        $hashInicial = if ($p[1] -eq '-') { 'NULL' } else { "'$($p[1])'" }
        Invoke-Dba "DELETE FROM $log.LOG_ALTERACAO WHERE USUARIO = '$marca';`nDELETE FROM $log.LOG_ACESSO WHERE USUARIO = '$marca';`nUPDATE $log.LOG_CADEIA SET ULTIMA_ORDEM = $($p[0]), ULTIMO_HASH = $hashInicial WHERE TABELA = 'LOG_ALTERACAO';`nCOMMIT;" | Out-Null
        $outLimpo = Invoke-Dba "SELECT 'QUEBRAS=' || COUNT(*) FROM $log.V_LOG_ALTERACAO_QUEBRAS;"
        $results += New-TestResult -Name "Depois da limpeza a corrente do ambiente de teste volta a estar inteira" -Passed ($outLimpo -match 'QUEBRAS=0') -Details $outLimpo
    }
    if ($apiMig) {
        Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $apiMig CASCADE;`nEXIT;`n" | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv metadata delete "kawashi-secrets/api/$apiMig" 2>&1 | Out-Null
    }
    if ($api) {
        Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $api CASCADE;`nEXIT;`n" | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv metadata delete "kawashi-secrets/api/$api" 2>&1 | Out-Null
    }
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
