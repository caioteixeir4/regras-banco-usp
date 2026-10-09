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

      EstagiarioDev   -> CONNECT THROUGH KAWASHI_ENV_TESTE_DEV (so o teste do time de Dev)
      EstagiarioInfra -> CONNECT THROUGH KAWASHI_ENV_TESTE_INFRA (so o teste do time de Infra)
      Desenvolvedor   -> CONNECT THROUGH KAWASHI_ENV_DEV e KAWASHI_ENV_HOMOLOG
      Infra           -> CONNECT THROUGH KAWASHI_ENV_INFRA e KAWASHI_ENV_HOMOLOG, + ROLE_KAWASHI_INFRA
      HomologViewer   -> so leitura (SELECT) em Homologacao, via ROLE_KAWASHI_HOMOLOG_VIEWER -
                        sem proxy, sem escrita em lugar nenhum. Pensado para QA/negocio que so
                        precisa ver a tela em homologacao, nao commitar codigo.

    Ninguem cria usuario com acesso a KAWASHI_ENV_PROD por este script - producao so e
    alcancada pelo ENGINEER_USER (DBA), de proposito.

    CORRIGIDO: ate a versao anterior deste script existia um unico perfil "Estagiario" (so
    ambiente TESTE, compartilhado por qualquer time). Virou EstagiarioDev/EstagiarioInfra,
    espelhando a separacao que ja existia entre Desenvolvedor/Infra um nivel acima.

.PARAMETER Servicos
    Liberacao ADITIVA e INDEPENDENTE do -Profile para schemas de SERVICO (segmentacao por dominio
    de negocio dentro de cada ambiente - ver secao 2.1 de infra/oracle-init/09_environments.sql).
    Para cada servico pedido, concede CONNECT THROUGH no schema KAWASHI_ENV_<AMBIENTE>_<SERVICO>
    de TODO ambiente que o -Profile escolhido ja alcanca - ex: -Profile Desenvolvedor -Servicos
    SEFAZ da proxy em KAWASHI_ENV_DEV_SEFAZ E KAWASHI_ENV_HOMOLOG_SEFAZ (porque Desenvolvedor
    alcanca os dois), sem tocar em nenhum schema SIMPLES_NACIONAL. Nao informar -Servicos
    continua sendo valido - a pessoa so enxerga as tabelas PADRAO do(s) ambiente(s) do seu perfil.
    Nao se aplica ao perfil HomologViewer (nao usa proxy em nenhum ambiente).

.PARAMETER Roles
    Roles Oracle extras a conceder, alem do que o -Profile ja concede. Use para excecoes
    pontuais - o caminho normal e o -Profile cobrir tudo que a pessoa precisa. Restrito as
    roles proprias da Kawashi (ROLE_KAWASHI_DEVELOPER, ROLE_KAWASHI_INFRA,
    ROLE_KAWASHI_HOMOLOG_VIEWER, KAWASHI_READONLY, KAWASHI_READWRITE) - nenhuma role nativa
    do Oracle (DBA e afins) pode ser concedida por aqui, de proposito.

.PARAMETER EnvFile
    Caminho do .env com as credenciais do ENGINEER_USER (DBA) e do Vault. Padrao: infra/.env.

.EXAMPLE
    ./create-team-member.ps1 -Username JOAO_SILVA -Profile Desenvolvedor

.EXAMPLE
    ./create-team-member.ps1 -Username MARIA_QA -Profile HomologViewer

.EXAMPLE
    ./create-team-member.ps1 -Username PEDRO_SEFAZ -Profile Desenvolvedor -Servicos SEFAZ

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
    [ValidateSet('EstagiarioDev', 'EstagiarioInfra', 'Desenvolvedor', 'Infra', 'HomologViewer')]
    [string]$Profile,

    # Liberacao aditiva de schema de SERVICO (ver .PARAMETER Servicos acima) -
    # independente do -Profile, nao concede acesso a nenhum ambiente por si so.
    [ValidateSet('SEFAZ', 'SIMPLES_NACIONAL')]
    [string[]]$Servicos = @(),

    # CORRIGIDO (achado real, nao hipotetico: testado ao vivo concedendo DBA a
    # um Estagiario novo via "-Roles @('DBA')" e funcionou sem nenhuma
    # resistencia): sem ValidateSet, -Roles aceitava QUALQUER string, incluso
    # roles nativas do Oracle como DBA, IMP_FULL_DATABASE, etc. Isso tornava
    # este parametro de "excecao pontual" (uma role extra alem do -Profile)
    # num caminho trivial de escalonamento de privilegio total: qualquer
    # pessoa capaz de rodar este script (ou seja, com acesso ao .env) podia
    # se auto-conceder - ou conceder a outra pessoa - DBA completo na hora da
    # criacao, contornando todo o modelo de RBAC deste projeto. A lista abaixo
    # restringe -Roles as roles PROPRIAS da Kawashi (nenhuma delas chega perto
    # de poder administrativo - a mais ampla, ROLE_KAWASHI_INFRA, so da
    # CREATE SESSION + SELECT ANY DICTIONARY). Se um dia precisar de poder de
    # DBA de verdade, o caminho e 08_engineer_account.sql (bootstrap revisado
    # manualmente), nunca este script de onboarding do dia a dia.
    [ValidateSet('ROLE_KAWASHI_DEVELOPER', 'ROLE_KAWASHI_INFRA', 'ROLE_KAWASHI_HOMOLOG_VIEWER', 'KAWASHI_READONLY', 'KAWASHI_READWRITE')]
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
        'EstagiarioDev' {
            return @(
                "ALTER USER KAWASHI_ENV_TESTE_DEV GRANT CONNECT THROUGH $Username;"
            )
        }
        'EstagiarioInfra' {
            return @(
                "ALTER USER KAWASHI_ENV_TESTE_INFRA GRANT CONNECT THROUGH $Username;"
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

# Lista os "nomes curtos" de ambiente (sem o prefixo KAWASHI_ENV_) que um
# -Profile ja alcanca via proxy - e com essa lista que -Servicos monta os
# nomes dos schemas de servico correspondentes (KAWASHI_ENV_<AMBIENTE>_<SERVICO>).
# HomologViewer retorna lista vazia de proposito: esse perfil nao usa proxy em
# nenhum ambiente (so a role de leitura), entao nao tem onde anexar um servico.
function Get-AmbientesDoPerfil {
    param([string]$Profile)

    switch ($Profile) {
        'EstagiarioDev'   { return @('TESTE_DEV') }
        'EstagiarioInfra' { return @('TESTE_INFRA') }
        'Desenvolvedor'   { return @('DEV', 'HOMOLOG') }
        'Infra'           { return @('INFRA', 'HOMOLOG') }
        'HomologViewer'   { return @() }
    }
}

# Traduz -Servicos em GRANTs de proxy aditivos (ver secao 2.1 e 3 de
# infra/oracle-init/09_environments.sql) - um por (servico x ambiente que o
# -Profile ja alcanca). Lanca erro cedo (antes de qualquer CREATE USER) se
# -Servicos for pedido pra um perfil que nao alcanca ambiente nenhum via
# proxy, em vez de silenciosamente nao conceder nada.
function Get-ServicoStatements {
    param([string]$Profile, [string[]]$Servicos, [string]$Username)

    if ($Servicos.Count -eq 0) { return @() }

    $ambientes = Get-AmbientesDoPerfil -Profile $Profile
    if ($ambientes.Count -eq 0) {
        throw "-Servicos nao se aplica ao perfil '$Profile' (esse perfil nao usa proxy authentication em nenhum ambiente - ver 09_environments.sql)."
    }

    $statements = @()
    foreach ($servico in $Servicos) {
        foreach ($ambiente in $ambientes) {
            $statements += "ALTER USER KAWASHI_ENV_${ambiente}_${servico} GRANT CONNECT THROUGH $Username;"
        }
    }
    return $statements
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
    # CORRIGIDO (achado em infra/tests/caixa-preta/Test-ConexaoNovoUsuario.ps1):
    # o conjunto original incluia "@", que e o PROPRIO separador usado pelo
    # Oracle Easy Connect ("usuario/senha@host"). Uma senha gerada contendo
    # "@" quebra qualquer "sqlplus usuario/senha@//host:porta/servico" digitado
    # por uma pessoa (ou montado por um script) - o parser corta no "@" de
    # DENTRO da senha, antes de chegar no "@" de verdade, e o Oracle tenta
    # resolver um pedaco da senha como se fosse hostname (ORA-12262). Removido
    # do conjunto de especiais por esse motivo (o "/" ja nao fazia parte dele).
    $specialSet = [char[]]'!#%^*-_=+?'
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
# Calculado ANTES de qualquer coisa ser criada no Oracle: se -Servicos nao se
# aplicar ao -Profile escolhido, o erro (ver Get-ServicoStatements) precisa
# interromper o script sem deixar nenhum usuario pela metade.
$servicoStatements = (Get-ServicoStatements -Profile $Profile -Servicos $Servicos -Username $Username) -join "`n"
$grantStatements = @($profileStatements, $extraRoleStatements, $servicoStatements) -join "`n"

# CORRIGIDO (achado em infra/tests/caixa-preta/Test-UsuarioDuplicado.ps1): por
# padrao, o SQL*Plus NAO para no primeiro erro de um script - ele so imprime o
# erro e continua pra proxima instrucao. Sem "WHENEVER SQLERROR EXIT", rodar
# este script com um -Username que ja existe fazia o "CREATE USER" falhar
# (ORA-01920) mas as linhas SEGUINTES (QUOTA, GRANTs de proxy do -Profile,
# PASSWORD EXPIRE) rodavam normalmente contra o usuario JA EXISTENTE - ou
# seja, uma tentativa de onboarding que o PowerShell reportava como FALHA (por
# causa do "throw" mais abaixo) na pratica concedia acesso de verdade a uma
# conta que ja existia, inclusive de um -Profile diferente do original. Com
# "WHENEVER SQLERROR EXIT", o primeiro erro interrompe o script inteiro.
$sql = @"
WHENEVER SQLERROR EXIT SQL.SQLCODE
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
if ($Servicos.Count -gt 0) {
    Write-Host "Servicos liberados: $($Servicos -join ', ')"
}
