<#
.SYNOPSIS
    Desliga uma pessoa do time: tira TODO o acesso dela ao banco e ao Vault, na hora, e registra
    quando, quem desligou e por que. E o par do create-team-member.ps1.

.DESCRIPTION
    Sem este script, quem saia do time continuava com a conta aberta, o proxy nos ambientes e o
    login no Vault ate alguem lembrar de tirar um por um.

    No banco (procedure SYS.KAWASHI_DESLIGAR_CONTA, em infra/oracle-init/12_cadastro_de_contas.sql):
      1. tranca a conta e expira a senha;
      2. tira o proxy em todos os ambientes;
      3. revoga roles, privilegios de sistema e permissoes em objetos;
      4. derruba as sessoes abertas, inclusive as abertas por proxy;
      5. grava no cadastro de contas: DESLIGADA, com data, quem desligou e o motivo.

    No Vault:
      6. apaga o login pessoal (userpass) e a policy da pessoa;
      7. apaga os segredos dela (onboarding/<conta> e engineers/<conta>).

    A conta NAO e apagada por padrao: fica trancada, para a trilha de auditoria continuar ligada a
    um nome que existe. Com -Apagar, ela e apagada depois de desligada (o cadastro continua, como
    DESLIGADA). Depois do desligamento, o painel (cadastro-de-contas.ps1) acusa como alarme se
    alguem destrancar a conta ou devolver algum acesso a ela.

    So vale para conta de PESSOA. Conta de API, administrador, quem tem DBA e a propria conta de
    quem roda o script sao recusados pelo banco.

    Pode ser rodado de novo para a mesma conta: o que ja foi tirado nao da erro.

.PARAMETER Username
    A conta da pessoa (a mesma usada no create-team-member.ps1).

.PARAMETER Motivo
    Por que a pessoa esta sendo desligada (ex.: "Fim do contrato", "Mudou de equipe"). Obrigatorio:
    fica no cadastro de contas. Nao escreva dado pessoal sensivel aqui.

.PARAMETER Apagar
    Depois de desligar, apaga a conta do banco. Use quando ela nao precisa mais existir.

.PARAMETER EnvFile
    Caminho do .env com as credenciais do ENGINEER_USER e do Vault. Padrao: infra/.env.

.EXAMPLE
    ./remove-team-member.ps1 -Username JOAO_SILVA -Motivo 'Fim do contrato'

.EXAMPLE
    ./remove-team-member.ps1 -Username JOAO_SILVA -Motivo 'Fim do estagio' -Apagar
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,29}$')]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[\p{L}0-9 .,\-/()']{3,300}$")]
    [string]$Motivo,

    [switch]$Apagar,

    [string]$EnvFile
)

$ErrorActionPreference = 'Stop'
# Padrao do -EnvFile calculado AQUI, e nao no bloco param: com [CmdletBinding()], quando o script
# e chamado com "powershell -File", o $PSScriptRoot ainda esta vazio nos valores padrao do param.
if (-not $EnvFile) { $EnvFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\.env' }
$Username = $Username.ToUpper()

# Mesmo caminho dos outros scripts: SQL em BASE64 (sem o BOM do pipe do PowerShell 5.1), connect
# string por variavel de ambiente e NLS_LANG em UTF-8 para o motivo com acento.
function Invoke-SqlPlus {
    param([string]$ConnectString, [string]$Sql)
    $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($Sql))
    $innerCmd = 'echo ' + $b64 + ' | base64 -d | sqlplus -s "$ORACLE_CONNSTR"'
    $anterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $saida = docker exec -i -e ORACLE_CONNSTR="$ConnectString" -e NLS_LANG=AMERICAN_AMERICA.AL32UTF8 kawashi-oracle sh -c "$innerCmd" 2>&1 | ForEach-Object { "$_" }
    $ErrorActionPreference = $anterior
    return $saida
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

# Roda um comando do Vault e devolve se deu certo. "Nao existe" conta como certo: o objetivo e
# que a coisa nao exista mais.
function Invoke-VaultRemocao {
    param([string[]]$Argumentos)
    $anterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $saida = (docker exec -e VAULT_TOKEN=$script:VaultToken kawashi-vault vault @Argumentos 2>&1 | ForEach-Object { "$_" }) -join ' '
    $codigo = $LASTEXITCODE
    $ErrorActionPreference = $anterior
    return ($codigo -eq 0 -or $saida -match 'not found|no value found|does not exist')
}

Write-Host "== Kawashi - Desligamento de $Username ==" -ForegroundColor Cyan

$envMap = Get-DotEnv -Path $EnvFile
foreach ($key in 'ENGINEER_USER', 'ENGINEER_USER_PASSWORD', 'VAULT_DEV_ROOT_TOKEN_ID') {
    if (-not $envMap.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($envMap[$key])) {
        throw "Variavel '$key' ausente ou vazia em $EnvFile."
    }
}
$conexao = "$($envMap['ENGINEER_USER'])/$($envMap['ENGINEER_USER_PASSWORD'])@//localhost:1521/FREEPDB1"
$script:VaultToken = $envMap['VAULT_DEV_ROOT_TOKEN_ID']
$motivoSql = $Motivo.Trim().Replace("'", "''")

# ---------------------------------------------------------------------------
# 1 a 5. Banco: tudo numa procedure, que recusa o que nao e conta de pessoa
# ---------------------------------------------------------------------------
Write-Host "-> Banco: trancando a conta, tirando proxies, roles e privilegios, derrubando sessoes..."
$saida = Invoke-SqlPlus -ConnectString $conexao -Sql @"
SET SERVEROUTPUT ON
SET FEEDBACK OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SESSION SET CONTAINER = FREEPDB1;
EXEC SYS.KAWASHI_DESLIGAR_CONTA('$Username', '$motivoSql');
EXIT;
"@
$texto = $saida -join "`n"
if ($texto -match '(ORA|SP2|PLS)-\d{4,5}') {
    $erro = ([regex]::Match($texto, 'ORA-20\d{3}: [^\r\n]+')).Value
    if (-not $erro) { $erro = $texto }
    throw "O banco recusou o desligamento de ${Username}:`n$erro"
}
$resumo = ($saida | Where-Object { $_ -like 'RESUMO|*' } | Select-Object -First 1)
$numeros = @{}
if ($resumo) { foreach ($par in $resumo.Split('|') | Select-Object -Skip 1) { $kv = $par.Split('='); $numeros[$kv[0]] = $kv[1] } }
Write-Host ("   conta trancada; proxies tirados: {0}; roles: {1}; privilegios: {2}; permissoes em objetos: {3}; sessoes derrubadas: {4}" -f `
    $numeros['proxies'], $numeros['roles'], $numeros['privilegios'], $numeros['objetos'], $numeros['sessoes'])

# ---------------------------------------------------------------------------
# 6 e 7. Vault
# ---------------------------------------------------------------------------
Write-Host "-> Vault: apagando login, policy e segredos da pessoa..."
$policy = "engineer-$($Username.ToLower())"
$vault = [ordered]@{
    "login pessoal (auth/userpass/users/$Username)"   = (Invoke-VaultRemocao @('delete', "auth/userpass/users/$Username"))
    "policy ($policy)"                                = (Invoke-VaultRemocao @('policy', 'delete', $policy))
    "senha temporaria (onboarding/$Username)"         = (Invoke-VaultRemocao @('kv', 'metadata', 'delete', "kawashi-secrets/onboarding/$Username"))
    "senha guardada pela pessoa (engineers/$Username)" = (Invoke-VaultRemocao @('kv', 'metadata', 'delete', "kawashi-secrets/engineers/$Username"))
}
$falhasVault = @()
foreach ($item in $vault.GetEnumerator()) {
    if ($item.Value) { Write-Host "   removido: $($item.Key)" } else { $falhasVault += $item.Key; Write-Host "   FALHOU: $($item.Key)" -ForegroundColor Red }
}

# ---------------------------------------------------------------------------
# Opcional: apagar a conta
# ---------------------------------------------------------------------------
if ($Apagar) {
    Write-Host "-> Apagando a conta do banco (o cadastro continua, como DESLIGADA)..."
    $saidaDrop = (Invoke-SqlPlus -ConnectString $conexao -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $Username CASCADE;`nEXIT;`n") -join "`n"
    if ($saidaDrop -match 'ORA-\d{5}') { throw "A pessoa foi desligada, mas apagar a conta falhou:`n$saidaDrop" }
}

Write-Host ""
if ($falhasVault.Count -gt 0) {
    Write-Host "== Desligamento INCOMPLETO ==" -ForegroundColor Red
    Write-Host "O banco foi fechado, mas o Vault nao: $($falhasVault -join '; ')."
    Write-Host "O Vault esta no ar? Rode este script de novo: o que ja foi feito nao da erro."
    exit 1
}
Write-Host "== $Username desligado(a) ==" -ForegroundColor Green
Write-Host "Motivo registrado: $Motivo"
Write-Host "Confira no painel: ./cadastro-de-contas.ps1 -Acao Liberacoes -Username $Username"
