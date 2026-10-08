# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-BRANCA: confirma que o trigger KAWASHI_HOMOLOG_AUTOGRANT_TRG
    (infra/oracle-init/09_environments.sql) concede SELECT automaticamente a
    ROLE_KAWASHI_HOMOLOG_VIEWER sempre que uma tabela nova e criada dentro do
    schema KAWASHI_ENV_HOMOLOG.

.DESCRIPTION
    E "caixa-branca" porque o teste sabe exatamente qual mecanismo interno
    esperar (um trigger AFTER CREATE ON SCHEMA) e consulta diretamente o
    catalogo (DBA_TAB_PRIVS) para confirmar que ele agiu - um teste de
    caixa-preta equivalente so poderia confirmar que "o QA consegue ler a
    tabela nova", sem saber (nem precisar saber) que um trigger foi o
    responsavel por isso.

    Cria e remove uma tabela descartavel dentro de KAWASHI_ENV_HOMOLOG para
    nao deixar nenhum resto no ambiente de homologacao real.

.NOTES
    CORRIGIDO (achado rodando este teste pela primeira vez): a primeira versao
    criava a tabela via "ALTER SESSION SET CURRENT_SCHEMA = KAWASHI_ENV_HOMOLOG"
    a partir do ENGINEER_USER. Isso faz o objeto NASCER com o dono certo
    (CURRENT_SCHEMA controla so a resolucao de nomes), mas gatilhos de schema
    ("ON SCHEMA") disparam com base em quem e o USUARIO ATUAL da sessao
    (CURRENT_USER), nao no CURRENT_SCHEMA - e o ENGINEER_USER nunca deixa de
    ser ele mesmo so por isso. Resultado: a tabela era criada normalmente, mas
    o trigger nunca disparava, e o teste falhava achando (corretamente) que
    nao tinha sido concedido nada. A forma de realmente "virar" KAWASHI_ENV_HOMOLOG
    e autenticacao por PROXY (igual um Dev/Infra de verdade faz em producao) -
    por isso o teste agora concede um CONNECT THROUGH temporario para o proprio
    ENGINEER_USER, conecta via proxy, cria a tabela dali, e revoga o proxy nao
    importa o resultado.

    Essa mesma rodada revelou um SEGUNDO problema, desta vez na propria
    09_environments.sql, e nao neste teste: rodar "EXECUTE IMMEDIATE 'GRANT ...'"
    direto no corpo do trigger de schema sempre falhava com ORA-04088/ORA-30511
    ("invalid DDL operation in system triggers"). Corrigido no script fonte
    trocando o GRANT imediato por um DBMS_SCHEDULER.CREATE_JOB (GRANT roda
    milissegundos depois, numa sessao separada, fora do contexto restrito do
    trigger) - ver comentario em 09_environments.sql. Por isso este teste
    espera (com um pequeno retry) em vez de checar o grant imediatamente apos
    o CREATE TABLE.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [CAIXA-BRANCA] Trigger de auto-grant em KAWASHI_ENV_HOMOLOG ==" -ForegroundColor Cyan

$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$engineerCred = Get-EngineerCredentials -EnvFile $EnvFile
$proxyConn = "$($engineerCred.User)[KAWASHI_ENV_HOMOLOG]/$($engineerCred.Password)@//localhost:1521/FREEPDB1"
$tabela = "TESTE_AUTOGRANT_$((New-ThrowawayUsername -Prefix '').TrimStart('_'))"
$results = @()
$proxyConcedido = $false

try {
    Invoke-SqlPlus -ConnectString $engineerConn -Sql @"
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER USER KAWASHI_ENV_HOMOLOG GRANT CONNECT THROUGH $($engineerCred.User);
EXIT;
"@ | Out-Null
    $proxyConcedido = $true

    $sqlCriar = "ALTER SESSION SET CONTAINER = FREEPDB1;`nCREATE TABLE $tabela (id NUMBER);`nEXIT;`n"
    $outCriar = (Invoke-SqlPlus -ConnectString $proxyConn -Sql $sqlCriar) -join "`n"
    $results += New-TestResult -Name "Tabela de teste criada em KAWASHI_ENV_HOMOLOG via proxy" -Passed ($outCriar -match 'Table created') -Details $(if ($outCriar -notmatch 'Table created') { $outCriar })

    $sqlChecar = @'
SET PAGESIZE 0
SET FEEDBACK OFF
SELECT grantee || ':' || privilege FROM dba_tab_privs
WHERE owner = 'KAWASHI_ENV_HOMOLOG' AND table_name = '__TABELA__' AND privilege = 'SELECT';
EXIT;
'@ -replace '__TABELA__', $tabela

    # O GRANT roda num job agendado assincrono (ver nota acima) - da uma
    # pequena margem antes de desistir, em vez de checar uma unica vez.
    $concedido = $false
    for ($tentativa = 1; $tentativa -le 10 -and -not $concedido; $tentativa++) {
        Start-Sleep -Seconds 1
        $outChecar = (Invoke-SqlPlus -ConnectString $engineerConn -Sql $sqlChecar) -join "`n"
        $concedido = $outChecar -match 'ROLE_KAWASHI_HOMOLOG_VIEWER:SELECT'
    }
    $results += New-TestResult -Name "Trigger KAWASHI_HOMOLOG_AUTOGRANT_TRG concedeu SELECT a ROLE_KAWASHI_HOMOLOG_VIEWER automaticamente (ate 10s, job assincrono)" `
        -Passed $concedido `
        -Details $(if (-not $concedido) { "saida da ultima tentativa:`n$outChecar" })
}
finally {
    Invoke-SqlPlus -ConnectString $engineerConn -Sql @"
ALTER SESSION SET CONTAINER = FREEPDB1;
DROP TABLE KAWASHI_ENV_HOMOLOG.$tabela;
EXIT;
"@ | Out-Null
    if ($proxyConcedido) {
        Invoke-SqlPlus -ConnectString $engineerConn -Sql @"
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER USER KAWASHI_ENV_HOMOLOG REVOKE CONNECT THROUGH $($engineerCred.User);
EXIT;
"@ | Out-Null
    }
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
