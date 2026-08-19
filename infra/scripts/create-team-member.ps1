<#
.SYNOPSIS
    Cria um novo usuario de time no Oracle da Kawashi e entrega a senha inicial via Vault
    (sem senha nenhuma passando por chat, .env ou texto puro em qualquer arquivo do repo).

.DESCRIPTION
    Fluxo executado por este script:
      1. Gera uma senha aleatoria forte para o novo usuario Oracle (respeita a politica de
         KAWASHI_PASSWORD_VERIFY: 12+ chars, maiuscula, minuscula, numero, especial).
      2. Cria o usuario no Oracle (via docker exec + sqlplus dentro do container kawashi-oracle),
         aplica KAWASHI_SECURE_PROFILE, concede as roles indicadas e forca troca de senha no
         primeiro login (PASSWORD EXPIRE).
      3. Cria uma policy e um login proprio (userpass) no Vault, restrito aos caminhos do
         proprio usuario:
           - kawashi-secrets/onboarding/<usuario>  -> leitura/exclusao (senha temporaria do Oracle)
           - kawashi-secrets/engineers/<usuario>   -> leitura/escrita (senha definitiva, quando a
                                                       pessoa trocar e quiser guardar no cofre)
           - auth/userpass/users/<usuario>         -> permissao para trocar a propria senha do Vault
      4. Guarda a senha temporaria do Oracle dentro do proprio Vault (kawashi-secrets/onboarding/<usuario>),
         nunca em .env, nunca em texto puro no terminal alem do resumo final impresso pra voce repassar.

.PARAMETER Username
    Nome do novo usuario Oracle (tambem usado como login do Vault). Letras/numeros/underscore,
    comecando com letra, ate 30 caracteres.

.PARAMETER Profile
    Perfil da pessoa dentro do fluxo de ambientes (ver infra/oracle-init/09_environments.sql).
    Cada perfil traduz automaticamente em quais ambientes a pessoa pode escrever, via proxy
    authentication (CONNECT THROUGH) - a pessoa nunca sabe/precisa de senha do ambiente em si:

      Estagiario     -> CONNECT THROUGH KAWASHI_ENV_TESTE (so Teste)
      Desenvolvedor  -> CONNECT THROUGH KAWASHI_ENV_DEV e KAWASHI_ENV_HOMOLOG
      Infra          -> CONNECT THROUGH KAWASHI_ENV_INFRA e KAWASHI_ENV_HOMOLOG, + ROLE_KAWASHI_INFRA
      HomologViewer  -> so leitura (SELECT) em Homologacao, via ROLE_KAWASHI_HOMOLOG_VIEWER -
                        sem proxy, sem escrita em lugar nenhum. Pensado para QA/negocio que so
                        precisa ver a tela em homologacao, nao commitar codigo.

    Ninguem cria usuario com acesso a KAWASHI_ENV_PROD por este script - producao so e
    alcancada pelo ENGINEER_USER (DBA), de proposito.

.PARAMETER Roles
    Roles Oracle extras a conceder, alem do que o -Profile ja concede. Use para excecoes
    pontuais - o caminho normal e o -Profile cobrir tudo que a pessoa precisa.

.PARAMETER EnvFile
    Caminho do .env com as credenciais do ENGINEER_USER (DBA) e do Vault. Padrao: infra/.env.

.EXAMPLE
    ./create-team-member.ps1 -Username JOAO_SILVA -Profile Desenvolvedor

.EXAMPLE
    ./create-team-member.ps1 -Username MARIA_QA -Profile HomologViewer

.NOTES
    Requer Docker Desktop com os containers kawashi-oracle e kawashi-vault no ar
    (docker compose up), e o engine KV "kawashi-secrets" ja habilitado no Vault.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,29}$')]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Estagiario', 'Desenvolvedor', 'Infra', 'HomologViewer')]
    [string]$Profile,

    [string[]]$Roles = @(),

    [string]$EnvFile = (Join-Path $PSScriptRoot '..\.env')
)

$ErrorActionPreference = 'Stop'
$Username = $Username.ToUpper()

# CORRIGIDO (achado testando ao vivo): o PowerShell 5.1 sempre insere um BOM
# UTF-8 no inicio de qualquer conteudo enviado via pipe "|" pra um processo
# externo - nem $OutputEncoding nem trocar de codificacao resolvem isso (e
# uma particularidade do pipeline do PowerShell 5.1 em si, nao da ferramenta
# de destino). O sqlplus e o "vault policy write" leem esse BOM como parte do
# primeiro comando/linha e o rejeitam (SP2-0734 / "illegal char").
#
# A solucao que realmente funciona: em vez de fazer pipe do conteudo (heredoc)
# pro processo, mandamos o conteudo como BASE64 dentro de um unico argumento
# de linha de comando (que o PowerShell passa sem BOM e sem interpretacao de
# shell), e decodificamos DENTRO do container antes de repassar pro sqlplus/
# vault. Dados sensiveis (connect string com senha) tambem NAO vao embutidos
# como texto na string do comando shell - vao via variavel de ambiente (-e),
# evitando que caracteres especiais da senha (%, ^, etc.) sejam interpretados
# por engano pelo shell dentro do container.
function Invoke-SqlPlus {
    param([string]$ConnectString, [string]$Sql)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Sql)
    $b64 = [Convert]::ToBase64String($bytes)
    $innerCmd = 'echo ' + $b64 + ' | base64 -d | sqlplus -s "$ORACLE_CONNSTR"'
    return docker exec -i -e ORACLE_CONNSTR="$ConnectString" kawashi-oracle sh -c "$innerCmd" 2>&1
}

function Write-VaultPolicy {
    param([string]$VaultToken, [string]$PolicyName, [string]$PolicyHcl)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($PolicyHcl)
    $b64 = [Convert]::ToBase64String($bytes)
    $innerCmd = 'echo ' + $b64 + ' | base64 -d | vault policy write ' + $PolicyName + ' -'
    return docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault sh -c "$innerCmd" 2>&1
}

# Traduz o -Profile em comandos SQL concretos (proxy authentication ou role de
# leitura). Ver infra/oracle-init/09_environments.sql para o racional completo
# de por que cada perfil recebe exatamente esses ambientes.
function Get-ProfileStatements {
    param([string]$Profile, [string]$Username)

    switch ($Profile) {
        'Estagiario' {
            return @(
                "ALTER USER KAWASHI_ENV_TESTE GRANT CONNECT THROUGH $Username;"
            )
        }
        'Desenvolvedor' {
            return @(
                "ALTER USER KAWASHI_ENV_DEV GRANT CONNECT THROUGH $Username;",
                "ALTER USER KAWASHI_ENV_HOMOLOG GRANT CONNECT THROUGH $Username;"
            )
        }
        'Infra' {
            return @(
                "ALTER USER KAWASHI_ENV_INFRA GRANT CONNECT THROUGH $Username;",
                "ALTER USER KAWASHI_ENV_HOMOLOG GRANT CONNECT THROUGH $Username;",
                "GRANT ROLE_KAWASHI_INFRA TO $Username;"
            )
        }
        'HomologViewer' {
            return @(
                "GRANT ROLE_KAWASHI_HOMOLOG_VIEWER TO $Username;"
            )
        }
    }
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

function New-StrongPassword {
    param(
        [int]$Length = 16,
        [string]$AvoidSubstring
    )
    $upperSet   = [char[]](65..90)
    $lowerSet   = [char[]](97..122)
    $digitSet   = [char[]](48..57)
    $specialSet = [char[]]'!@#%^*-_=+?'
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

Write-Host "== Kawashi - Onboarding de novo usuario: $Username ==" -ForegroundColor Cyan

$envMap = Get-DotEnv -Path $EnvFile
foreach ($key in 'ENGINEER_USER', 'ENGINEER_USER_PASSWORD', 'VAULT_DEV_ROOT_TOKEN_ID') {
    if (-not $envMap.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($envMap[$key])) {
        throw "Variavel '$key' ausente ou vazia em $EnvFile."
    }
}
$EngineerUser     = $envMap['ENGINEER_USER']
$EngineerPassword = $envMap['ENGINEER_USER_PASSWORD']
$VaultToken       = $envMap['VAULT_DEV_ROOT_TOKEN_ID']

$TempDbPassword    = New-StrongPassword -Length 16 -AvoidSubstring $Username
$TempVaultPassword = New-StrongPassword -Length 16

# ---------------------------------------------------------------------------
# 1. Criacao do usuario no Oracle
# ---------------------------------------------------------------------------
Write-Host "-> Criando usuario Oracle e aplicando politica de seguranca (perfil: $Profile)..."

$profileStatements = (Get-ProfileStatements -Profile $Profile -Username $Username) -join "`n"
$extraRoleStatements = ($Roles | ForEach-Object { "GRANT $_ TO $Username;" }) -join "`n"
$grantStatements = @($profileStatements, $extraRoleStatements) -join "`n"

$sql = @"
ALTER SESSION SET CONTAINER = FREEPDB1;
CREATE USER $Username IDENTIFIED BY "$TempDbPassword" PROFILE KAWASHI_SECURE_PROFILE DEFAULT TABLESPACE TS_KAWASHI_DATA;
ALTER USER $Username QUOTA 500M ON TS_KAWASHI_DATA;
GRANT CREATE SESSION TO $Username;
$grantStatements
ALTER USER $Username PASSWORD EXPIRE;
EXIT;
"@

$connectString = "$EngineerUser/$EngineerPassword@//localhost:1521/FREEPDB1"
$sqlOutput = Invoke-SqlPlus -ConnectString $connectString -Sql $sql
Write-Verbose ($sqlOutput -join "`n")

if ($sqlOutput -match 'ORA-\d{5}') {
    throw "Falha ao criar usuario no Oracle:`n$($sqlOutput -join "`n")"
}

# ---------------------------------------------------------------------------
# 2. Policy + login pessoal no Vault (userpass), escopado aos caminhos do usuario
# ---------------------------------------------------------------------------
Write-Host "-> Configurando acesso pessoal no Vault..."

$policyName = "engineer-$($Username.ToLower())"
$policyHcl = @"
path "kawashi-secrets/data/onboarding/$Username" {
  capabilities = ["read", "delete"]
}

path "kawashi-secrets/data/engineers/$Username" {
  capabilities = ["create", "read", "update"]
}

path "auth/userpass/users/$Username" {
  capabilities = ["update"]
}
"@

Write-VaultPolicy -VaultToken $VaultToken -PolicyName $policyName -PolicyHcl $policyHcl | Out-Null

# Habilita o metodo de login userpass uma unica vez (ignora erro se ja existir).
# CORRIGIDO (achado testando ao vivo): docker exec retorna a saida como um
# ARRAY de linhas no PowerShell - "-notmatch" contra um array filtra elemento
# por elemento (quase sempre sobra alguma linha que nao bate com "userpass/",
# ja que o JSON tem varias linhas), entao a condicao praticamente sempre dava
# TRUE mesmo com o metodo ja habilitado. Juntando tudo numa unica string
# antes de comparar, o -notmatch passa a checar o conteudo inteiro de uma vez.
$authList = (docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault auth list -format=json 2>&1) -join "`n"
if ($authList -notmatch 'userpass/') {
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault auth enable userpass | Out-Null
}

docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault write "auth/userpass/users/$Username" `
    password=$TempVaultPassword policies=$policyName | Out-Null

# ---------------------------------------------------------------------------
# 3. Senha temporaria do Oracle guardada no proprio Vault (nunca em .env)
# ---------------------------------------------------------------------------
docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv put "kawashi-secrets/onboarding/$Username" `
    db_username=$Username `
    db_password=$TempDbPassword `
    oracle_service="kawashi-oracle:1521/FREEPDB1" `
    note="Senha temporaria - expira no primeiro login no Oracle. Delete este segredo depois de ler." | Out-Null

# ---------------------------------------------------------------------------
# Resumo para o admin repassar com seguranca (nao cole isso em chat aberto/commit)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "== Usuario criado com sucesso ==" -ForegroundColor Green
Write-Host "Repasse estas duas informacoes ao novo integrante por um canal seguro (ex: DM, nao um canal publico):"
Write-Host ""
Write-Host "  URL do Vault:        http://localhost:8200"
Write-Host "  Login do Vault:      $Username"
Write-Host "  Senha temporaria do Vault: $TempVaultPassword"
Write-Host ""
Write-Host "Peca para a pessoa seguir o guia: infra/docs/onboarding-novo-membro.md"
Write-Host ""
Write-Host "LEMBRETE: se a whitelist de IP (KAWASHI_ALLOWED_IPS) ja estiver em modo de" -ForegroundColor Yellow
Write-Host "bloqueio ativo, cadastre o IP da maquina dessa pessoa la ANTES do primeiro login dela." -ForegroundColor Yellow
Write-Host "Perfil: $Profile"
if ($Roles.Count -gt 0) {
    Write-Host "Roles extras concedidas: $($Roles -join ', ')"
}
