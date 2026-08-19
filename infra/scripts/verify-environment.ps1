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

# CORRIGIDO (achado testando ao vivo): o PowerShell 5.1 sempre insere um BOM
# UTF-8 no inicio de qualquer conteudo enviado via pipe "|" pra um processo
# externo, independente de $OutputEncoding - o sqlplus le esse BOM como parte
# do primeiro comando e o rejeita (SP2-0734). A solucao que realmente
# funciona: mandar o SQL como BASE64 num argumento de linha de comando (sem
# BOM, sem interpretacao de shell) e decodificar dentro do container antes de
# repassar pro sqlplus. A connect string (com senha) vai via variavel de
# ambiente, nao embutida na string do shell, pra nao arriscar caracteres
# especiais da senha sendo interpretados pelo shell dentro do container.
function Invoke-SqlPlus {
    param([string]$ConnectString, [string]$Sql)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Sql)
    $b64 = [Convert]::ToBase64String($bytes)
    $innerCmd = 'echo ' + $b64 + ' | base64 -d | sqlplus -s "$ORACLE_CONNSTR"'
    return docker exec -i -e ORACLE_CONNSTR="$ConnectString" kawashi-oracle sh -c "$innerCmd" 2>&1
}

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

$objetosOutput = Invoke-SqlPlus -ConnectString $connectString -Sql $sqlObjetos
Write-Host $objetosOutput

# CORRIGIDO (achado testando ao vivo, mesmo bug do create-team-member.ps1):
# docker exec retorna array de linhas - "-notmatch" filtrado elemento a
# elemento praticamente sempre da "verdadeiro" (quase sempre sobra alguma
# linha sem 'KAWASHI'), o que mascararia um objeto invalido de verdade.
# Juntar numa string antes de comparar resolve.
$objetosOutputStr = $objetosOutput -join "`n"
if ($objetosOutputStr -match 'no rows selected' -or $objetosOutputStr -notmatch '\bKAWASHI') {
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

$jobsOutput = Invoke-SqlPlus -ConnectString $connectString -Sql $sqlJobs
Write-Host $jobsOutput

Write-Host ""
Write-Host "== Verificacao concluida - revise a saida acima manualmente == " -ForegroundColor Cyan
Write-Host "Nenhuma linha em 'all_objects'/'all_errors' e o resultado ideal para o passo 1."
Write-Host "Os dois jobs devem aparecer com ENABLED = TRUE no passo 3 (execucoes so aparecem apos o primeiro horario agendado)."
