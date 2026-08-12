<#
.SYNOPSIS
    Verifica se o bootstrap do banco (oracle-init/01 a 09) subiu sem erros silenciosos.

.DESCRIPTION
    Muito PL/SQL deste projeto nunca roda "na hora que voce ve o erro" - triggers, procedures
    e jobs agendados podem compilar com erro (ficando com status INVALID) ou falhar em segundo
    plano (jobs do DBMS_SCHEDULER) sem que ninguem perceba, ate o dia em que alguem precisar
    daquilo e descobrir que estava quebrado o tempo todo. Rode este script logo depois do
    primeiro "docker compose up" pra pegar esse tipo de problema cedo.

    Verifica tres coisas:
      1. Objetos PL/SQL invalidos (trigger/procedure/function que nao compilou).
      2. Erros de compilacao especificos de cada objeto invalido (a causa raiz).
      3. Se os jobs agendados (KAWASHI_DB_MAINTENANCE_JOB, KAWASHI_INDEX_REBUILD_JOB) existem
         e estao habilitados.

.PARAMETER EnvFile
    Caminho do .env com as credenciais do ENGINEER_USER. Padrao: infra/.env.

.EXAMPLE
    ./verify-environment.ps1
#>

[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\.env')
)

$ErrorActionPreference = 'Stop'

function Get-DotEnv {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Arquivo .env nao encontrado em '$Path'."
    }
    $map = @{}
    foreach ($line in Get-Content $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $parts = $trimmed.Split('=', 2)
        if ($parts.Count -eq 2) { $map[$parts[0].Trim()] = $parts[1].Trim() }
    }
    return $map
}

Write-Host "== Kawashi - Verificacao pos-boot do banco ==" -ForegroundColor Cyan

$envMap = Get-DotEnv -Path $EnvFile
foreach ($key in 'ENGINEER_USER', 'ENGINEER_USER_PASSWORD') {
    if (-not $envMap.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($envMap[$key])) {
        throw "Variavel '$key' ausente ou vazia em $EnvFile."
    }
}
$EngineerUser     = $envMap['ENGINEER_USER']
$EngineerPassword = $envMap['ENGINEER_USER_PASSWORD']
$connectString    = "$EngineerUser/$EngineerPassword@//localhost:1521/FREEPDB1"

# ---------------------------------------------------------------------------
# 1 e 2. Objetos invalidos + a causa raiz de cada um (USER_ERRORS)
# ---------------------------------------------------------------------------
Write-Host "-> Checando objetos PL/SQL invalidos..."

$sqlObjetos = @"
SET PAGESIZE 200
SET LINESIZE 200
SELECT object_type, object_name, status FROM all_objects
WHERE owner IN ('SYS') AND object_name LIKE 'KAWASHI%' AND status != 'VALID';
SELECT type, name, line, position, text FROM all_errors
WHERE owner IN ('SYS') AND name LIKE 'KAWASHI%'
ORDER BY name, sequence;
EXIT;
"@

$objetosOutput = $sqlObjetos | docker exec -i kawashi-oracle sqlplus -s $connectString 2>&1
Write-Host $objetosOutput

if ($objetosOutput -match 'no rows selected' -or $objetosOutput -notmatch '\bKAWASHI') {
    Write-Host "   Nenhum objeto KAWASHI_* invalido encontrado." -ForegroundColor Green
} else {
    Write-Host "   ATENCAO: revise a saida acima - pode haver objeto invalido." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 3. Jobs agendados - existem e estao habilitados?
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "-> Checando jobs agendados (DBMS_SCHEDULER)..."

$sqlJobs = @"
SET PAGESIZE 200
SET LINESIZE 200
SELECT job_name, enabled, state, last_start_date, next_run_date
FROM dba_scheduler_jobs
WHERE job_name IN ('KAWASHI_DB_MAINTENANCE_JOB', 'KAWASHI_INDEX_REBUILD_JOB');
SELECT job_name, status, error# , log_date
FROM dba_scheduler_job_run_details
WHERE job_name IN ('KAWASHI_DB_MAINTENANCE_JOB', 'KAWASHI_INDEX_REBUILD_JOB')
ORDER BY log_date DESC
FETCH FIRST 10 ROWS ONLY;
EXIT;
"@

$jobsOutput = $sqlJobs | docker exec -i kawashi-oracle sqlplus -s $connectString 2>&1
Write-Host $jobsOutput

Write-Host ""
Write-Host "== Verificacao concluida - revise a saida acima manualmente == " -ForegroundColor Cyan
Write-Host "Nenhuma linha em 'all_objects'/'all_errors' e o resultado ideal para o passo 1."
Write-Host "Os dois jobs devem aparecer com ENABLED = TRUE no passo 3 (execucoes so aparecem apos o primeiro horario agendado)."
