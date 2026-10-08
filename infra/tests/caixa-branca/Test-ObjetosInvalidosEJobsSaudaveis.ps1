# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-BRANCA (regressao): confirma que nenhum objeto PL/SQL
    KAWASHI_* esta INVALID e que os jobs agendados de manutencao continuam
    ENABLED - a mesma verificacao que infra/scripts/verify-environment.ps1 ja
    faz manualmente, mas agora como asserção automatizada.

.DESCRIPTION
    Sem isto, nada na suite automatizada hoje pegaria uma mudanca futura que
    quebrasse a compilacao de uma trigger/procedure/function (por exemplo, um
    CREATE OR REPLACE mal escrito rodado manualmente contra o ambiente) - so
    rodando verify-environment.ps1 na mao, ou esbarrando no sintoma depois.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')

Write-Host "== [CAIXA-BRANCA] Nenhum objeto KAWASHI_* invalido, jobs agendados saudaveis ==" -ForegroundColor Cyan

$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$results = @()

# Objetos KAWASHI_* ficam em varios schemas (SYS, KAWASHI_ENV_*, etc.) - por
# isso DBA_OBJECTS (todo o banco) em vez de ALL_OBJECTS (so o que o usuario
# atual enxerga). Precisa de "/ as sysdba" pra ver os de SYS sem restricao.
$sqlInvalidos = @'
SET PAGESIZE 200
SET FEEDBACK ON
SET LINESIZE 200
SELECT owner, object_name, object_type, status FROM dba_objects
WHERE object_name LIKE 'KAWASHI%' AND status != 'VALID';
EXIT;
'@
$outInvalidos = (Invoke-SqlPlus -ConnectString '/ as sysdba' -Sql $sqlInvalidos) -join "`n"
$results += New-TestResult -Name "Nenhum objeto KAWASHI_* esta INVALID em todo o banco" -Passed ($outInvalidos -match 'no rows selected') -Details $(if ($outInvalidos -notmatch 'no rows selected') { $outInvalidos })

$sqlJobs = @'
SET PAGESIZE 0
SET FEEDBACK OFF
SELECT job_name || '=' || enabled FROM dba_scheduler_jobs
WHERE job_name IN ('KAWASHI_DB_MAINTENANCE_JOB', 'KAWASHI_INDEX_REBUILD_JOB');
EXIT;
'@
$outJobs = (Invoke-SqlPlus -ConnectString $engineerConn -Sql $sqlJobs) -join "`n"
$results += New-TestResult -Name "KAWASHI_DB_MAINTENANCE_JOB existe e esta ENABLED" -Passed ($outJobs -match 'KAWASHI_DB_MAINTENANCE_JOB=TRUE') -Details $(if ($outJobs -notmatch 'KAWASHI_DB_MAINTENANCE_JOB=TRUE') { $outJobs })
$results += New-TestResult -Name "KAWASHI_INDEX_REBUILD_JOB existe e esta ENABLED" -Passed ($outJobs -match 'KAWASHI_INDEX_REBUILD_JOB=TRUE') -Details $(if ($outJobs -notmatch 'KAWASHI_INDEX_REBUILD_JOB=TRUE') { $outJobs })

# Nao basta estar "enabled" (Test-ProfileEHardeningInternals ja cobre
# parametros estaticos) - roda os dois jobs AGORA sob demanda e confirma que
# uma execucao de verdade termina com sucesso, nao so que estao cadastrados.
foreach ($job in 'KAWASHI_DB_MAINTENANCE_JOB', 'KAWASHI_INDEX_REBUILD_JOB') {
    # Os jobs foram criados pelo bootstrap rodando como SYS (ver 07_maintenance_jobs.sql),
    # entao sao donos de SYS. Mesma restricao ja vista em KAWASHI_PASSWORD_VERIFY
    # e KAWASHI_SECURITY_LOG (O7_DICTIONARY_ACCESSIBILITY): mesmo com DBA_SCHEDULER_JOBS
    # mostrando o job pro ENGINEER_USER, DBMS_SCHEDULER.RUN_JOB nele da ORA-27476
    # ("does not exist") quando chamado por uma conta que nao e SYS - precisa de
    # "/ as sysdba".
    $sqlRun = @"
ALTER SESSION SET CONTAINER = FREEPDB1;
BEGIN DBMS_SCHEDULER.RUN_JOB('SYS.$job', use_current_session => TRUE); END;
/
EXIT;
"@
    $outRun = (Invoke-SqlPlus -ConnectString '/ as sysdba' -Sql $sqlRun) -join "`n"
    $results += New-TestResult -Name "$job roda sob demanda sem erro (DBMS_SCHEDULER.RUN_JOB)" -Passed ($outRun -match 'PL/SQL procedure successfully completed') -Details $(if ($outRun -notmatch 'PL/SQL procedure successfully completed') { $outRun })
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
