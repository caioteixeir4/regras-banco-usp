# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-BRANCA (invariante de arquitetura): confirma que NENHUMA
    tabela de um schema PADRAO (KAWASHI_ENV_TESTE_DEV, _TESTE_INFRA, _DEV,
    _INFRA, _HOMOLOG, _PROD) tem foreign key apontando pra dentro de um schema
    de SERVICO (SEFAZ, SIMPLES_NACIONAL, ORGANIZACOES, LOGIN, ADMINISTRACAO,
    ou qualquer outro criado no futuro) - a FK so pode existir no sentido
    SERVICO -> PADRAO, nunca o inverso (ver arquitetura.md, secao 2.1).

.DESCRIPTION
    Pergunta levantada pelo usuario: "nao e interessante fazer testes? tipo
    para garantir que nas tabelas padroes nunca tenha uma foreing key que
    esta em um esquema la na frente". Sem este teste, nada na suite
    automatizada pegaria uma FK adicionada por engano no sentido errado (ex:
    alguem cria CLIENTE.CONFIGURACAO_PADRAO_ID REFERENCES SEFAZ.ALGUMA_TABELA)
    - isso quebraria a promessa central da arquitetura de que o schema padrao
    e reutilizavel por qualquer servico novo sem nunca precisar saber que
    aquele servico existe.

    A consulta e GENERICA (schema de servico = qualquer owner "KAWASHI_ENV_%"
    que NAO seja um dos 6 nomes de ambiente "puros") - continua valendo pra
    qualquer servico futuro, sem precisar listar nomes de servico um por um.

    Controles positivos (pra provar que a consulta nao e vazia por acidente -
    uma consulta que nunca encontra nada "passaria" mesmo quebrada): confirma
    que as FKs servico->padrao conhecidas (SEFAZ, ADMINISTRACAO, LOGIN - ver
    infra/oracle-init/11_exemplo_dominio_negocio.sql e
    12_exemplo_dominio_kawashi_core.sql) realmente existem no sentido certo.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')

Write-Host "== [CAIXA-BRANCA] Invariante: tabela padrao nunca referencia schema de servico ==" -ForegroundColor Cyan

$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$results = @()

$ambientesPadrao = "'KAWASHI_ENV_TESTE_DEV','KAWASHI_ENV_TESTE_INFRA','KAWASHI_ENV_DEV','KAWASHI_ENV_INFRA','KAWASHI_ENV_HOMOLOG','KAWASHI_ENV_PROD'"

# --- Invariante: zero FKs no sentido PADRAO -> SERVICO, em qualquer dos 6 ambientes ---
$sqlInvariante = @"
SET PAGESIZE 200
SET LINESIZE 200
SET FEEDBACK ON
SELECT a.owner, a.table_name, a.constraint_name, a.r_owner, b.table_name AS tabela_referenciada
FROM dba_constraints a
JOIN dba_constraints b ON a.r_owner = b.owner AND a.r_constraint_name = b.constraint_name
WHERE a.constraint_type = 'R'
  AND a.owner IN ($ambientesPadrao)
  AND a.r_owner LIKE 'KAWASHI\_ENV\_%' ESCAPE '\'
  AND a.r_owner NOT IN ($ambientesPadrao);
EXIT;
"@
$outInvariante = (Invoke-SqlPlus -ConnectString $engineerConn -Sql $sqlInvariante) -join "`n"
$results += New-TestResult -Name "Nenhuma tabela padrao (nos 6 ambientes) tem FK apontando pra um schema de servico" -Passed ($outInvariante -match 'no rows selected') -Details $(if ($outInvariante -notmatch 'no rows selected') { $outInvariante })

# --- Controles positivos: as FKs servico->padrao conhecidas existem de verdade ---
$sqlControles = @"
SET PAGESIZE 0
SET FEEDBACK OFF
SET LINESIZE 200
SELECT a.owner || '->' || a.r_owner
FROM dba_constraints a
JOIN dba_constraints b ON a.r_owner = b.owner AND a.r_constraint_name = b.constraint_name
WHERE a.constraint_type = 'R'
  AND a.owner IN ('KAWASHI_ENV_DEV_SEFAZ', 'KAWASHI_ENV_DEV_ADMINISTRACAO', 'KAWASHI_ENV_DEV_LOGIN');
EXIT;
"@
$outControles = (Invoke-SqlPlus -ConnectString $engineerConn -Sql $sqlControles) -join "`n"
$results += New-TestResult -Name "Controle positivo: KAWASHI_ENV_DEV_SEFAZ tem FK apontando pro padrao (KAWASHI_ENV_DEV) - consulta nao e vazia por acidente" -Passed ($outControles -match 'KAWASHI_ENV_DEV_SEFAZ->KAWASHI_ENV_DEV\b') -Details $(if ($outControles -notmatch 'KAWASHI_ENV_DEV_SEFAZ->KAWASHI_ENV_DEV\b') { $outControles })
$results += New-TestResult -Name "Controle positivo: KAWASHI_ENV_DEV_ADMINISTRACAO tem FK apontando pro padrao (KAWASHI_ENV_DEV)" -Passed ($outControles -match 'KAWASHI_ENV_DEV_ADMINISTRACAO->KAWASHI_ENV_DEV\b') -Details $(if ($outControles -notmatch 'KAWASHI_ENV_DEV_ADMINISTRACAO->KAWASHI_ENV_DEV\b') { $outControles })
$results += New-TestResult -Name "Controle positivo: KAWASHI_ENV_DEV_LOGIN tem FK apontando pro servico ORGANIZACOES, nao pro padrao direto" -Passed ($outControles -match 'KAWASHI_ENV_DEV_LOGIN->KAWASHI_ENV_DEV_ORGANIZACOES') -Details $(if ($outControles -notmatch 'KAWASHI_ENV_DEV_LOGIN->KAWASHI_ENV_DEV_ORGANIZACOES') { $outControles })

# --- Sanity: os 3 schemas novos existem nos 2 ambientes onde deveriam ---
$sqlSchemas = @"
SET PAGESIZE 0
SET FEEDBACK OFF
SELECT username FROM dba_users
WHERE username IN (
    'KAWASHI_ENV_TESTE_DEV_ORGANIZACOES', 'KAWASHI_ENV_TESTE_DEV_LOGIN', 'KAWASHI_ENV_TESTE_DEV_ADMINISTRACAO',
    'KAWASHI_ENV_DEV_ORGANIZACOES', 'KAWASHI_ENV_DEV_LOGIN', 'KAWASHI_ENV_DEV_ADMINISTRACAO'
)
ORDER BY username;
EXIT;
"@
$outSchemas = (Invoke-SqlPlus -ConnectString $engineerConn -Sql $sqlSchemas) -join "`n"
$qtdSchemas = ([regex]::Matches($outSchemas, 'KAWASHI_ENV_(TESTE_DEV|DEV)_(ORGANIZACOES|LOGIN|ADMINISTRACAO)')).Count
$results += New-TestResult -Name "Os 3 schemas de exemplo (ORGANIZACOES/LOGIN/ADMINISTRACAO) existem em TESTE_DEV e DEV (6 no total)" -Passed ($qtdSchemas -eq 6) -Details $(if ($qtdSchemas -ne 6) { "Encontrados: $qtdSchemas`n$outSchemas" })

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
