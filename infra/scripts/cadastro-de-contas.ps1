# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Painel das contas do banco: quem e cada conta, que cargo tem, o que pode acessar e como
    esta a senha em relacao ao limite de 90 dias. Vale para pessoas (desenvolvedores,
    estagiarios, infra), para as contas de API e para o administrador.

.DESCRIPTION
    Le as views criadas por infra/oracle-init/12_cadastro_de_contas.sql:
      SYS.V_KAWASHI_CONTAS            uma linha por conta, com cargo, liberacoes e senha
      SYS.V_KAWASHI_CONTA_LIBERACOES  uma linha por liberacao (ambiente, role, privilegio)

    As liberacoes e as datas de senha sao lidas AO VIVO do dicionario do Oracle: se alguem der
    um GRANT por fora dos scripts, aparece aqui. So nome, cargo e perfil ficam gravados na
    tabela SYS.KAWASHI_CONTA, e so entram pela procedure SYS.KAWASHI_REGISTRAR_CONTA.

    Acoes:
      Listar      Mostra todas as contas (padrao).
      Alertas     Mostra so as contas com pendencia (senha vencida ou vencendo em 15 dias,
                  conta sem cadastro, pessoa sem nome ou cargo, conta bloqueada) e termina com
                  codigo 1 se houver alguma. Serve para agendar: codigo 1 = alguem precisa agir.
      Liberacoes  Detalha tudo o que UMA conta pode (-Username).
      Registrar   Grava ou completa o cadastro de uma conta que ja existe (-Username, com
                  -Nome e/ou -Cargo). Usado para contas antigas ou criadas sem cargo.

    Senha de 90 dias, como e cobrada:
      Pessoa e administrador  O proprio Oracle bloqueia ao vencer (perfil KAWASHI_SECURE_PROFILE,
                              com 7 dias de tolerancia). O painel avisa antes.
      Conta de API            A senha nao expira sozinha, de proposito (uma API parada por senha
                              vencida e pior). O painel conta os mesmos 90 dias e marca VENCIDA
                              para a rotacao ser feita a mao.

.PARAMETER Acao
    Listar (padrao), Alertas, Liberacoes ou Registrar.

.PARAMETER Username
    Conta alvo de Liberacoes e de Registrar.

.PARAMETER Nome
    Nome da pessoa (ou do responsavel, se for conta de API). So em Registrar.

.PARAMETER Cargo
    Cargo da pessoa. So em Registrar.

.PARAMETER Tipo
    PESSOA, API ou ADMIN. So em Registrar, e so necessario quando a conta ainda nao tem cadastro.

.PARAMETER Perfil
    Perfil com que a conta foi criada (ex.: Desenvolvedor). So em Registrar, quando a conta
    ainda nao tem cadastro.

.PARAMETER ComRemovidas
    Em Listar, mostra tambem as contas desligadas (remove-team-member.ps1) e as apagadas do banco.
    Desligada com alarme aparece sempre, com ou sem esta opcao.

.PARAMETER EnvFile
    Caminho do .env com as credenciais do ENGINEER_USER. Padrao: infra/.env.

.EXAMPLE
    ./cadastro-de-contas.ps1

.EXAMPLE
    ./cadastro-de-contas.ps1 -Acao Alertas

.EXAMPLE
    ./cadastro-de-contas.ps1 -Acao Liberacoes -Username JOAO_SILVA

.EXAMPLE
    ./cadastro-de-contas.ps1 -Acao Registrar -Username JOAO_SILVA -Nome 'Joao da Silva' -Cargo 'Desenvolvedor Pleno'
#>
[CmdletBinding()]
param(
    [ValidateSet('Listar', 'Alertas', 'Liberacoes', 'Registrar')]
    [string]$Acao = 'Listar',

    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,29}$')]
    [string]$Username,

    [ValidatePattern("^[\p{L}0-9 .,\-/()']{1,200}$")]
    [string]$Nome,

    [ValidatePattern("^[\p{L}0-9 .,\-/()']{1,100}$")]
    [string]$Cargo,

    [ValidateSet('PESSOA', 'API', 'ADMIN')]
    [string]$Tipo,

    [ValidatePattern('^[A-Za-z][A-Za-z0-9]{0,29}$')]
    [string]$Perfil,

    [switch]$ComRemovidas,

    [string]$EnvFile
)

$ErrorActionPreference = 'Stop'
# Padrao do -EnvFile calculado AQUI, e nao no bloco param: com [CmdletBinding()], quando o script
# e chamado com "powershell -File", o $PSScriptRoot ainda esta vazio nos valores padrao do param.
if (-not $EnvFile) { $EnvFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\.env' }

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

# Mesmo caminho dos outros scripts: SQL em BASE64 (sem o BOM do pipe do PowerShell 5.1) e a
# connect string por variavel de ambiente. NLS_LANG em UTF-8 para nome e cargo com acento.
function Invoke-SqlPlus {
    param([string]$Sql)
    $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($Sql))
    $innerCmd = 'echo ' + $b64 + ' | base64 -d | sqlplus -s "$ORACLE_CONNSTR"'
    $anterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $saida = docker exec -i -e ORACLE_CONNSTR="$script:Conexao" -e NLS_LANG=AMERICAN_AMERICA.AL32UTF8 kawashi-oracle sh -c "$innerCmd" 2>&1 | ForEach-Object { "$_" }
    $ErrorActionPreference = $anterior
    $texto = ($saida -join "`n")
    if ($texto -match '(ORA|SP2)-\d{4,5}') { throw "O banco recusou a consulta:`n$texto" }
    return $saida
}

# Cada linha vira um objeto com a lista de campos em .C (um array solto se desmancharia quando a
# consulta devolve uma linha so).
# Uma consulta devolve linhas "campo1|campo2|..." marcadas com um prefixo, para separar dado de ruido.
function Get-Linhas {
    param([string]$Select)
    $saida = Invoke-SqlPlus "SET PAGESIZE 0`nSET FEEDBACK OFF`nSET LINESIZE 4000`nSET TRIMSPOOL ON`nALTER SESSION SET CONTAINER = FREEPDB1;`n$Select`nEXIT;`n"
    return @($saida | Where-Object { $_ -like 'L|*' } | ForEach-Object { [pscustomobject]@{ C = $_.Substring(2).TrimEnd().Split('|') } })
}

function ConvertTo-LiteralSql {
    param([string]$Texto)
    if ([string]::IsNullOrWhiteSpace($Texto)) { return 'NULL' }
    return "'" + $Texto.Trim().Replace("'", "''") + "'"
}

$envMap = Get-DotEnv -Path $EnvFile
foreach ($key in 'ENGINEER_USER', 'ENGINEER_USER_PASSWORD') {
    if (-not $envMap.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($envMap[$key])) {
        throw "Variavel '$key' ausente ou vazia em $EnvFile."
    }
}
$script:Conexao = "$($envMap['ENGINEER_USER'])/$($envMap['ENGINEER_USER_PASSWORD'])@//localhost:1521/FREEPDB1"
if ($Username) { $Username = $Username.ToUpper() }

$colunas = @"
'L|' || USERNAME || '|' || TIPO || '|' || NVL(PERFIL, '-') || '|' || NVL(NOME, '-') || '|' || NVL(CARGO, '-') || '|' ||
CADASTRO || '|' || NVL(AMBIENTES_LIBERADOS, '-') || '|' || NVL(ROLES, '-') || '|' ||
NVL(TO_CHAR(SENHA_TROCADA_EM, 'DD/MM/YYYY'), '-') || '|' || NVL(TO_CHAR(SENHA_VENCE_EM, 'DD/MM/YYYY'), '-') || '|' ||
NVL(TO_CHAR(DIAS_PARA_VENCER), '-') || '|' || NVL(SITUACAO_DA_SENHA, '-') || '|' || NVL(EXPIRA_SOZINHA, '-') || '|' ||
NVL(TO_CHAR(ULTIMO_LOGIN, 'DD/MM/YYYY'), '-') || '|' || NVL(PENDENCIA, '-') || '|' ||
NVL(TO_CHAR(DESLIGADA_EM, 'DD/MM/YYYY'), '-') || '|' || NVL(DESLIGADA_POR, '-') || '|' || NVL(REPLACE(MOTIVO_DESLIGAMENTO, '|', '/'), '-')
"@

# Um bloco por conta (uma tabela larga perderia colunas na largura do terminal).
function Show-Contas {
    param([object[]]$Linhas)
    foreach ($l in $Linhas) {
        $c = $l.C
        $quem = (@($c[3], $c[4]) | Where-Object { $_ -ne '-' }) -join ', '
        if (-not $quem) { $quem = if ($c[1] -eq 'API') { '(conta de sistema)' } else { '(sem nome e cargo)' } }
        $acessos = @()
        if ($c[6] -ne '-') { $acessos += 'ambientes ' + ($c[6] -replace 'KAWASHI_ENV_', '') }
        if ($c[7] -ne '-') { $acessos += 'roles ' + $c[7] }
        if ($acessos.Count -eq 0) { $acessos = @('nenhum') }
        $cor = if ($c[5] -eq 'DESLIGADA' -and $c[14] -ne '-') { 'Red' } elseif ($c[5] -in 'REMOVIDA', 'DESLIGADA') { 'DarkGray' } elseif ($c[14] -ne '-') { 'Yellow' } else { 'Green' }
        Write-Host ("{0}  [{1} / {2}]  {3}" -f $c[0], $c[1], $c[2], $quem) -ForegroundColor $cor
        if ($c[5] -eq 'DESLIGADA') {
            Write-Host "    desligada em $($c[15]) por $($c[16]): $($c[17])"
            if ($c[14] -ne '-') { Write-Host "    ALARME: $($c[14])" -ForegroundColor Red }
            continue
        }
        if ($c[5] -eq 'REMOVIDA') { Write-Host "    conta ja apagada do banco (so o cadastro restou)"; continue }
        Write-Host "    acesso:    $($acessos -join '; ')"
        Write-Host "    senha:     $($c[11]) - trocada em $($c[8]), limite em $($c[9]) (faltam $($c[10]) dias) - expira sozinha: $($c[12])"
        Write-Host "    login:     ultimo em $($c[13])"
        if ($c[5] -ne 'OK') { Write-Host "    cadastro:  $($c[5])" }
        if ($c[14] -ne '-') { Write-Host "    PENDENCIA: $($c[14])" -ForegroundColor Yellow }
    }
    Write-Host ""
}
switch ($Acao) {
    'Listar' {
        Write-Host "== Kawashi - Contas do banco ==" -ForegroundColor Cyan
        # Desligadas e removidas ficam fora da lista do dia a dia (use -ComRemovidas), menos a desligada
        # com alarme (destrancada ou com acesso de volta), que aparece sempre.
        $filtro = if ($ComRemovidas) { '' } else { "WHERE CADASTRO NOT IN ('REMOVIDA', 'DESLIGADA') OR (CADASTRO = 'DESLIGADA' AND PENDENCIA IS NOT NULL)" }
        $linhas = @(Get-Linhas "SELECT $colunas FROM SYS.V_KAWASHI_CONTAS $filtro ORDER BY TIPO DESC, USERNAME;")
        if ($linhas.Count -eq 0) { Write-Host "Nenhuma conta encontrada."; break }
        Show-Contas $linhas
        $comPendencia = @($linhas | Where-Object { $_.C[14] -ne '-' -and $_.C[5] -ne 'REMOVIDA' }).Count
        Write-Host "$($linhas.Count) conta(s), $comPendencia com pendencia. Limite de senha: o do perfil KAWASHI_SECURE_PROFILE."
        Write-Host "Pessoa e administrador: o banco bloqueia ao vencer. Conta de API: nao expira sozinha, rotacao manual."
    }
    'Alertas' {
        Write-Host "== Kawashi - Contas com pendencia ==" -ForegroundColor Cyan
        $linhas = @(Get-Linhas "SELECT $colunas FROM SYS.V_KAWASHI_CONTAS WHERE PENDENCIA IS NOT NULL AND CADASTRO <> 'REMOVIDA' ORDER BY TIPO DESC, USERNAME;")
        if ($linhas.Count -eq 0) {
            Write-Host "Nenhuma pendencia: todas as contas tem cadastro completo e senha em dia." -ForegroundColor Green
            exit 0
        }
        Show-Contas $linhas
        Write-Host "$($linhas.Count) conta(s) precisam de acao." -ForegroundColor Yellow
        exit 1
    }
    'Liberacoes' {
        if (-not $Username) { throw "Informe -Username para ver as liberacoes de uma conta." }
        Write-Host "== Kawashi - Liberacoes de $Username ==" -ForegroundColor Cyan
        $conta = @(Get-Linhas "SELECT $colunas FROM SYS.V_KAWASHI_CONTAS WHERE USERNAME = '$Username';")
        if ($conta.Count -eq 0) { throw "Conta '$Username' nao existe no banco nem no cadastro." }
        Show-Contas $conta
        $libs = @(Get-Linhas "SELECT 'L|' || TIPO_LIBERACAO || '|' || LIBERACAO || '|' || DETALHE FROM SYS.V_KAWASHI_CONTA_LIBERACOES WHERE USERNAME = '$Username' ORDER BY 1;")
        if ($libs.Count -eq 0) { Write-Host "Nenhuma liberacao: a conta existe mas nao pode acessar nada."; break }
        $libs | ForEach-Object { [pscustomobject]@{ Tipo = $_.C[0]; Liberacao = $_.C[1]; Detalhe = $_.C[2] } } | Format-Table -AutoSize -Wrap | Out-String -Width 250 | Write-Host
    }
    'Registrar' {
        if (-not $Username) { throw "Informe -Username da conta a cadastrar." }
        if (-not $Nome -and -not $Cargo -and -not $Tipo -and -not $Perfil) { throw "Informe o que gravar: -Nome, -Cargo, -Tipo e/ou -Perfil." }
        $atual = @(Get-Linhas "SELECT 'L|' || TIPO || '|' || NVL(PERFIL, '-') || '|' || CADASTRO FROM SYS.V_KAWASHI_CONTAS WHERE USERNAME = '$Username';")
        if ($atual.Count -eq 0 -or $atual[0].C[2] -eq 'REMOVIDA') { throw "Conta '$Username' nao existe no banco: nada a cadastrar." }
        # Conta que ja tem cadastro mantem tipo e perfil, a menos que sejam informados.
        $tipoFinal   = if ($Tipo) { $Tipo } else { $atual[0].C[0] }
        $perfilFinal = if ($Perfil) { $Perfil } elseif ($atual[0].C[1] -ne '-') { $atual[0].C[1] } else { throw "A conta '$Username' ainda nao tem cadastro: informe -Perfil (ex.: Desenvolvedor)." }
        Invoke-SqlPlus "WHENEVER SQLERROR EXIT SQL.SQLCODE`nALTER SESSION SET CONTAINER = FREEPDB1;`nEXEC SYS.KAWASHI_REGISTRAR_CONTA('$Username', '$tipoFinal', '$perfilFinal', $(ConvertTo-LiteralSql $Nome), $(ConvertTo-LiteralSql $Cargo), NULL);`nEXIT;`n" | Out-Null
        Write-Host "Cadastro de $Username gravado." -ForegroundColor Green
        Show-Contas (Get-Linhas "SELECT $colunas FROM SYS.V_KAWASHI_CONTAS WHERE USERNAME = '$Username';")
    }
}
