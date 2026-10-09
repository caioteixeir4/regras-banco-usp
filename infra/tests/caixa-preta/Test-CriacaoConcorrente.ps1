# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA (concorrencia): roda varias chamadas de
    create-team-member.ps1 AO MESMO TEMPO, para usuarios diferentes, e
    confirma que todas terminam com sucesso e sem contaminacao cruzada entre
    elas.

.DESCRIPTION
    create-team-member.ps1 tem pelo menos um trecho check-then-act classico
    (checa se o metodo "userpass" ja esta habilitado no Vault antes de tentar
    habilitar) que e um candidato natural a race condition quando dois
    onboardings rodam ao mesmo tempo - o primeiro ve "nao habilitado" e tenta
    habilitar, o segundo ve a mesma coisa e tambem tenta, e um dos dois leva
    um erro do Vault ("path is already in use"). Este teste nao verifica o
    codigo-fonte; ele realmente dispara N onboardings concorrentes (via
    Start-Job do PowerShell, processos de verdade) e observa se o RESULTADO
    final de cada um esta correto e isolado dos outros.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env'),
    [int]$Concorrencia = 3
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [CAIXA-PRETA] $Concorrencia criacoes de usuario simultaneas ==" -ForegroundColor Cyan

$createScript = Join-Path $PSScriptRoot '..\..\scripts\create-team-member.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken = Get-VaultToken -EnvFile $EnvFile
$results = @()

$usuarios = 1..$Concorrencia | ForEach-Object { New-ThrowawayUsername -Prefix "TST_CONC$_" }

$jobs = $usuarios | ForEach-Object {
    $username = $_
    Start-Job -ScriptBlock {
        param($CreateScript, $Username, $EnvFile)
        try {
            & $CreateScript -Username $Username -Profile 'EstagiarioDev' -EnvFile $EnvFile *> $null
            return @{ Username = $Username; Ok = $true; Erro = $null }
        } catch {
            return @{ Username = $Username; Ok = $false; Erro = $_.Exception.Message }
        }
    } -ArgumentList $createScript, $username, $EnvFile
}

Write-Host "-> Aguardando as $Concorrencia criacoes simultaneas terminarem..."
$jobs | Wait-Job | Out-Null
$resultadosJobs = $jobs | Receive-Job
$jobs | Remove-Job

try {
    foreach ($r in $resultadosJobs) {
        $results += New-TestResult -Name "Onboarding concorrente de '$($r.Username)' terminou com sucesso" -Passed $r.Ok -Details $(if (-not $r.Ok) { $r.Erro })
    }

    # --- Isolamento: cada usuario so enxerga seu proprio segredo/policy, sem
    # misturar dados de outro onboarding que rodou ao mesmo tempo -------------
    foreach ($username in $usuarios) {
        $kvJson = (docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv get -format=json "kawashi-secrets/onboarding/$username" 2>&1) -join "`n"
        $kvObj = $kvJson | ConvertFrom-Json -ErrorAction SilentlyContinue
        $dbUsernameNoSegredo = $kvObj.data.data.db_username
        $results += New-TestResult -Name "Segredo de onboarding de '$username' contem o PROPRIO username (nao o de outro onboarding concorrente)" -Passed ($dbUsernameNoSegredo -eq $username) -Details $(if ($dbUsernameNoSegredo -ne $username) { "esperado=$username observado=$dbUsernameNoSegredo" })

        $policyHcl = (docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault policy read "engineer-$($username.ToLower())" 2>&1) -join "`n"
        $outrosUsuarios = $usuarios | Where-Object { $_ -ne $username }
        $vazou = $false
        foreach ($outro in $outrosUsuarios) {
            if ($policyHcl -match [regex]::Escape($outro)) { $vazou = $true }
        }
        $results += New-TestResult -Name "Policy de '$username' NAO menciona nenhum outro usuario criado na mesma leva concorrente" -Passed (-not $vazou) -Details $(if ($vazou) { $policyHcl })
    }

    # --- Todos os usuarios Oracle realmente existem, cada um com seu nome ----
    $outUsuarios = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT username FROM dba_users WHERE username IN ($(($usuarios | ForEach-Object { "'$_'" }) -join ','));`nEXIT;`n") -join "`n"
    $todosExistem = ($usuarios | Where-Object { $outUsuarios -notmatch [regex]::Escape($_) }).Count -eq 0
    $results += New-TestResult -Name "Todos os $Concorrencia usuarios Oracle foram criados de verdade (nenhum perdido na corrida)" -Passed $todosExistem -Details $(if (-not $todosExistem) { $outUsuarios })
}
finally {
    Write-Host "-> Limpando usuarios descartaveis e artefatos no Vault..."
    foreach ($username in $usuarios) {
        Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $username CASCADE;`nEXIT;`n" | Out-Null
        $policyName = "engineer-$($username.ToLower())"
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault policy delete $policyName 2>&1 | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault delete "auth/userpass/users/$username" 2>&1 | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv delete "kawashi-secrets/onboarding/$username" 2>&1 | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv delete "kawashi-secrets/engineers/$username" 2>&1 | Out-Null
    }
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
