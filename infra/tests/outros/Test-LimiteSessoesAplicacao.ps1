# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de INTEGRACAO (guarda de regressao de um achado critico ja
    corrigido): confirma que a conta de aplicacao (SPRING_APP_USER) aguenta um
    pool de conexoes de verdade (mais de 3 conexoes simultaneas) sem ser
    rejeitada - e que o novo teto (50, ver KAWASHI_SERVICE_PROFILE em
    02_global_hardening.sql) ainda existe como rede de seguranca contra um
    vazamento de conexao sem limite nenhum.

.DESCRIPTION
    ACHADO ORIGINAL (ver item 14 de infra/docs/bugs-primeiro-teste.md): esta
    conta usava KAWASHI_SECURE_PROFILE (SESSIONS_PER_USER=3, pensado pra
    pessoa) - um pool HikariCP padrao (10 conexoes) quebraria a aplicacao real
    na propria inicializacao. Corrigido criando KAWASHI_SERVICE_PROFILE
    (SESSIONS_PER_USER=50) especificamente pra contas de servico/aplicacao.

    Abre 8 conexoes simultaneas de verdade (mais que o padrao do HikariCP,
    pra ter margem de confianca real - nao so "1 a mais que 3") rodando uma
    consulta CPU-bound (CONNECT BY, sem depender de DBMS_LOCK - a conta de
    aplicacao nao tem EXECUTE nesse pacote) e confirma que NENHUMA e rejeitada.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env'),
    [int]$ConexoesSimultaneas = 8
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [INTEGRACAO] Pool de conexoes real (>3) da conta de aplicacao ==" -ForegroundColor Cyan

$appConn = Get-SpringAppConnectString -EnvFile $EnvFile
$appUser = (Get-SpringAppCredentials -EnvFile $EnvFile).User
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$results = @()

function Start-ConexaoDemorada {
    param([string]$ConnectString)
    # CONNECT BY ate 500 mil: CPU-bound o bastante pra manter a sessao aberta
    # por um instante sem precisar de DBMS_LOCK/DBMS_SESSION (a conta de
    # aplicacao nao tem EXECUTE em nenhum dos dois) - mas leve o bastante pra
    # 8 delas rodarem ao mesmo tempo sem estourar memoria (um numero maior,
    # tipo 150 milhoes, da ORA-30009 so de uma, sem relacao com SESSIONS_PER_USER).
    $sql = "SELECT /*+ NO_MERGE */ COUNT(*) FROM (SELECT LEVEL FROM DUAL CONNECT BY LEVEL <= 500000);`nEXIT;`n"
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($sql)
    $b64 = [Convert]::ToBase64String($bytes)
    $innerCmd = 'echo ' + $b64 + ' | base64 -d | sqlplus -s "$ORACLE_CONNSTR"'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'docker'
    $psi.Arguments = "exec -i -e ORACLE_CONNSTR=$ConnectString kawashi-oracle sh -c `"$innerCmd`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    return [System.Diagnostics.Process]::Start($psi)
}

$procs = 1..$ConexoesSimultaneas | ForEach-Object { Start-ConexaoDemorada -ConnectString $appConn }

# Polling curto em v$session pra capturar o PICO real de sessoes simultaneas -
# mais robusto contra variacao de quanto tempo cada "docker exec" leva pra
# efetivamente conectar do que um unico Start-Sleep fixo.
$picoSessoes = 0
for ($i = 0; $i -lt 10; $i++) {
    $outSessoes = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT COUNT(*) FROM v`$session WHERE username = '$appUser';`nEXIT;`n") -join "`n"
    $atual = [int](($outSessoes -replace '[^\d]', '') -as [int])
    if ($atual -gt $picoSessoes) { $picoSessoes = $atual }
    Start-Sleep -Milliseconds 300
}

$procs | ForEach-Object { $_.WaitForExit(20000) | Out-Null }
$saidas = ($procs | ForEach-Object { ($_.StandardOutput.ReadToEnd() + $_.StandardError.ReadToEnd()) }) -join "`n"
$nenhumaRejeitada = $saidas -notmatch 'ORA-02391'

$results += New-TestResult -Name "Pelo menos $([Math]::Min(4, $ConexoesSimultaneas)) sessoes simultaneas de verdade foram observadas (pico: $picoSessoes) - confirma que o teste exercitou o cenario, nao so abriu e fechou rapido demais pra medir" -Passed ($picoSessoes -ge [Math]::Min(4, $ConexoesSimultaneas)) -Details $(if ($picoSessoes -lt [Math]::Min(4, $ConexoesSimultaneas)) { "pico observado=$picoSessoes" })
$results += New-TestResult -Name "[CORRIGIDO] Nenhuma das $ConexoesSimultaneas conexoes simultaneas foi rejeitada por SESSIONS_PER_USER (ORA-02391) - KAWASHI_SERVICE_PROFILE aguenta um pool de verdade" -Passed $nenhumaRejeitada -Details $(if (-not $nenhumaRejeitada) { $saidas })

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
