<#
.SYNOPSIS
    Cria uma conta de SERVICO (a API) no Oracle da Kawashi, que entra num ambiente via proxy
    authentication - o mesmo modelo das pessoas (create-team-member.ps1), mas com o perfil de
    servico (KAWASHI_SERVICE_PROFILE) em vez do perfil de pessoa.

.DESCRIPTION
    Por que um script separado do create-team-member.ps1? Uma conta de API e diferente de uma
    pessoa em tudo que importa para o Oracle (achado real, ver item 14 de
    infra/docs/bugs-primeiro-teste.md):
      - Pool de conexoes: um HikariCP padrao abre 10 conexoes; KAWASHI_SECURE_PROFILE (pessoa)
        limita a 3 sessoes e derrubaria a aplicacao na subida. KAWASHI_SERVICE_PROFILE permite 50.
      - Senha: pessoa tem PASSWORD EXPIRE e troca interativa; uma aplicacao JDBC nunca consegue
        responder a esse prompt. A conta de servico nao expira sozinha.
      - Entrega da credencial: pessoa recebe senha temporaria por canal seguro; a API recebe a
        senha por configuracao (variavel de ambiente / Vault), nunca por um humano digitando.

    Fluxo executado por este script:
      1. Gera uma senha aleatoria forte (24 caracteres, respeita KAWASHI_PASSWORD_VERIFY).
      2. Cria o usuario no Oracle com KAWASHI_SERVICE_PROFILE e SO o privilegio CREATE SESSION.
         A conta NAO tem tablespace, quota nem objetos proprios. Se a conta vazar, ela nao
         enxerga nada fora do ambiente em que foi liberada.
      3. Concede CONNECT THROUGH conforme o -Papel (ver abaixo).
      4. Guarda as credenciais no Vault em kawashi-secrets/api/<conta>.
      5. Opcionalmente (-OutEnvFile) grava as credenciais num arquivo .env local para
         desenvolvimento - esse arquivo NUNCA deve ser versionado.

    DUAS CONTAS POR AMBIENTE (-Papel). Quem entra por proxy no schema do ambiente age como o
    DONO das tabelas, e o dono sempre pode apaga-las. Por isso a API usa duas contas:
      - Execucao (padrao): entra em KAWASHI_ENV_<AMBIENTE>_APP, um schema sem objetos que so
        recebe SELECT/INSERT/UPDATE/DELETE nas tabelas. E a conta que atende os pedidos: se a
        API for invadida, o invasor nao consegue criar, alterar nem apagar tabela.
      - Migracao: entra em KAWASHI_ENV_<AMBIENTE>, o dono. So e usada na subida da aplicacao,
        pelo Flyway, para criar e alterar tabelas.

    A conexao JDBC usa a sintaxe de proxy do driver Oracle no nome do usuario:
        usuario = <conta>[<schema de entrada>]      senha = a senha da PROPRIA conta

    Producao (KAWASHI_ENV_PROD) fica de fora de proposito, igual as pessoas: ninguem alcanca
    producao por proxy. Quando a API for a producao de verdade, essa decisao precisa ser
    tomada de forma explicita (ver TODO em infra/oracle-init/09_environments.sql).

.PARAMETER Username
    Nome da conta de servico (letras/numeros/underscore, comecando com letra, ate 30
    caracteres). Sugestao: API_<AMBIENTE>, ex: API_TESTE_DEV.

.PARAMETER Ambiente
    Ambiente em que a conta entra via proxy (nome curto, sem o prefixo KAWASHI_ENV_).

.PARAMETER Papel
    Execucao (padrao) ou Migracao. Ver "DUAS CONTAS POR AMBIENTE" acima.

.PARAMETER OutEnvFile
    Caminho de um arquivo .env local. Execucao grava DB_URL, DB_SCHEMA, DB_USER e DB_PASSWORD;
    Migracao grava DB_MIGRACAO_USER e DB_MIGRACAO_PASSWORD. Se o arquivo ja existe, as chaves
    sao ACRESCENTADAS (para as duas contas ficarem no mesmo arquivo), mas o script recusa se as
    chaves deste papel ja estiverem la: ele nunca troca uma credencial existente. Use so para
    desenvolvimento local e mantenha o arquivo fora do git.

.PARAMETER EnvFile
    Caminho do .env com as credenciais do ENGINEER_USER (DBA) e do Vault. Padrao: infra/.env.

.EXAMPLE
    ./create-api-account.ps1 -Username API_TESTE_DEV -Ambiente TESTE_DEV

.EXAMPLE
    # As duas contas da API num ambiente, no mesmo .env:
    ./create-api-account.ps1 -Username API_DEV     -Ambiente DEV -OutEnvFile C:\projetos\tabelas-api-banco-usp\.env
    ./create-api-account.ps1 -Username API_DEV_MIG -Ambiente DEV -Papel Migracao -OutEnvFile C:\projetos\tabelas-api-banco-usp\.env

.NOTES
    Requer Docker Desktop com os containers kawashi-oracle e kawashi-vault no ar, e o engine KV
    "kawashi-secrets" ja habilitado no Vault (vault-init.ps1).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,29}$')]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [ValidateSet('TESTE_DEV', 'TESTE_INFRA', 'DEV', 'INFRA', 'HOMOLOG')]
    [string]$Ambiente,

    [ValidateSet('Execucao', 'Migracao')]
    [string]$Papel = 'Execucao',

    [string]$OutEnvFile,

    # Quem responde por esta conta (vai para o cadastro de contas, SYS.KAWASHI_CONTA).
    [ValidatePattern("^[\p{L}0-9 .,\-/()']{1,200}$")]
    [string]$Responsavel,

    [string]$EnvFile
)

$ErrorActionPreference = 'Stop'
# Padrao do -EnvFile calculado AQUI, e nao no bloco param: com [CmdletBinding()], quando o script
# e chamado com "powershell -File", o $PSScriptRoot ainda esta vazio nos valores padrao do param.
if (-not $EnvFile) { $EnvFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\.env' }
$Username = $Username.ToUpper()

# Mesmo motivo do create-team-member.ps1: o sqlplus recebe o SQL como BASE64 dentro de um unico
# argumento (sem BOM do pipe do PowerShell 5.1) e a connect string vai por variavel de ambiente
# (-e), pra caracteres especiais da senha nao serem interpretados pelo shell do container.
function Invoke-SqlPlus {
    param([string]$ConnectString, [string]$Sql)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Sql)
    $b64 = [Convert]::ToBase64String($bytes)
    $innerCmd = 'echo ' + $b64 + ' | base64 -d | sqlplus -s "$ORACLE_CONNSTR"'
    return docker exec -i -e ORACLE_CONNSTR="$ConnectString" -e NLS_LANG=AMERICAN_AMERICA.AL32UTF8 kawashi-oracle sh -c "$innerCmd" 2>&1
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

# Mantido em sincronia de proposito com create-team-member.ps1 (os scripts de infra/scripts sao
# autocontidos, sem biblioteca compartilhada). Sem "@" no conjunto de especiais: e o separador
# do Easy Connect ("usuario/senha@host") e quebraria a connect string.
function New-StrongPassword {
    param(
        [int]$Length = 16,
        [string]$AvoidSubstring
    )
    $upperSet   = [char[]](65..90)
    $lowerSet   = [char[]](97..122)
    $digitSet   = [char[]](48..57)
    $specialSet = [char[]]'!%^*-_=+?'
    $allSets    = $upperSet + $lowerSet + $digitSet + $specialSet

    do {
        $required = @(
            ($upperSet   | Get-Random)
            ($lowerSet   | Get-Random)
            ($digitSet   | Get-Random)
            ($specialSet | Get-Random)
        )
        $fillCount = $Length - $required.Count
        $filler = 1..$fillCount | ForEach-Object { $allSets | Get-Random }
        $password = -join (($required + $filler) | Sort-Object { Get-Random })
    } while ($AvoidSubstring -and $password.ToUpper().Contains($AvoidSubstring.ToUpper()))

    return $password
}

Write-Host "== Kawashi - Conta de API: $Username (ambiente $Ambiente) ==" -ForegroundColor Cyan

# Nome reservado: nao deixa a conta de API colidir com um schema de ambiente/servico.
if ($Username -like 'KAWASHI_ENV_*') {
    throw "Nome '$Username' reservado: contas com prefixo KAWASHI_ENV_ sao schemas de ambiente, nao contas de API."
}

# Validado ANTES de criar qualquer coisa: se o arquivo ja tem as chaves deste papel, nao deixa
# uma conta pela metade. O arquivo pode existir (a outra conta da API mora nele), mas uma
# credencial que ja esta la nunca e trocada.
$chaveDoPapel = if ($Papel -eq 'Migracao') { 'DB_MIGRACAO_USER' } else { 'DB_USER' }
$envJaExiste = $false
if ($OutEnvFile) {
    $OutEnvFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutEnvFile)
    if (Test-Path -LiteralPath $OutEnvFile) {
        $envJaExiste = $true
        if (Select-String -LiteralPath $OutEnvFile -Pattern "^\s*$chaveDoPapel\s*=" -Quiet) {
            throw "O arquivo '$OutEnvFile' ja existe e ja tem $chaveDoPapel. Este script nao troca credenciais existentes - apague a linha, o arquivo, ou escolha outro caminho."
        }
    }
}

$envMap = Get-DotEnv -Path $EnvFile
foreach ($key in 'ENGINEER_USER', 'ENGINEER_USER_PASSWORD', 'VAULT_DEV_ROOT_TOKEN_ID') {
    if (-not $envMap.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($envMap[$key])) {
        throw "Variavel '$key' ausente ou vazia em $EnvFile."
    }
}
$EngineerUser     = $envMap['ENGINEER_USER']
$EngineerPassword = $envMap['ENGINEER_USER_PASSWORD']
$VaultToken       = $envMap['VAULT_DEV_ROOT_TOKEN_ID']

$ApiPassword = New-StrongPassword -Length 24 -AvoidSubstring $Username
$Schema      = "KAWASHI_ENV_$Ambiente"
# Execucao entra no schema _APP (sem objetos, so DML nas tabelas); Migracao entra no dono.
$SchemaDeEntrada = if ($Papel -eq 'Migracao') { $Schema } else { "${Schema}_APP" }
$JdbcUser    = "${Username}[${SchemaDeEntrada}]"

# ---------------------------------------------------------------------------
# 1. Conta no Oracle: perfil de servico, so CREATE SESSION, proxy no schema de entrada
# ---------------------------------------------------------------------------
Write-Host "-> Criando a conta no Oracle (perfil de servico, papel $Papel) e liberando o proxy em $SchemaDeEntrada..."

$grantStatements = @("ALTER USER $SchemaDeEntrada GRANT CONNECT THROUGH $Username;")
$literalResponsavel = if ([string]::IsNullOrWhiteSpace($Responsavel)) { 'NULL' } else { "'" + $Responsavel.Trim().Replace("'", "''") + "'" }

# "WHENEVER SQLERROR EXIT" pelo mesmo motivo do create-team-member.ps1: sem ele, um CREATE USER
# que falha (nome ja existe, ORA-01920) deixaria os GRANTs seguintes rodarem contra a conta que
# ja existia, concedendo acesso de verdade numa tentativa que o script reporta como falha.
$sql = @"
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SESSION SET CONTAINER = FREEPDB1;
CREATE USER $Username IDENTIFIED BY "$ApiPassword" PROFILE KAWASHI_SERVICE_PROFILE;
GRANT CREATE SESSION TO $Username;
$($grantStatements -join "`n")
EXEC SYS.KAWASHI_REGISTRAR_CONTA('$Username', 'API', '$Papel', $literalResponsavel, NULL, '$Ambiente');
EXIT;
"@

$connectString = "$EngineerUser/$EngineerPassword@//localhost:1521/FREEPDB1"
$sqlOutput = Invoke-SqlPlus -ConnectString $connectString -Sql $sql
Write-Verbose ($sqlOutput -join "`n")

if ($sqlOutput -match 'ORA-\d{5}') {
    $texto = ($sqlOutput -join "`n") -replace [regex]::Escape($ApiPassword), '<senha>'
    throw "Falha ao criar a conta de API no Oracle:`n$texto"
}

# ---------------------------------------------------------------------------
# 2. Credenciais no Vault (nunca em texto puro no terminal)
# ---------------------------------------------------------------------------
Write-Host "-> Guardando as credenciais no Vault (kawashi-secrets/api/$Username)..."

$vaultOutput = docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv put "kawashi-secrets/api/$Username" `
    db_username=$Username `
    db_password=$ApiPassword `
    jdbc_user=$JdbcUser `
    ambiente=$Ambiente `
    papel=$Papel `
    schema=$Schema `
    oracle_service="kawashi-oracle:1521/FREEPDB1" 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "A conta '$Username' FOI criada no Oracle, mas gravar no Vault falhou (rode vault-init.ps1 se o Vault foi recriado). Saida:`n$($vaultOutput -join "`n")"
}

# ---------------------------------------------------------------------------
# 3. .env local opcional (desenvolvimento)
# ---------------------------------------------------------------------------
if ($OutEnvFile) {
    $linhas = @()
    if (-not $envJaExiste) { $linhas += '# Gerado por create-api-account.ps1 - NAO versionar este arquivo.' }
    # DB_URL e DB_SCHEMA sao iguais para as duas contas: entram uma vez so.
    foreach ($par in @(@('DB_URL', 'jdbc:oracle:thin:@//localhost:1521/FREEPDB1'), @('DB_SCHEMA', $Schema))) {
        if (-not $envJaExiste -or -not (Select-String -LiteralPath $OutEnvFile -Pattern "^\s*$($par[0])\s*=" -Quiet)) {
            $linhas += "$($par[0])=$($par[1])"
        }
    }
    if ($Papel -eq 'Migracao') {
        $linhas += "DB_MIGRACAO_USER=$JdbcUser"
        $linhas += "DB_MIGRACAO_PASSWORD=$ApiPassword"
    } else {
        $linhas += "DB_USER=$JdbcUser"
        $linhas += "DB_PASSWORD=$ApiPassword"
    }
    $texto = ($linhas -join "`n") + "`n"
    if ($envJaExiste) {
        # Garante que o acrescimo comeca em linha nova, mesmo se o arquivo nao terminar com quebra.
        $atual = [System.IO.File]::ReadAllText($OutEnvFile)
        if ($atual.Length -gt 0 -and -not $atual.EndsWith("`n")) { $texto = "`n" + $texto }
        [System.IO.File]::AppendAllText($OutEnvFile, $texto, [System.Text.UTF8Encoding]::new($false))
        Write-Host "-> Credenciais acrescentadas a $OutEnvFile (mantenha fora do git)."
    } else {
        [System.IO.File]::WriteAllText($OutEnvFile, $texto, [System.Text.UTF8Encoding]::new($false))
        Write-Host "-> Arquivo local de desenvolvimento criado em $OutEnvFile (mantenha fora do git)."
    }
}

Write-Host ""
Write-Host "== Conta de API criada com sucesso ==" -ForegroundColor Green
Write-Host "  Conta Oracle:       $Username  (perfil KAWASHI_SERVICE_PROFILE, so CREATE SESSION)"
Write-Host "  Papel:              $Papel"
Write-Host "  Entra em:           $SchemaDeEntrada (via proxy)"
Write-Host "  Usuario JDBC:       $JdbcUser"
Write-Host "  Senha:              kawashi-secrets/api/$Username no Vault (campo db_password)"
Write-Host ""
Write-Host "A API deve ler a senha de configuracao (variavel de ambiente ou Vault), nunca de arquivo versionado." -ForegroundColor Yellow
