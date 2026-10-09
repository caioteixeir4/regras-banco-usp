<#
.SYNOPSIS
    Concede acesso a schema(s) de SERVICO (SEFAZ, SIMPLES_NACIONAL, etc.) a um usuario
    Oracle QUE JA EXISTE, sem recriar a conta do zero.

.DESCRIPTION
    create-team-member.ps1 so aceita -Servicos no momento da CRIACAO do usuario - rodar
    aquele script de novo contra um -Username ja existente falha com ORA-01920 (nome ja
    existe) antes mesmo de chegar nos grants de servico. Isso deixa sem solucao o caso
    comum do dia a dia: uma pessoa que ja tem conta (ex: Desenvolvedor sem nenhum servico)
    e que, meses depois, entra no time da SEFAZ - ela nao devia precisar de uma conta nova
    so por causa disso.

    Este script resolve exatamente esse caso, como uma acao SEPARADA e EXPLICITA (nunca
    automatica): concede CONNECT THROUGH no(s) schema(s) KAWASHI_ENV_<AMBIENTE>_<SERVICO>
    de cada ambiente que o usuario JA alcanca hoje - descobrindo "quais ambientes ja
    alcanca" consultando DBA_PROXIES de verdade (a fonte da verdade do Oracle), em vez de
    tentar adivinhar ou pedir pra informar de novo qual -Profile a pessoa tem (isso nao
    fica gravado em lugar nenhum do Oracle - so os grants de proxy em si existem).

    Continua valendo a mesma regra de 09_environments.sql secao 2.1 e de
    create-team-member.ps1: por padrao (sem rodar este script) um perfil so enxerga as
    tabelas PADRAO do(s) ambiente(s) dele - nenhum servico extra e concedido sozinho. Dar
    um servico a todo mundo (ou a varias pessoas) nao tem problema nenhum nesse desenho -
    so precisa ser uma decisao explicita, uma chamada deste script por pessoa (ou por
    script/loop de quem estiver automatizando o onboarding em lote), nunca algo que o
    -Profile jogue sozinho.

.PARAMETER Username
    Nome do usuario Oracle que JA EXISTE (criado antes via create-team-member.ps1).

.PARAMETER Servicos
    Um ou mais servicos a liberar (SEFAZ, SIMPLES_NACIONAL). Para cada um, concede CONNECT
    THROUGH no schema KAWASHI_ENV_<AMBIENTE>_<SERVICO> de TODO ambiente que o usuario ja
    alcanca hoje (descoberto via DBA_PROXIES, nao perguntado). Idempotente: rodar de novo
    com um servico ja concedido nao da erro (ALTER USER ... GRANT CONNECT THROUGH e
    idempotente no Oracle - testado ao vivo).

.PARAMETER EnvFile
    Caminho do .env com as credenciais do ENGINEER_USER. Padrao: infra/.env.

.EXAMPLE
    ./grant-service-access.ps1 -Username JOAO_SILVA -Servicos SEFAZ

.EXAMPLE
    ./grant-service-access.ps1 -Username MARIA_INFRA -Servicos SEFAZ, SIMPLES_NACIONAL

.NOTES
    Requer que -Username ja exista e tenha pelo menos um ambiente via proxy (DBA_PROXIES) -
    nao se aplica a um usuario HomologViewer (que nunca usa proxy) nem a um -Username que
    nao existe. Nao faz nada com Vault: isto so ajusta grant no Oracle, nao mexe em login
    nem em segredo de ninguem.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,29}$')]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [ValidateCount(1, 2)]
    [ValidateSet('SEFAZ', 'SIMPLES_NACIONAL')]
    [string[]]$Servicos,

    [string]$EnvFile = (Join-Path $PSScriptRoot '..\.env')
)

$ErrorActionPreference = 'Stop'
$Username = $Username.ToUpper()

# Mesmo padrao BOM-safe (base64 via argumento, nao pipe) ja usado em
# create-team-member.ps1 e infra/tests/lib/TestHelpers.ps1 - mantido em
# sincronia de proposito, ver bugs-primeiro-teste.md item 5.
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

# Os 6 schemas de ambiente "puros" (sem sufixo de servico) - usado pra filtrar
# o resultado de DBA_PROXIES e distinguir "ambiente de verdade" de um schema de
# servico que o usuario ja tenha (nao faz sentido anexar SEFAZ em cima de um
# schema que ja e KAWASHI_ENV_DEV_SEFAZ).
$AMBIENTES_BASE = @('TESTE_DEV', 'TESTE_INFRA', 'DEV', 'INFRA', 'HOMOLOG', 'PROD')

Write-Host "== Kawashi - Concedendo acesso a servico(s) para usuario existente: $Username ==" -ForegroundColor Cyan

$envMap = Get-DotEnv -Path $EnvFile
foreach ($key in 'ENGINEER_USER', 'ENGINEER_USER_PASSWORD') {
    if (-not $envMap.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($envMap[$key])) {
        throw "Variavel '$key' ausente ou vazia em $EnvFile."
    }
}
$connectString = "$($envMap['ENGINEER_USER'])/$($envMap['ENGINEER_USER_PASSWORD'])@//localhost:1521/FREEPDB1"

# ---------------------------------------------------------------------------
# 1. O usuario precisa ja existir
# ---------------------------------------------------------------------------
$sqlExiste = "SET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT username FROM dba_users WHERE username = '$Username';`nEXIT;`n"
$outExiste = (Invoke-SqlPlus -ConnectString $connectString -Sql $sqlExiste) -join "`n"
if ($outExiste -notmatch [regex]::Escape($Username)) {
    throw "Usuario '$Username' nao existe. Crie primeiro com create-team-member.ps1 (sem -Servicos, se for o caso) e so depois rode este script."
}

# ---------------------------------------------------------------------------
# 2. Descobrir, via DBA_PROXIES (fonte da verdade - nao perguntamos o
#    -Profile de volta porque isso nao fica gravado em lugar nenhum), em quais
#    ambientes "puros" este usuario ja e PROXY hoje.
#
#    CUIDADO COM A DIRECAO: confirmado ao vivo que "ALTER USER X GRANT CONNECT
#    THROUGH Y" grava CLIENT=X (o ambiente) e PROXY=Y (a pessoa) em
#    DBA_PROXIES - o inverso do que o nome das colunas sugere a primeira
#    vista. A consulta certa pra "em quais ambientes a pessoa Y entra" e
#    "SELECT client FROM dba_proxies WHERE proxy = 'Y'", nunca o contrario.
# ---------------------------------------------------------------------------
$sqlProxies = "SET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT client FROM dba_proxies WHERE proxy = '$Username';`nEXIT;`n"
$outProxies = Invoke-SqlPlus -ConnectString $connectString -Sql $sqlProxies

$ambientesDoUsuario = @()
foreach ($linha in $outProxies) {
    $schema = $linha.Trim()
    if ($schema -notmatch '^KAWASHI_ENV_(.+)$') { continue }
    $nomeCurto = $Matches[1]
    if ($AMBIENTES_BASE -contains $nomeCurto) { $ambientesDoUsuario += $nomeCurto }
}
$ambientesDoUsuario = $ambientesDoUsuario | Select-Object -Unique

if ($ambientesDoUsuario.Count -eq 0) {
    throw "Usuario '$Username' nao tem proxy em nenhum ambiente (DBA_PROXIES vazio pra ele) - -Servicos nao se aplica. Isso e esperado pra um perfil HomologViewer (so leitura, sem proxy); pra qualquer outro perfil, confirme que create-team-member.ps1 rodou sem erro."
}

Write-Host "-> Usuario ja alcanca: $($ambientesDoUsuario -join ', ')"

# ---------------------------------------------------------------------------
# 3. Conceder CONNECT THROUGH no(s) schema(s) de servico correspondentes
# ---------------------------------------------------------------------------
$grantStatements = @()
foreach ($servico in $Servicos) {
    foreach ($ambiente in $ambientesDoUsuario) {
        $grantStatements += "ALTER USER KAWASHI_ENV_${ambiente}_${servico} GRANT CONNECT THROUGH $Username;"
    }
}

$sql = @"
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SESSION SET CONTAINER = FREEPDB1;
$($grantStatements -join "`n")
EXIT;
"@

$sqlOutput = Invoke-SqlPlus -ConnectString $connectString -Sql $sql
Write-Verbose ($sqlOutput -join "`n")

if ($sqlOutput -match 'ORA-\d{5}') {
    throw "Falha concedendo acesso de servico:`n$($sqlOutput -join "`n")"
}

Write-Host ""
Write-Host "== Acesso concedido com sucesso ==" -ForegroundColor Green
foreach ($servico in $Servicos) {
    $schemas = $ambientesDoUsuario | ForEach-Object { "KAWASHI_ENV_${_}_${servico}" }
    Write-Host "  ${servico}: $($schemas -join ', ')"
}
Write-Host ""
Write-Host "Nenhuma senha ou login mudou - a pessoa usa a MESMA senha de sempre, so que agora" -ForegroundColor Yellow
Write-Host "tambem pode proxyar pros schemas de servico listados acima." -ForegroundColor Yellow
