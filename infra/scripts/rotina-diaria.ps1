<#
.SYNOPSIS
    A conferencia diaria de seguranca: senhas e contas com pendencia, e o log de alteracoes
    conferido e ancorado no Vault. Feita para rodar sozinha (agendar-rotina.ps1), todo dia.

.DESCRIPTION
    Antes, as duas conferencias existiam mas so rodavam se alguem lembrasse:
      - cadastro-de-contas.ps1 -Acao Alertas  (senha vencendo ou vencida, conta sem cadastro,
        pessoa sem nome ou cargo, conta bloqueada, desligada com acesso de volta);
      - ancorar-log.ps1  (confere se o log de alteracoes de cada ambiente ainda bate com a ancora
        no Vault e, se bater, avanca a ancora; se nao bater, NAO ancora e acusa).

    Esta rotina roda as duas, grava um relatorio em infra/logs/ (fora do git) e, quando algo
    precisa de atencao, mostra um aviso na area de notificacao do Windows.

    Tambem confere o que costuma quebrar sem ninguem ver: Docker fora do ar e Vault reiniciado
    (em desenvolvimento ele e em memoria e perde tudo). Neste caso a rotina reconfigura o Vault
    (vault-init.ps1) e avisa que as ancoras anteriores se perderam: a conferencia daquele dia so
    passa a valer dali em diante.

    Codigos de saida: 0 = tudo certo; 1 = algo precisa de atencao (veja o relatorio);
    2 = nao deu para conferir (Docker ou banco fora do ar).

.PARAMETER PastaDeRelatorio
    Onde gravar o relatorio. Padrao: infra/logs/.

.PARAMETER SemAviso
    Nao mostra o aviso do Windows (para rodar em teste ou em servidor).

.PARAMETER EnvFile
    Caminho do .env. Padrao: infra/.env.

.EXAMPLE
    ./rotina-diaria.ps1
#>
[CmdletBinding()]
param(
    [string]$PastaDeRelatorio,
    [switch]$SemAviso,
    [string]$EnvFile
)

$ErrorActionPreference = 'Continue'
# Pasta deste script calculada AQUI, e nao nos valores padrao dos parametros: no Windows PowerShell
# 5.1, quando o script e chamado com -File (e assim que o Agendador de Tarefas chama), o
# $PSScriptRoot ainda esta vazio no bloco param e a rotina morria antes de comecar.
$aqui = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $PastaDeRelatorio) { $PastaDeRelatorio = Join-Path $aqui '..\logs' }
if (-not $EnvFile) { $EnvFile = Join-Path $aqui '..\.env' }
$PastaDeRelatorio = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PastaDeRelatorio)
$EnvFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EnvFile)
$inicio = Get-Date
$linhas = New-Object System.Collections.Generic.List[string]
$atencao = New-Object System.Collections.Generic.List[string]
$codigo = 0

function Add-Linha([string]$texto) { $script:linhas.Add($texto); Write-Host $texto }

# Roda outro script em processo separado (o "exit" dele nao encerra esta rotina) e devolve codigo e saida.
function Invoke-Script {
    param([string]$Nome, [string]$Argumentos)
    $caminho = Join-Path $script:aqui $Nome
    $cmd = "& '$caminho' $Argumentos -EnvFile '$($script:EnvFile)'"
    $saida = (powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return [pscustomobject]@{ Codigo = $LASTEXITCODE; Saida = $saida }
}

function Show-Aviso {
    param([string]$Titulo, [string]$Texto, [string]$Tipo)
    if ($SemAviso) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $icone = New-Object System.Windows.Forms.NotifyIcon
        $icone.Icon = if ($Tipo -eq 'Error') { [System.Drawing.SystemIcons]::Error } else { [System.Drawing.SystemIcons]::Warning }
        $icone.Visible = $true
        $icone.ShowBalloonTip(15000, $Titulo, $Texto, [System.Windows.Forms.ToolTipIcon]::$Tipo)
        Start-Sleep -Seconds 16
        $icone.Dispose()
    } catch {
        # Sem sessao grafica (servidor, teste): o relatorio ja tem tudo.
    }
}

Add-Linha "== Kawashi - Rotina diaria de seguranca - $($inicio.ToString('dd/MM/yyyy HH:mm')) =="

# ---------------------------------------------------------------------------
# 0. O ambiente esta de pe?
# ---------------------------------------------------------------------------
$saude = (docker inspect kawashi-oracle --format '{{.State.Health.Status}}' 2>&1 | Out-String).Trim()
$vaultNoAr = (docker inspect kawashi-vault --format '{{.State.Running}}' 2>&1 | Out-String).Trim()
if ($saude -ne 'healthy' -or $vaultNoAr -ne 'true') {
    Add-Linha "[FORA DO AR] Banco: '$saude'; Vault rodando: '$vaultNoAr'. Nada foi conferido hoje."
    Add-Linha "             Abra o Docker Desktop e rode: docker start kawashi-oracle kawashi-vault"
    $atencao.Add('Docker, banco ou Vault fora do ar: nada foi conferido')
    $codigo = 2
} else {
    Add-Linha "[OK] Banco e Vault no ar."

    # Portas publicadas so na maquina (127.0.0.1)? O docker-compose.yml ja pede isso, mas um
    # container criado antes da mudanca continua exposto ate ser recriado: aqui se ve o que vale.
    $expostas = @()
    foreach ($c in 'kawashi-oracle', 'kawashi-vault') {
        $mapa = (docker inspect $c --format '{{json .HostConfig.PortBindings}}' 2>&1 | Out-String).Trim() | ConvertFrom-Json
        foreach ($porta in $mapa.PSObject.Properties) {
            foreach ($b in $porta.Value) { if ($b.HostIp -ne '127.0.0.1') { $expostas += "$c porta $($b.HostPort)" } }
        }
    }
    if ($expostas.Count -gt 0) {
        Add-Linha "[ATENCAO] Porta publicada para a rede inteira, nao so para esta maquina: $($expostas -join ', ')."
        Add-Linha "          O docker-compose.yml ja corrige; vale quando o container for recriado (ver infra/docs/arquitetura.md, secao 1)."
        $atencao.Add("porta exposta na rede: $($expostas -join ', ')")
        $codigo = [Math]::Max($codigo, 1)
    } else {
        Add-Linha "[OK] Portas do banco e do Vault so na maquina local (127.0.0.1)."
    }

    # Vault reiniciado? (em desenvolvimento ele perde tudo, inclusive as ancoras do log)
    $envMap = @{}
    foreach ($l in Get-Content $EnvFile) { $p = $l.Trim().Split('=', 2); if ($p.Count -eq 2 -and -not $p[0].StartsWith('#')) { $envMap[$p[0].Trim()] = $p[1].Trim() } }
    $motores = (docker exec -e VAULT_TOKEN=$($envMap['VAULT_DEV_ROOT_TOKEN_ID']) kawashi-vault vault secrets list -format=json 2>&1 | Out-String)
    if ($motores -notmatch 'kawashi-secrets/') {
        Add-Linha "[ATENCAO] O Vault foi reiniciado e estava vazio: reconfigurando (vault-init.ps1)."
        Add-Linha "          As ancoras anteriores do log se perderam; a conferencia do log so vale de hoje em diante."
        Add-Linha "          Reponha tambem a copia das chaves de cifra da API: gerar-chaves-de-cifra.ps1 -SoCopiarParaOVault"
        Invoke-Script 'vault-init.ps1' '' | Out-Null
        $atencao.Add('Vault reiniciado: ancoras do log recomecaram e a copia das chaves da API precisa ser reposta')
        $codigo = 1
    }

    # -----------------------------------------------------------------------
    # 1. Contas: senhas, cadastro, desligados
    # -----------------------------------------------------------------------
    Add-Linha ""
    Add-Linha "--- Contas (cadastro-de-contas.ps1 -Acao Alertas) ---"
    $r = Invoke-Script 'cadastro-de-contas.ps1' '-Acao Alertas'
    $r.Saida -split "`n" | Where-Object { $_ -and $_ -notmatch '^== ' } | ForEach-Object { Add-Linha $_ }
    if ($r.Codigo -eq 1) {
        $n = if ($r.Saida -match '(\d+) conta\(s\) precisam') { $Matches[1] } else { '?' }
        $alarme = if ($r.Saida -match 'ALARME') { ' (com ALARME de conta desligada)' } else { '' }
        $atencao.Add("$n conta(s) com pendencia$alarme")
        $codigo = [Math]::Max($codigo, 1)
    } elseif ($r.Codigo -ne 0) {
        $atencao.Add('a conferencia das contas falhou')
        $codigo = [Math]::Max($codigo, 1)
    }

    # -----------------------------------------------------------------------
    # 2. Log de alteracoes: confere e ancora cada ambiente
    # -----------------------------------------------------------------------
    Add-Linha ""
    Add-Linha "--- Log de alteracoes (ancorar-log.ps1) ---"
    $r = Invoke-Script 'ancorar-log.ps1' '-Acao Ancorar'
    $r.Saida -split "`n" | Where-Object { $_ -and $_ -notmatch '^== ' } | ForEach-Object { Add-Linha $_ }
    if ($r.Codigo -ne 0) {
        $atencao.Add('DIVERGENCIA no log de alteracoes: alguem pode ter mexido no historico')
        $codigo = [Math]::Max($codigo, 1)
    }
}

# ---------------------------------------------------------------------------
# Relatorio e aviso
# ---------------------------------------------------------------------------
Add-Linha ""
if ($atencao.Count -eq 0) {
    Add-Linha "RESULTADO: tudo certo."
} else {
    Add-Linha "RESULTADO: precisa de atencao:"
    $atencao | ForEach-Object { Add-Linha " - $_" }
}

New-Item -ItemType Directory -Force -Path $PastaDeRelatorio | Out-Null
$arquivo = Join-Path $PastaDeRelatorio ("rotina-" + $inicio.ToString('yyyy-MM-dd_HHmm') + '.txt')
[System.IO.File]::WriteAllLines($arquivo, $linhas, [System.Text.UTF8Encoding]::new($false))
Write-Host "Relatorio: $arquivo"

if ($codigo -ne 0) {
    $tipo = if ($codigo -eq 2 -or ($atencao -match 'DIVERGENCIA|ALARME')) { 'Error' } else { 'Warning' }
    Show-Aviso -Titulo 'Kawashi: rotina de seguranca' -Texto (($atencao -join '; ') + ". Relatorio em infra\logs.") -Tipo $tipo
}
exit $codigo
