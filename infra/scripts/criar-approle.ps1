# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Cria (ou recria) o papel AppRole de uma aplicacao (API ou BFF) num ambiente, com leitura SO dos
    segredos dela no Vault, e opcionalmente liga a aplicacao a ele.

.DESCRIPTION
    Sem isto, a API e o BFF leem os segredos do .env (senha do banco, chaves de cifra, segredo do
    BFF), copiados a mao. Com o AppRole, a aplicacao entra no Vault na subida e le os segredos de
    la (SegredosDoVault.java em cada repositorio); o .env fica so com a identidade do papel.

    O papel "kawashi-<aplicacao>-<ambiente>" tem uma politica de mesmo nome que so LE:
      api: kawashi-secrets/cifra/<AMB>, kawashi-secrets/bff/<AMB> e kawashi-secrets/api/<conta> das
           contas de execucao e de migracao informadas;
      bff: kawashi-secrets/bff/<AMB>.
    Nada de escrita, nada de outro ambiente, nada da conta de outra aplicacao. O token que a
    aplicacao recebe dura 5 minutos (so serve para a subida) e o secret_id vale 30 dias (rodar o
    script de novo gera outro).

    Com -Ligar, grava no .env da aplicacao VAULT_ADDR, VAULT_AMBIENTE, VAULT_ROLE_ID e
    VAULT_SECRET_ID (sem mostrar os valores). Daqui em diante a aplicacao EXIGE o Vault para subir.
    ATENCAO: o Vault de desenvolvimento e em memoria; depois de reinicia-lo, rode vault-init.ps1,
    reponha os segredos e rode este script de novo, senao a aplicacao nao sobe (falha fechada).

    O token root vai para o conteiner por variavel de ambiente ("docker exec -e NOME", sem o valor)
    e a politica vai em base64 (o PowerShell 5.1 poe um BOM no que manda pela entrada padrao).

.PARAMETER Aplicacao
    api ou bff.

.PARAMETER Ambiente
    TESTE_DEV, TESTE_INFRA, DEV, INFRA, HOMOLOG ou PROD.

.PARAMETER ContaExecucao
    (api) A conta de execucao da API (DB_USER do .env da API).

.PARAMETER ContaMigracao
    (api) A conta de migracao da API (DB_MIGRACAO_USER do .env da API).

.PARAMETER Ligar
    Grava a identidade do papel no .env da aplicacao (-AppEnvFile).

.PARAMETER AppEnvFile
    O .env da aplicacao, para -Ligar.

.PARAMETER VaultAddr
    Endereco do Vault visto pela aplicacao. Padrao: http://localhost:8200.

.PARAMETER EnvFile
    O .env do repositorio de regras (token root do Vault). Padrao: infra/.env.

.EXAMPLE
    .\criar-approle.ps1 -Aplicacao bff -Ambiente TESTE_DEV -Ligar -AppEnvFile ..\..\..\bff-banco-usp\.env

.EXAMPLE
    .\criar-approle.ps1 -Aplicacao api -Ambiente TESTE_DEV -ContaExecucao KW_API_EXEC -ContaMigracao KW_API_MIG
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('api', 'bff')]
    [string]$Aplicacao,

    [Parameter(Mandatory = $true)]
    [ValidateSet('TESTE_DEV', 'TESTE_INFRA', 'DEV', 'INFRA', 'HOMOLOG', 'PROD')]
    [string]$Ambiente,

    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,29}$')]
    [string]$ContaExecucao,

    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,29}$')]
    [string]$ContaMigracao,

    [switch]$Ligar,

    [string]$AppEnvFile,

    [ValidatePattern('^https?://[A-Za-z0-9.\-]+(:\d+)?$')]
    [string]$VaultAddr = 'http://localhost:8200',

    [string]$EnvFile
)

$ErrorActionPreference = 'Stop'
# Padrao do -EnvFile calculado AQUI: com [CmdletBinding()] e "powershell -File", o $PSScriptRoot fica vazio no bloco param.
if (-not $EnvFile) { $EnvFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\.env' }
if ($Aplicacao -eq 'api' -and (-not $ContaExecucao -or -not $ContaMigracao)) {
    throw 'Para a API, informe -ContaExecucao e -ContaMigracao (DB_USER e DB_MIGRACAO_USER do .env dela).'
}
if ($Ligar -and -not $AppEnvFile) { throw 'Com -Ligar, informe -AppEnvFile (o .env da aplicacao).' }
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Get-ValorDoEnv {
    param([string]$Arquivo, [string]$Chave)
    if (-not (Test-Path -LiteralPath $Arquivo)) { throw "Arquivo .env nao encontrado em '$Arquivo'." }
    foreach ($linha in [System.IO.File]::ReadAllLines($Arquivo)) {
        $p = $linha.Trim().Split('=', 2)
        if ($p.Count -eq 2 -and $p[0].Trim() -eq $Chave) { return $p[1].Trim() }
    }
    throw "Variavel '$Chave' ausente em $Arquivo."
}

# Troca a linha da chave (ou acrescenta no fim); as outras linhas ficam como estao. Nada e mostrado.
function Set-LinhaDoEnv {
    param([string]$Arquivo, [string]$Chave, [string]$Valor)
    $linhas = New-Object System.Collections.Generic.List[string]
    $trocou = $false
    if (Test-Path -LiteralPath $Arquivo) {
        foreach ($linha in [System.IO.File]::ReadAllLines($Arquivo)) {
            $p = $linha.Trim().Split('=', 2)
            if ($p.Count -eq 2 -and $p[0].Trim() -eq $Chave) {
                if (-not $trocou) { $linhas.Add("$Chave=$Valor"); $trocou = $true }
            } else {
                $linhas.Add($linha)
            }
        }
    }
    if (-not $trocou) { $linhas.Add("$Chave=$Valor") }
    [System.IO.File]::WriteAllText($Arquivo, ($linhas -join "`n") + "`n", $utf8)
}

function Invoke-Vault {
    # Roda um comando do vault no conteiner com o token root por variavel de ambiente. Devolve a saida.
    param([string]$Comando)
    $anterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $env:VAULT_TOKEN = Get-ValorDoEnv $EnvFile 'VAULT_DEV_ROOT_TOKEN_ID'
        $saida = docker exec -e VAULT_TOKEN kawashi-vault sh -c $Comando 2>&1 | ForEach-Object { "$_" }
        $script:okVault = ($LASTEXITCODE -eq 0)
    } finally {
        Remove-Item Env:\VAULT_TOKEN -ErrorAction SilentlyContinue
        $ErrorActionPreference = $anterior
    }
    return ($saida -join "`n")
}

$papel = "kawashi-$Aplicacao-$($Ambiente.ToLower().Replace('_', '-'))"
$caminhos = @("kawashi-secrets/data/bff/$Ambiente")
if ($Aplicacao -eq 'api') {
    $caminhos += "kawashi-secrets/data/cifra/$Ambiente", "kawashi-secrets/data/api/$ContaExecucao", "kawashi-secrets/data/api/$ContaMigracao"
}
$politica = ($caminhos | ForEach-Object { "path `"$_`" {`n  capabilities = [`"read`"]`n}" }) -join "`n"

# 1. O metodo approle (o vault-init.ps1 ja liga; aqui so confere).
$metodos = Invoke-Vault 'vault auth list -format=json'
if (-not $script:okVault) { throw "O Vault nao respondeu (o conteiner kawashi-vault esta de pe? rodou o vault-init.ps1?):`n$metodos" }
if ($metodos -notmatch '"approle/"') {
    Invoke-Vault 'vault auth enable approle' | Out-Null
    if (-not $script:okVault) { throw 'Nao consegui habilitar o approle.' }
}

# 2. A politica (so leitura dos caminhos acima) e o papel.
$b64 = [Convert]::ToBase64String($utf8.GetBytes($politica))
$saida = Invoke-Vault ("echo $b64 | base64 -d | vault policy write $papel -")
if (-not $script:okVault) { throw "O Vault recusou a politica:`n$saida" }
$saida = Invoke-Vault ("vault write auth/approle/role/$papel token_policies=$papel token_ttl=5m token_max_ttl=5m secret_id_ttl=720h token_type=service")
if (-not $script:okVault) { throw "O Vault recusou o papel:`n$saida" }

$roleId = (Invoke-Vault "vault read -field=role_id auth/approle/role/$papel/role-id").Trim()
if (-not $script:okVault -or $roleId -notmatch '^[0-9a-f-]{36}$') { throw 'Nao consegui ler o role_id.' }
Write-Host "Papel $papel pronto: so le $($caminhos.Count) caminho(s):" -ForegroundColor Green
$caminhos | ForEach-Object { Write-Host "   $_" }

if (-not $Ligar) {
    Write-Host "A aplicacao ainda NAO usa o papel. Para ligar, rode de novo com -Ligar -AppEnvFile <.env da aplicacao>." -ForegroundColor Yellow
    exit 0
}

# 3. Liga: secret_id novo direto para o .env, sem aparecer na tela.
$secretId = (Invoke-Vault "vault write -f -field=secret_id auth/approle/role/$papel/secret-id").Trim()
if (-not $script:okVault -or $secretId -notmatch '^[0-9a-f-]{36}$') { throw 'Nao consegui gerar o secret_id.' }
Set-LinhaDoEnv $AppEnvFile 'VAULT_ADDR' $VaultAddr
Set-LinhaDoEnv $AppEnvFile 'VAULT_AMBIENTE' $Ambiente
Set-LinhaDoEnv $AppEnvFile 'VAULT_ROLE_ID' $roleId
Set-LinhaDoEnv $AppEnvFile 'VAULT_SECRET_ID' $secretId
$secretId = $null
Write-Host "Aplicacao ligada ao Vault: VAULT_ADDR, VAULT_AMBIENTE, VAULT_ROLE_ID e VAULT_SECRET_ID gravados em $AppEnvFile (valores nao mostrados)." -ForegroundColor Green
Write-Host "Na proxima subida, a aplicacao le os segredos do Vault e NAO sobe sem ele." -ForegroundColor Yellow
