# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de INTEGRACAO: a rotina diaria (rotina-diaria.ps1) junta as conferencias de contas e do
    log, grava o relatorio e devolve um codigo que diz se alguem precisa agir; o agendar-rotina.ps1
    coloca e tira a rotina do Agendador de Tarefas do Windows.

.DESCRIPTION
    Roda a rotina num estado limpo (codigo 0, relatorio "tudo certo", ancora gravada nos 6
    ambientes), planta uma pendencia (conta criada por fora dos scripts) e confere que ela e
    acusada (codigo 1, relatorio com a conta). Depois agenda a rotina com um nome de teste,
    confere a tarefa (diaria, no horario, so com o usuario logado, rodando a rotina certa) e tira.

    O relatorio vai para uma pasta temporaria, e o aviso do Windows fica desligado (-SemAviso).
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')

Write-Host "== [INTEGRACAO] Rotina diaria e agendamento ==" -ForegroundColor Cyan

$rotina   = Join-Path $PSScriptRoot '..\..\scripts\rotina-diaria.ps1'
$agendar  = Join-Path $PSScriptRoot '..\..\scripts\agendar-rotina.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken   = Get-VaultToken -EnvFile $EnvFile
$pasta  = Join-Path $env:TEMP ("kawashi-rotina-" + (Get-Random -Maximum 999999))
$tarefa = "Kawashi Teste " + (Get-Random -Maximum 999999)
$results = @()
$porFora = $null

function Invoke-Rotina {
    # Com -File, exatamente como o Agendador de Tarefas chama. (No Windows PowerShell 5.1 o
    # $PSScriptRoot fica vazio no bloco param nesse modo; pelo terminal o defeito nao aparecia.)
    $saida = (powershell -NoProfile -ExecutionPolicy Bypass -File $rotina -SemAviso -PastaDeRelatorio $pasta 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $codigo = $LASTEXITCODE
    $ultimo = Get-ChildItem $pasta -Filter 'rotina-*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    $relatorio = if ($ultimo) { [IO.File]::ReadAllText($ultimo.FullName) } else { '' }
    return [pscustomobject]@{ Codigo = $codigo; Saida = $saida; Relatorio = $relatorio }
}

try {
    # --- estado limpo --------------------------------------------------------------
    # A porta exposta e conferida ao vivo no container. Enquanto o container antigo (de antes do
    # docker-compose.yml publicar so em 127.0.0.1) nao for recriado, a rotina acusa isso, e e o
    # comportamento certo: o teste aceita esse UNICO motivo de atencao e confere que ele aparece.
    $portasExpostas = @()
    foreach ($c in 'kawashi-oracle', 'kawashi-vault') {
        $mapa = (docker inspect $c --format '{{json .HostConfig.PortBindings}}' 2>&1 | Out-String).Trim() | ConvertFrom-Json
        foreach ($porta in $mapa.PSObject.Properties) { foreach ($b in $porta.Value) { if ($b.HostIp -ne '127.0.0.1') { $portasExpostas += $c } } }
    }
    $r = Invoke-Rotina
    if ($portasExpostas.Count -eq 0) {
        $results += New-TestResult -Name "Com tudo em ordem a rotina termina com codigo 0 e o relatorio diz 'tudo certo'" -Passed (($r.Codigo -eq 0) -and ($r.Relatorio -match 'RESULTADO: tudo certo')) -Details "codigo=$($r.Codigo)`n$($r.Relatorio)"
    } else {
        $outrosMotivos = @($r.Relatorio -split "`n" | Where-Object { $_ -match '^ - ' -and $_ -notmatch 'porta exposta na rede' })
        $results += New-TestResult -Name "Com o container ainda publicando a porta para a rede, a rotina acusa isso (codigo 1) e nada mais: e o unico motivo de atencao" -Passed (($r.Codigo -eq 1) -and ($r.Relatorio -match 'porta exposta na rede') -and ($outrosMotivos.Count -eq 0)) -Details "codigo=$($r.Codigo) outros=$($outrosMotivos -join ' | ')`n$($r.Relatorio)"
    }

    $results += New-TestResult -Name "O relatorio e gravado em arquivo e traz as duas conferencias (contas e log)" -Passed (($r.Relatorio -match '--- Contas') -and ($r.Relatorio -match '--- Log de alteracoes')) -Details $r.Relatorio

    $semAncora = @()
    foreach ($amb in 'TESTE_DEV', 'TESTE_INFRA', 'DEV', 'INFRA', 'HOMOLOG', 'PROD') {
        $argCampo = '-field=ordem'
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv get $argCampo "kawashi-secrets/log-ancora/$amb" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $semAncora += $amb }
    }
    $results += New-TestResult -Name "Depois da rotina, o log dos 6 ambientes esta ancorado no Vault" -Passed ($semAncora.Count -eq 0) -Details "sem ancora: $($semAncora -join ', ')"

    # --- uma pendencia aparece -------------------------------------------------------
    $porFora = New-ThrowawayUsername -Prefix 'TST_ROTF'
    $senha = New-StrongPassword -Length 16 -AvoidSubstring $porFora
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nCREATE USER $porFora IDENTIFIED BY `"$senha`" PROFILE KAWASHI_SECURE_PROFILE;`nEXIT;`n" | Out-Null
    $r = Invoke-Rotina
    $results += New-TestResult -Name "Conta criada por fora dos scripts faz a rotina terminar com codigo 1, e o relatorio aponta a conta e a pendencia" -Passed (($r.Codigo -eq 1) -and ($r.Relatorio -match $porFora) -and ($r.Relatorio -match 'conta sem cadastro') -and ($r.Relatorio -match 'precisa de atencao')) -Details "codigo=$($r.Codigo)`n$($r.Relatorio)"

    # --- agendamento -----------------------------------------------------------------
    & $agendar -Horario '07:45' -NomeDaTarefa $tarefa *> $null
    $t = Get-ScheduledTask -TaskPath '\Kawashi\' -TaskName $tarefa -ErrorAction SilentlyContinue
    $okTarefa = $false; $detalhe = 'tarefa nao encontrada'
    if ($t) {
        $gat = $t.Triggers | Select-Object -First 1
        $acao = $t.Actions | Select-Object -First 1
        $okTarefa = ($gat.CimClass.CimClassName -eq 'MSFT_TaskDailyTrigger') -and ($gat.StartBoundary -match 'T07:45') `
            -and ($acao.Arguments -match 'rotina-diaria\.ps1') -and ($t.Principal.LogonType -eq 'Interactive') -and ($t.Settings.StartWhenAvailable)
        $detalhe = "gatilho=$($gat.CimClass.CimClassName) $($gat.StartBoundary) acao=$($acao.Arguments) logon=$($t.Principal.LogonType) atrasada=$($t.Settings.StartWhenAvailable)"
    }
    $results += New-TestResult -Name "agendar-rotina.ps1 cria a tarefa diaria no horario pedido, rodando a rotina, so com o usuario logado (sem senha guardada) e recuperando o horario perdido" -Passed $okTarefa -Details $detalhe

    & $agendar -Remover -NomeDaTarefa $tarefa *> $null
    $sumiu = -not (Get-ScheduledTask -TaskPath '\Kawashi\' -TaskName $tarefa -ErrorAction SilentlyContinue)
    $results += New-TestResult -Name "agendar-rotina.ps1 -Remover tira a tarefa" -Passed $sumiu -Details "removida=$sumiu"

    $recusou = $false
    try { & $agendar -Horario '25:99' -NomeDaTarefa $tarefa *> $null } catch { $recusou = ($_.Exception.Message -match 'Horario') }
    $results += New-TestResult -Name "Horario invalido e recusado antes de mexer no Agendador" -Passed $recusou -Details "recusou=$recusou"
}
finally {
    Write-Host "-> Limpando: conta descartavel, tarefa de teste e relatorios temporarios..."
    if ($porFora) {
        Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $porFora CASCADE;`nEXIT;`n" | Out-Null
    }
    if (Get-ScheduledTask -TaskPath '\Kawashi\' -TaskName $tarefa -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskPath '\Kawashi\' -TaskName $tarefa -Confirm:$false
    }
    Remove-Item -Recurse -Force $pasta -ErrorAction SilentlyContinue
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
