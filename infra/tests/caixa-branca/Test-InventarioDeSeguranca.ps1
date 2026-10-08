# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-BRANCA (golden snapshot / guarda de regressao de
    inventario): confirma que o CONJUNTO de triggers, roles, profiles,
    procedures/functions e jobs agendados relacionados a seguranca e
    EXATAMENTE o esperado - nem falta nenhum, nem sobrou nenhum extra.

.DESCRIPTION
    Diferente dos outros testes de caixa-branca (que checam o CONTEUDO/
    comportamento de uma peca especifica), este olha pro INVENTARIO inteiro de
    uma vez. Ele pega dois tipos de regressao que nenhum teste pontual
    pegaria:
      - ALGUEM REMOVEU uma peca de seguranca sem querer (ex: um DROP TRIGGER
        acidental rodado direto num ambiente, ou um script futuro que
        esqueceu de recriar algo).
      - ALGUEM DEIXOU PRA TRAS uma peca de teste/debug (ex: um objeto criado
        manualmente pra investigar um bug, que devia ter sido removido - como
        quase aconteceu durante a propria investigacao do item 8 de
        bugs-primeiro-teste.md, onde uma tabela de debug manual quase ficou
        esquecida em KAWASHI_ENV_HOMOLOG).

    A lista "esperada" abaixo e deliberadamente mantida A MAO (nao gerada
    dinamicamente a partir do codigo) - o proposito do teste e justamente
    perceber quando o inventario real diverge do que humanos documentaram
    como esperado.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')

Write-Host "== [CAIXA-BRANCA] Inventario de seguranca (golden snapshot) ==" -ForegroundColor Cyan

$results = @()

function Get-ConjuntoViaSql {
    param([string]$Sql)
    $out = (Invoke-SqlPlus -ConnectString '/ as sysdba' -Sql $Sql) -join "`n"
    # Filtra qualquer linha que nao seja um identificador Oracle puro (maiusculas/
    # numeros/underscore) - descarta banners como "Session altered." e afins.
    # CORRIGIDO: sem isso, "Session altered." (do ALTER SESSION SET CONTAINER
    # no topo de cada bloco) aparecia como se fosse um item real do inventario.
    return ($out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[A-Z][A-Z0-9_]*$' })
}

function Compare-Inventario {
    param([string]$Nome, [string[]]$Esperado, [string[]]$Real)
    $esperadoSet = @($Esperado | Sort-Object -Unique)
    $realSet = @($Real | Where-Object { $_ } | Sort-Object -Unique)
    $faltando = @($esperadoSet | Where-Object { $_ -notin $realSet })
    $extra = @($realSet | Where-Object { $_ -notin $esperadoSet })
    $passou = ($faltando.Count -eq 0) -and ($extra.Count -eq 0)
    $detalhe = ''
    if ($faltando.Count -gt 0) { $detalhe += "FALTANDO: $($faltando -join ', '). " }
    if ($extra.Count -gt 0) { $detalhe += "EXTRA (nao documentado): $($extra -join ', '). " }
    return New-TestResult -Name "Inventario de $Nome bate exatamente com o esperado ($($esperadoSet.Count) itens)" -Passed $passou -Details $detalhe
}

# --- Triggers relacionados a seguranca/ambientes (qualquer schema) ----------
$sqlTriggers = @'
ALTER SESSION SET CONTAINER = FREEPDB1;
SET PAGESIZE 0
SET FEEDBACK OFF
SELECT trigger_name FROM dba_triggers WHERE trigger_name LIKE 'KAWASHI%' ORDER BY trigger_name;
EXIT;
'@
$triggersReais = Get-ConjuntoViaSql -Sql $sqlTriggers
$triggersEsperados = @(
    'KAWASHI_CONTEXT_SECURITY_TRG', 'KAWASHI_LOGOFF_SECURITY_TRG', 'KAWASHI_DDL_AUDIT_TRG',
    'KAWASHI_PRIVESC_AUDIT_TRG', 'KAWASHI_HOMOLOG_AUTOGRANT_TRG'
)
$results += Compare-Inventario -Nome 'triggers' -Esperado $triggersEsperados -Real $triggersReais

# --- Roles do projeto -------------------------------------------------------
$sqlRoles = @'
ALTER SESSION SET CONTAINER = FREEPDB1;
SET PAGESIZE 0
SET FEEDBACK OFF
SELECT role FROM dba_roles WHERE role LIKE '%KAWASHI%' ORDER BY role;
EXIT;
'@
$rolesReais = Get-ConjuntoViaSql -Sql $sqlRoles
$rolesEsperadas = @(
    'ROLE_KAWASHI_DEVELOPER', 'ROLE_KAWASHI_INFRA', 'ROLE_KAWASHI_HOMOLOG_VIEWER',
    'KAWASHI_READONLY', 'KAWASHI_READWRITE'
)
$results += Compare-Inventario -Nome 'roles' -Esperado $rolesEsperadas -Real $rolesReais

# --- Profiles do projeto -----------------------------------------------------
$sqlProfiles = @'
ALTER SESSION SET CONTAINER = FREEPDB1;
SET PAGESIZE 0
SET FEEDBACK OFF
SELECT DISTINCT profile FROM dba_profiles WHERE profile LIKE 'KAWASHI%' ORDER BY profile;
EXIT;
'@
$profilesReais = Get-ConjuntoViaSql -Sql $sqlProfiles
$profilesEsperados = @('KAWASHI_SECURE_PROFILE', 'KAWASHI_SERVICE_PROFILE')
$results += Compare-Inventario -Nome 'profiles' -Esperado $profilesEsperados -Real $profilesReais

# --- Procedures/Functions de seguranca (qualquer schema) --------------------
$sqlProcs = @'
ALTER SESSION SET CONTAINER = FREEPDB1;
SET PAGESIZE 0
SET FEEDBACK OFF
SELECT object_name FROM dba_objects WHERE object_name LIKE 'KAWASHI%' AND object_type IN ('PROCEDURE', 'FUNCTION') ORDER BY object_name;
EXIT;
'@
$procsReais = Get-ConjuntoViaSql -Sql $sqlProcs
$procsEsperados = @('KAWASHI_PASSWORD_VERIFY', 'KAWASHI_WRITE_SECURITY_LOG')
$results += Compare-Inventario -Nome 'procedures/functions' -Esperado $procsEsperados -Real $procsReais

# --- Jobs agendados -----------------------------------------------------------
$sqlJobs = @'
ALTER SESSION SET CONTAINER = FREEPDB1;
SET PAGESIZE 0
SET FEEDBACK OFF
SELECT job_name FROM dba_scheduler_jobs WHERE job_name LIKE 'KAWASHI%' ORDER BY job_name;
EXIT;
'@
$jobsReais = Get-ConjuntoViaSql -Sql $sqlJobs
$jobsEsperados = @('KAWASHI_DB_MAINTENANCE_JOB', 'KAWASHI_INDEX_REBUILD_JOB', 'KAWASHI_UNIFIED_AUDIT_PURGE_JOB')
$results += Compare-Inventario -Nome 'jobs agendados' -Esperado $jobsEsperados -Real $jobsReais

# --- Tabelas de controle/log do SIEM -----------------------------------------
$sqlTabelas = @'
ALTER SESSION SET CONTAINER = FREEPDB1;
SET PAGESIZE 0
SET FEEDBACK OFF
SELECT table_name FROM dba_tables WHERE table_name LIKE 'KAWASHI%' AND owner = 'SYS' ORDER BY table_name;
EXIT;
'@
$tabelasReais = Get-ConjuntoViaSql -Sql $sqlTabelas
$tabelasEsperadas = @('KAWASHI_ALLOWED_IPS', 'KAWASHI_FORBIDDEN_TOOLS', 'KAWASHI_SECURITY_LOG', 'KAWASHI_SECURITY_LOG_FALLBACK')
$results += Compare-Inventario -Nome 'tabelas de controle/log (owner SYS)' -Esperado $tabelasEsperadas -Real $tabelasReais

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
