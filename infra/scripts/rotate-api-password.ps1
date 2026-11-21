<#
.SYNOPSIS
    Troca a senha de uma conta de API sem derrubar a aplicacao: Oracle, Vault e .env da API de uma
    vez, e a senha nunca aparece na tela.

.DESCRIPTION
    A senha das contas de API nao expira sozinha (de proposito: uma API parada de madrugada por
    senha vencida e pior), mas o painel (cadastro-de-contas.ps1) cobra a troca a cada 90 dias. Este
    script e a troca.

    Usa a troca GRADUAL do Oracle 23ai (PASSWORD_ROLLOVER_TIME do KAWASHI_SERVICE_PROFILE, 1 dia):
    logo depois da troca, a senha antiga e a nova valem juntas. Assim:

      1. ./rotate-api-password.ps1 -Username API_DEV -OutEnvFile <.env da API>
           gera a senha nova, troca no Oracle, no Vault e na linha certa do .env
           (DB_PASSWORD para a conta de execucao, DB_MIGRACAO_PASSWORD para a de migracao).
           A API que esta rodando continua com a antiga, sem erro.
      2. reinicie a API (ela le a senha nova do .env).
      3. ./rotate-api-password.ps1 -Username API_DEV -EncerrarSenhaAntiga
           a senha antiga deixa de entrar.

    Se o passo 3 for esquecido, a senha antiga para sozinha depois de 1 dia, e ate la o painel
    mostra a pendencia "senha antiga ainda vale". Com a API parada, -Imediata troca e ja encerra a
    antiga num passo so.

    Recusa conta que nao e de API (perfil KAWASHI_SERVICE_PROFILE). Recusa um -OutEnvFile cujo
    usuario (DB_USER ou DB_MIGRACAO_USER) nao seja esta conta: nao grava a senha de uma conta no
    lugar da de outra.

.PARAMETER Username
    A conta de API.

.PARAMETER OutEnvFile
    O .env da API a atualizar. Sem ele, a senha nova fica so no Oracle e no Vault
    (kawashi-secrets/api/<conta>, campo db_password).

.PARAMETER EncerrarSenhaAntiga
    Nao troca nada: so encerra o periodo em que a senha antiga ainda vale. Rode depois de reiniciar
    a API.

.PARAMETER Imediata
    Troca e encerra a senha antiga na hora. Use com a API parada.

.PARAMETER EnvFile
    Caminho do .env com as credenciais do ENGINEER_USER e do Vault. Padrao: infra/.env.

.EXAMPLE
    ./rotate-api-password.ps1 -Username API_TESTE_DEV_EXEC -OutEnvFile ..\..\..\tabelas-api-banco-usp\.env

.EXAMPLE
    ./rotate-api-password.ps1 -Username API_TESTE_DEV_EXEC -EncerrarSenhaAntiga
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,29}$')]
    [string]$Username,

    [string]$OutEnvFile,

    [switch]$EncerrarSenhaAntiga,

    [switch]$Imediata,

    [string]$EnvFile
)

$ErrorActionPreference = 'Stop'
$aqui = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $EnvFile) { $EnvFile = Join-Path $aqui '..\.env' }
$Username = $Username.ToUpper()
if ($EncerrarSenhaAntiga -and ($Imediata -or $OutEnvFile)) {
    throw "-EncerrarSenhaAntiga so encerra a senha antiga; nao combine com -Imediata nem -OutEnvFile."
}

function Get-DotEnv {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Arquivo .env nao encontrado em '$Path'." }
    $map = @{}
    foreach ($line in Get-Content $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $parts = $trimmed.Split('=', 2)
        if ($parts.Count -eq 2) { $map[$parts[0].Trim()] = $parts[1].Trim() }
    }
    return $map
}

# Mesmo caminho dos outros scripts: SQL em BASE64 e connect string por variavel de ambiente.
function Invoke-SqlPlus {
    param([string]$ConnectString, [string]$Sql)
    $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($Sql))
    $innerCmd = 'echo ' + $b64 + ' | base64 -d | sqlplus -s "$ORACLE_CONNSTR"'
    $anterior = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $saida = docker exec -i -e ORACLE_CONNSTR="$ConnectString" kawashi-oracle sh -c "$innerCmd" 2>&1 | ForEach-Object { "$_" }
    $ErrorActionPreference = $anterior
    return ($saida -join "`n")
}

# Mantido em sincronia com create-api-account.ps1 (sem "@", que quebra a connect string).
function New-StrongPassword {
    param([int]$Length = 24, [string]$AvoidSubstring)
    $upperSet = [char[]](65..90); $lowerSet = [char[]](97..122); $digitSet = [char[]](48..57)
    $specialSet = [char[]]'!%^*-_=+?'
    $allSets = $upperSet + $lowerSet + $digitSet + $specialSet
    do {
        $required = @(($upperSet | Get-Random), ($lowerSet | Get-Random), ($digitSet | Get-Random), ($specialSet | Get-Random))
        $filler = 1..($Length - $required.Count) | ForEach-Object { $allSets | Get-Random }
        $password = -join (($required + $filler) | Sort-Object { Get-Random })
    } while ($AvoidSubstring -and $password.ToUpper().Contains($AvoidSubstring.ToUpper()))
    return $password
}

$envMap = Get-DotEnv -Path $EnvFile
foreach ($key in 'ENGINEER_USER', 'ENGINEER_USER_PASSWORD', 'VAULT_DEV_ROOT_TOKEN_ID') {
    if (-not $envMap.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($envMap[$key])) { throw "Variavel '$key' ausente ou vazia em $EnvFile." }
}
$conexao = "$($envMap['ENGINEER_USER'])/$($envMap['ENGINEER_USER_PASSWORD'])@//localhost:1521/FREEPDB1"
$VaultToken = $envMap['VAULT_DEV_ROOT_TOKEN_ID']

Write-Host "== Kawashi - Senha da conta de API $Username ==" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# A conta existe e e de API? (e qual o papel, para saber qual linha do .env)
# ---------------------------------------------------------------------------
$info = Invoke-SqlPlus $conexao @"
SET PAGESIZE 0
SET FEEDBACK OFF
SET LINESIZE 400
ALTER SESSION SET CONTAINER = FREEPDB1;
SELECT 'INFO|' || u.profile || '|' || u.account_status || '|' || NVL(c.PERFIL, '-') || '|' || NVL(c.AMBIENTE, '-') || '|' ||
       NVL((SELECT MAX(client) FROM dba_proxies WHERE proxy = u.username), '-')
  FROM dba_users u LEFT JOIN SYS.KAWASHI_CONTA c ON c.USERNAME = u.username
 WHERE u.username = '$Username';
EXIT;
"@
$linhaInfo = ($info -split "`n" | Where-Object { $_ -like 'INFO|*' } | Select-Object -First 1)
if (-not $linhaInfo) { throw "Conta '$Username' nao existe no banco." }
$c = $linhaInfo.Split('|')
$perfilSenha = $c[1]; $status = $c[2]; $papel = $c[3]; $schemaDeEntrada = $c[5]
if ($perfilSenha -ne 'KAWASHI_SERVICE_PROFILE') {
    throw "A conta '$Username' nao e de API (perfil $perfilSenha). Senha de pessoa e trocada pela propria pessoa, no primeiro login e a cada 90 dias."
}

# ---------------------------------------------------------------------------
# So encerrar a senha antiga
# ---------------------------------------------------------------------------
if ($EncerrarSenhaAntiga) {
    if ($status -notmatch 'ROLLOVER') {
        Write-Host "Nao havia troca em andamento: a senha antiga ja nao vale (status: $status)."
        exit 0
    }
    $r = Invoke-SqlPlus $conexao "ALTER SESSION SET CONTAINER = FREEPDB1;`nALTER USER $Username EXPIRE PASSWORD ROLLOVER PERIOD;`nEXIT;`n"
    if ($r -match 'ORA-\d{5}') { throw "Nao consegui encerrar a senha antiga:`n$r" }
    Write-Host "Senha antiga encerrada: a partir de agora so a nova entra." -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------------------
# Antes de trocar: o .env indicado e mesmo desta conta?
# ---------------------------------------------------------------------------
if ($papel -eq '-') { $papel = if ($schemaDeEntrada -like '*_APP') { 'Execucao' } else { 'Migracao' } }
$chaveUsuario = if ($papel -eq 'Migracao') { 'DB_MIGRACAO_USER' } else { 'DB_USER' }
$chaveSenha   = if ($papel -eq 'Migracao') { 'DB_MIGRACAO_PASSWORD' } else { 'DB_PASSWORD' }
if ($OutEnvFile) {
    $OutEnvFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutEnvFile)
    $apiEnv = Get-DotEnv -Path $OutEnvFile
    if (-not $apiEnv.ContainsKey($chaveUsuario) -or $apiEnv[$chaveUsuario] -notlike "$Username[[]*") {
        throw "O arquivo '$OutEnvFile' nao e desta conta: $chaveUsuario la e '$($apiEnv[$chaveUsuario])', esperado '$Username[...]'. Nada foi trocado."
    }
    if (-not $apiEnv.ContainsKey($chaveSenha)) { throw "O arquivo '$OutEnvFile' nao tem a linha $chaveSenha. Nada foi trocado." }
}
if ($status -match 'ROLLOVER') {
    throw "Ja ha uma troca em andamento para '$Username'. Encerre a anterior (-EncerrarSenhaAntiga) antes de trocar de novo."
}

# ---------------------------------------------------------------------------
# 1. Oracle
# ---------------------------------------------------------------------------
$senha = New-StrongPassword -Length 24 -AvoidSubstring $Username
Write-Host "-> Oracle: trocando a senha (troca gradual: a antiga ainda vale ate ser encerrada)..."
$r = Invoke-SqlPlus $conexao "WHENEVER SQLERROR EXIT SQL.SQLCODE`nALTER SESSION SET CONTAINER = FREEPDB1;`nALTER USER $Username IDENTIFIED BY `"$senha`";`nEXIT;`n"
if ($r -match 'ORA-\d{5}') { throw "O Oracle recusou a troca:`n$($r -replace [regex]::Escape($senha), '<senha>')" }

# ---------------------------------------------------------------------------
# 2. Vault
# ---------------------------------------------------------------------------
Write-Host "-> Vault: gravando a senha nova em kawashi-secrets/api/$Username..."
$anterior = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv patch "kawashi-secrets/api/$Username" "db_password=$senha" 2>&1 | Out-Null
$okVault = ($LASTEXITCODE -eq 0)
if (-not $okVault) {
    # O segredo nao existe (Vault de desenvolvimento reiniciado): grava de novo, completo.
    $ambiente = if ($c[4] -ne '-') { $c[4] } else { ($schemaDeEntrada -replace '^KAWASHI_ENV_', '' -replace '_APP$', '') }
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv put "kawashi-secrets/api/$Username" `
        "db_username=$Username" "db_password=$senha" "jdbc_user=$Username[$schemaDeEntrada]" "ambiente=$ambiente" "papel=$papel" `
        "schema=KAWASHI_ENV_$ambiente" "oracle_service=kawashi-oracle:1521/FREEPDB1" 2>&1 | Out-Null
    $okVault = ($LASTEXITCODE -eq 0)
}
$ErrorActionPreference = $anterior
if (-not $okVault) { Write-Host "   AVISO: nao consegui gravar no Vault (ele esta no ar? rode vault-init.ps1). O Oracle ja tem a senha nova." -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# 3. .env da API (so a linha da senha; o resto do arquivo fica como estava)
# ---------------------------------------------------------------------------
if ($OutEnvFile) {
    Write-Host "-> .env da API: regravando so a linha $chaveSenha..."
    $linhas = [System.IO.File]::ReadAllLines($OutEnvFile)
    for ($i = 0; $i -lt $linhas.Count; $i++) {
        if ($linhas[$i] -match "^\s*$chaveSenha\s*=") { $linhas[$i] = "$chaveSenha=$senha" }
    }
    [System.IO.File]::WriteAllLines($OutEnvFile, $linhas, [System.Text.UTF8Encoding]::new($false))
}

# ---------------------------------------------------------------------------
# 4. Encerrar a antiga ja (so com -Imediata)
# ---------------------------------------------------------------------------
if ($Imediata) {
    $r = Invoke-SqlPlus $conexao "ALTER SESSION SET CONTAINER = FREEPDB1;`nALTER USER $Username EXPIRE PASSWORD ROLLOVER PERIOD;`nEXIT;`n"
    if ($r -match 'ORA-\d{5}') { throw "A senha nova foi gravada, mas encerrar a antiga falhou:`n$r" }
}
$senha = $null

Write-Host ""
Write-Host "== Senha de $Username trocada ==" -ForegroundColor Green
if ($Imediata) {
    Write-Host "A senha antiga ja nao vale. Suba a API (ela le a senha nova do .env)."
} else {
    Write-Host "A senha antiga AINDA vale (no maximo 1 dia), para a API que esta rodando nao cair."
    Write-Host "Proximos passos:"
    Write-Host "  1. reinicie a API"
    Write-Host "  2. ./rotate-api-password.ps1 -Username $Username -EncerrarSenhaAntiga"
}
