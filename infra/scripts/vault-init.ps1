<#
.SYNOPSIS
    Configura o Vault do zero (engine de segredos + metodo de login) de forma reprodutivel,
    em vez de depender de cliques manuais na UI.

.DESCRIPTION
    Ate agora, toda vez que o container do Vault era recriado, alguem precisava entrar na UI
    (http://localhost:8200) e clicar em "Enable new engine" na mao pra recriar o mesmo estado.
    Isso e exatamente o tipo de coisa que devia estar em codigo, nao na memoria de quem configurou
    da ultima vez - e vale tanto pra rodar local quanto (no futuro) contra um Vault na AWS.

    Este script e IDEMPOTENTE: pode ser rodado de novo sem quebrar nada se o Vault ja estiver
    configurado (ele checa o que ja existe antes de tentar criar).

    O QUE ESTE SCRIPT FAZ HOJE (equivalente ao setup manual que ja foi feito pela UI):
      1. Habilita o secrets engine KV versao 2 no path "kawashi-secrets" - e onde ficam guardadas
         as credenciais (temporarias de onboarding e definitivas de cada engenheiro).
      2. Habilita o auth method "userpass" - e o metodo de login usado pelo
         infra/scripts/create-team-member.ps1 pra dar a cada pessoa um login proprio no Vault.

    O QUE ESTE SCRIPT *NAO* FAZ (e por que isso e esperado no estagio atual do projeto):
      - Nao mexe em storage/persistencia: o Vault continua em modo "-dev" (memoria, tudo se
        perde a cada restart do container). Rodar este script e, hoje, um passo manual repetido
        toda vez que voce sobe o ambiente do zero.
      - Nao mexe em unseal: o modo "-dev" ja nasce destravado com um token fixo
        (VAULT_DEV_ROOT_TOKEN_ID do .env). Producao de verdade nao usa isso.
      - Nao mexe em TLS: o Vault aqui responde em HTTP puro, sem certificado.

    ###########################################################################
    # TODO (AWS / PRODUCAO) - registrar aqui pra nao esquecer quando migrar:  #
    ###########################################################################
    #   1. STORAGE PERSISTENTE: trocar o modo "-dev" por um Vault "server" de
    #      verdade, com backend de storage persistente (Integrated Storage/Raft
    #      com volume EBS, ou Consul). Sem isso, todo restart apaga os segredos
    #      - inaceitavel fora do ambiente de desenvolvimento local.
    #   2. AUTO-UNSEAL: configurar unseal automatico via AWS KMS, pra ninguem
    #      precisar digitar as unseal keys manualmente sempre que o Vault reiniciar.
    #   3. TLS: terminar TLS no proprio Vault (ou num ALB na frente dele) com
    #      certificado emitido via ACM - nunca expor a API do Vault em HTTP puro
    #      fora do seu proprio laptop.
    #   4. AUTENTICACAO SEM SENHA FIXA: trocar (ou complementar) o auth method
    #      "userpass" pelo "AWS Auth Method" do Vault, que autentica a aplicacao
    #      pela IAM Role da instancia/task, sem nenhuma senha estatica envolvida.
    #      Isso fecha o ciclo do item "Dynamic Credentials" do roadmap do projeto.
    #   5. PARAR DE USAR O ROOT TOKEN NO DIA A DIA: hoje TODOS os scripts usam
    #      VAULT_DEV_ROOT_TOKEN_ID pra tudo, porque em dev isso e aceitavel. Em
    #      producao, criar uma policy/token administrativo com o minimo de
    #      privilegio necessario pra rodar esses scripts, e guardar o root token
    #      de verdade trancado (sealed, fora do dia a dia).
    ###########################################################################

.PARAMETER EnvFile
    Caminho do .env com VAULT_DEV_ROOT_TOKEN_ID. Padrao: infra/.env.

.EXAMPLE
    ./vault-init.ps1

.NOTES
    Rode este script logo depois de "docker compose up", antes de usar o
    create-team-member.ps1 pela primeira vez em um Vault recem-criado.
#>

[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\.env')
)

$ErrorActionPreference = 'Stop'

# Nome do path onde os segredos da Kawashi ficam guardados (compartilhado com
# create-team-member.ps1 - se mudar aqui, tem que mudar la tambem).
$KvEnginePath = 'kawashi-secrets'

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

Write-Host "== Kawashi - Inicializacao do Vault ==" -ForegroundColor Cyan

$envMap = Get-DotEnv -Path $EnvFile
if (-not $envMap.ContainsKey('VAULT_DEV_ROOT_TOKEN_ID') -or [string]::IsNullOrWhiteSpace($envMap['VAULT_DEV_ROOT_TOKEN_ID'])) {
    throw "Variavel 'VAULT_DEV_ROOT_TOKEN_ID' ausente ou vazia em $EnvFile."
}
$VaultToken = $envMap['VAULT_DEV_ROOT_TOKEN_ID']

# Helper pra rodar qualquer comando "vault ..." de dentro do container, autenticado
# com o token root. Usamos "docker exec" (em vez de exigir o CLI do Vault instalado
# no Windows) porque o binario "vault" ja vem dentro da propria imagem do container.
function Invoke-VaultCommand {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$VaultArgs)
    return docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault @VaultArgs 2>&1
}

# ---------------------------------------------------------------------------
# 0. Espera o Vault responder (o container pode levar alguns segundos pra subir
#    logo depois do "docker compose up", e chamar a API antes disso so gera erro
#    de conexao recusada, nao um erro "de verdade").
# ---------------------------------------------------------------------------
Write-Host "-> Aguardando o Vault responder..."
$maxTentativas = 15
$ok = $false
for ($i = 0; $i -lt $maxTentativas; $i++) {
    $status = docker exec kawashi-vault vault status -format=json 2>&1
    if ($LASTEXITCODE -eq 0 -or $status -match '"sealed"\s*:\s*false') {
        $ok = $true
        break
    }
    Start-Sleep -Seconds 2
}
if (-not $ok) {
    throw "Vault nao respondeu apos $maxTentativas tentativas. Confirme que 'docker compose up' esta rodando e que o container 'kawashi-vault' esta saudavel (docker logs kawashi-vault)."
}

# ---------------------------------------------------------------------------
# 1. Secrets engine KV v2 no path "kawashi-secrets"
#    Idempotente: consulta o que ja esta habilitado antes de tentar criar de novo
#    (o Vault recusa com erro se voce tentar habilitar um path que ja existe).
# ---------------------------------------------------------------------------
Write-Host "-> Verificando secrets engine '$KvEnginePath'..."

$secretsListJson = Invoke-VaultCommand secrets list -format=json
$secretsList = $secretsListJson | ConvertFrom-Json -ErrorAction SilentlyContinue

$engineJaExiste = $false
if ($secretsList) {
    $engineJaExiste = [bool]($secretsList.PSObject.Properties.Name -contains "$KvEnginePath/")
}

if ($engineJaExiste) {
    Write-Host "   Ja existe - nada a fazer." -ForegroundColor DarkGray
} else {
    Write-Host "   Nao existe ainda - habilitando KV v2 em '$KvEnginePath'..."
    Invoke-VaultCommand secrets enable -path=$KvEnginePath -version=2 kv | Out-Null
    Write-Host "   Habilitado." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 2. Auth method "userpass"
#    E o metodo de login pessoal usado pelo create-team-member.ps1 pra dar a
#    cada integrante do time um usuario/senha proprio no Vault (em vez de todo
#    mundo compartilhar o token root, que so o administrador do projeto deve usar).
# ---------------------------------------------------------------------------
Write-Host "-> Verificando auth method 'userpass'..."

$authListJson = Invoke-VaultCommand auth list -format=json
$authList = $authListJson | ConvertFrom-Json -ErrorAction SilentlyContinue

$authJaExiste = $false
if ($authList) {
    $authJaExiste = [bool]($authList.PSObject.Properties.Name -contains 'userpass/')
}

if ($authJaExiste) {
    Write-Host "   Ja existe - nada a fazer." -ForegroundColor DarkGray
} else {
    Write-Host "   Nao existe ainda - habilitando..."
    Invoke-VaultCommand auth enable userpass | Out-Null
    Write-Host "   Habilitado." -ForegroundColor Green
}

Write-Host ""
Write-Host "== Vault pronto para uso ==" -ForegroundColor Green
Write-Host "Engine de segredos: $KvEnginePath (KV v2)"
Write-Host "Login pessoal: metodo 'userpass' habilitado"
Write-Host "Proximo passo: use infra/scripts/create-team-member.ps1 para criar usuarios."
