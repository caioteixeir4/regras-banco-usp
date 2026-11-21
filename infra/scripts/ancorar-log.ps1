<#
.SYNOPSIS
    Ancora, FORA do banco, o estado da corrente de LOG_ALTERACAO de cada ambiente, e confere se o
    banco ainda bate com a ultima ancora.

.DESCRIPTION
    O log de alteracoes da aplicacao e encadeado por hash dentro do banco (ver
    infra/oracle-init/11_schema_log.sql): alterar ou apagar uma linha quebra a corrente e a view
    V_LOG_ALTERACAO_QUEBRAS acusa. Mas quem tem DBA consegue recalcular a corrente INTEIRA e deixar
    a view vazia de novo. Enquanto a unica copia do "ultimo hash" mora no mesmo banco que o log,
    esse ataque e invisivel.

    Este script fecha essa porta guardando, no Vault, o numero e o hash da ultima linha gravada
    (a "ancora"). Depois disso, reescrever o passado exige alterar o banco E o Vault.

      -Acao Ancorar   (padrao) Para cada ambiente: confere primeiro a ancora anterior (se existir)
                      e, se estiver tudo certo, grava a ancora nova em
                      kawashi-secrets/log-ancora/<AMBIENTE>. Recusa ancorar por cima de uma
                      divergencia: ancorar um log adulterado legitimaria a adulteracao.
      -Acao Conferir  So confere, nao grava nada. Sai com codigo 1 se houver divergencia.

    O que a conferencia olha, por ambiente:
      1. A view V_LOG_ALTERACAO_QUEBRAS esta vazia (corrente inteira por dentro).
      2. A linha de numero <ordem ancorada> ainda existe e ainda tem o hash ancorado.
      3. O log nao encolheu: a ultima ordem do banco nao e menor que a ancorada.

    Rode o "Ancorar" com frequencia (agendado). Tudo que foi gravado ate a ultima ancora fica
    protegido; o que veio depois dela ainda depende so do banco.

    LIMITES, no ambiente de desenvolvimento:
      - O Vault roda em modo dev (memoria): as ancoras somem quando o container reinicia. Em
        producao o Vault e persistente.
      - Este script usa o token root do Vault, o mesmo do engenheiro que e DBA. Em producao, a
        ancora precisa ser gravada com uma credencial que o DBA nao tem (e, idealmente, num cofre
        que nao aceita reescrever versoes), senao as duas chaves estao na mesma mao.

.PARAMETER Acao
    Ancorar (padrao) ou Conferir.

.PARAMETER Ambiente
    Um ou mais ambientes (nome curto). Padrao: os seis.

.PARAMETER EnvFile
    Caminho do .env com as credenciais do ENGINEER_USER (DBA) e do Vault. Padrao: infra/.env.

.EXAMPLE
    ./ancorar-log.ps1

.EXAMPLE
    ./ancorar-log.ps1 -Acao Conferir -Ambiente TESTE_DEV
#>
[CmdletBinding()]
param(
    [ValidateSet('Ancorar', 'Conferir')]
    [string]$Acao = 'Ancorar',

    [ValidateSet('TESTE_DEV', 'TESTE_INFRA', 'DEV', 'INFRA', 'HOMOLOG', 'PROD')]
    [string[]]$Ambiente = @('TESTE_DEV', 'TESTE_INFRA', 'DEV', 'INFRA', 'HOMOLOG', 'PROD'),

    [string]$EnvFile
)

$ErrorActionPreference = 'Stop'
# Padrao do -EnvFile calculado AQUI, e nao no bloco param: com [CmdletBinding()], quando o script
# e chamado com "powershell -File", o $PSScriptRoot ainda esta vazio nos valores padrao do param.
if (-not $EnvFile) { $EnvFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\.env' }

# Mesmo motivo dos outros scripts: o SQL vai em BASE64 num unico argumento e a connect string por
# variavel de ambiente, pra nada ser interpretado pelo shell do container.
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
        throw "Arquivo .env nao encontrado em '$Path'. Copie infra/.env.example para infra/.env e preencha antes de rodar este script."
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

$envMap = Get-DotEnv -Path $EnvFile
foreach ($key in 'ENGINEER_USER', 'ENGINEER_USER_PASSWORD', 'VAULT_DEV_ROOT_TOKEN_ID') {
    if (-not $envMap.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($envMap[$key])) {
        throw "Variavel '$key' ausente ou vazia em $EnvFile."
    }
}
$connectString = "$($envMap['ENGINEER_USER'])/$($envMap['ENGINEER_USER_PASSWORD'])@//localhost:1521/FREEPDB1"
$VaultToken    = $envMap['VAULT_DEV_ROOT_TOKEN_ID']

function Invoke-Consulta {
    param([string]$Sql)
    $saida = (Invoke-SqlPlus -ConnectString $connectString -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSET LINESIZE 300`nALTER SESSION SET CONTAINER = FREEPDB1;`n$Sql`nEXIT;`n") -join "`n"
    if ($saida -match 'ORA-\d{5}') { throw "Falha ao consultar o banco:`n$saida" }
    return $saida
}

function Get-CampoDaAncora {
    param([string]$Amb, [string]$Campo)
    $argCampo = "-field=$Campo"
    # "Sem ancora ainda" faz o vault escrever na saida de erro; no Windows PowerShell isso viraria
    # excecao com ErrorActionPreference = Stop. A chamada roda com "Continue" e vale o codigo de saida.
    $anterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $valor = docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv get $argCampo "kawashi-secrets/log-ancora/$Amb" 2>&1
        $codigo = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $anterior
    }
    if ($codigo -ne 0) { return $null }
    return (($valor | ForEach-Object { "$_" }) -join '').Trim()
}

Write-Host "== Kawashi - Ancora do log de alteracoes ($Acao) ==" -ForegroundColor Cyan
$divergencias = 0

foreach ($amb in $Ambiente) {
    $log = "KAWASHI_ENV_${amb}_LOG"
    $estado = Invoke-Consulta @"
SELECT 'ESTADO=' || c.ULTIMA_ORDEM || '|' || NVL(c.ULTIMO_HASH, '-') || '|' ||
       (SELECT COUNT(*) FROM $log.V_LOG_ALTERACAO_QUEBRAS) || '|' ||
       (SELECT NVL(MAX(ORDEM), 0) FROM $log.LOG_ALTERACAO)
  FROM $log.LOG_CADEIA c WHERE c.TABELA = 'LOG_ALTERACAO';
"@
    if ($estado -notmatch 'ESTADO=(\d+)\|([0-9a-f]{64}|-)\|(\d+)\|(\d+)') {
        throw "Nao consegui ler o estado da corrente de $log. Saida:`n$estado"
    }
    $ordem = [long]$Matches[1]; $hash = $Matches[2]; $quebras = [int]$Matches[3]; $maiorOrdem = [long]$Matches[4]

    $problemas = @()
    if ($quebras -gt 0) { $problemas += "a corrente tem $quebras problema(s) (ver $log.V_LOG_ALTERACAO_QUEBRAS)" }

    $ordemAncorada = Get-CampoDaAncora -Amb $amb -Campo 'ordem'
    if ($null -ne $ordemAncorada -and $ordemAncorada -ne '') {
        $hashAncorado = Get-CampoDaAncora -Amb $amb -Campo 'hash'
        if ([long]$ordemAncorada -gt 0) {
            $linha = Invoke-Consulta "SELECT 'HASH=' || HASH FROM $log.LOG_ALTERACAO WHERE ORDEM = $([long]$ordemAncorada);"
            if ($linha -notmatch 'HASH=([0-9a-f]{64})') {
                $problemas += "a linha ancorada (ordem $ordemAncorada) nao existe mais no banco"
            } elseif ($Matches[1] -ne $hashAncorado) {
                $problemas += "a linha de ordem $ordemAncorada mudou depois de ancorada (o hash do banco nao e o do Vault)"
            }
        }
        if ($maiorOrdem -lt [long]$ordemAncorada) {
            $problemas += "o log encolheu: a ultima ordem no banco ($maiorOrdem) e menor que a ancorada ($ordemAncorada)"
        }
    }

    if ($problemas.Count -gt 0) {
        $divergencias++
        Write-Host "  [DIVERGENCIA] $amb" -ForegroundColor Red
        $problemas | ForEach-Object { Write-Host "       - $_" -ForegroundColor Red }
        continue
    }

    if ($Acao -eq 'Conferir') {
        $descricao = if ($null -eq $ordemAncorada -or $ordemAncorada -eq '') { 'sem ancora ainda' } else { "bate com a ancora (ordem $ordemAncorada)" }
        Write-Host "  [OK]    $amb - corrente inteira, $descricao; ultima ordem no banco: $ordem" -ForegroundColor Green
        continue
    }

    $quando = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    # Log ainda vazio: o Vault trata "chave=-" como "ler da entrada padrao", entao o marcador e outro.
    $hashParaVault = if ($hash -eq '-') { 'vazio' } else { $hash }
    $saidaVault = docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv put "kawashi-secrets/log-ancora/$amb" `
        ordem=$ordem hash=$hashParaVault ancorado_em=$quando 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Nao consegui gravar a ancora de $amb no Vault (rode vault-init.ps1 se o Vault foi recriado). Saida:`n$($saidaVault -join "`n")"
    }
    Write-Host "  [OK]    $amb - ancorado na ordem $ordem" -ForegroundColor Green
}

if ($divergencias -gt 0) {
    Write-Host ""
    Write-Host "$divergencias ambiente(s) com divergencia. Nada foi ancorado por cima deles: investigue antes." -ForegroundColor Red
    exit 1
}
exit 0
