# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Roda todos os testes de infra/tests/* em sequencia e imprime um resumo
    agregado no final.

.DESCRIPTION
    Ordem fixa (do mais isolado para o mais integrado): unitarios ->
    caixa-branca -> caixa-preta -> outros. Cada pasta e uma categoria; cada
    arquivo "Test-*.ps1" dentro dela e um teste independente, que cria e
    remove seus proprios dados descartaveis - pode ser rodado sozinho ou
    atraves deste orquestrador.

    Requer os containers kawashi-oracle e kawashi-vault no ar (docker compose
    up) e o Vault ja inicializado (infra/scripts/vault-init.ps1) - ver
    infra/tests/README.md.

.PARAMETER EnvFile
    Caminho do .env com as credenciais do ENGINEER_USER e do Vault. Padrao: infra/.env.

.EXAMPLE
    ./Run-AllTests.ps1

.EXAMPLE
    ./Run-AllTests.ps1 -Categoria caixa-preta
#>
[CmdletBinding()]
param(
    [string]$EnvFile,
    [ValidateSet('unitarios', 'caixa-branca', 'caixa-preta', 'outros')]
    [string[]]$Categoria = @('unitarios', 'caixa-branca', 'caixa-preta', 'outros')
)

$ErrorActionPreference = 'Stop'
# Padrao do -EnvFile calculado AQUI: com [CmdletBinding()] e "powershell -File", o $PSScriptRoot fica vazio no bloco param.
if (-not $EnvFile) { $EnvFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\.env' }
$inicio = Get-Date
$totalPassou = 0
$totalFalhou = 0
$falhas = @()

# O Vault roda em modo "-dev" (memoria): todo restart do container (ou do Docker Desktop) apaga o
# engine de segredos e o metodo de login. Sem eles, o primeiro teste que usa o Vault falha com um
# erro que nao diz a causa. O vault-init.ps1 e idempotente, entao roda sempre antes da suite.
Write-Host "-> Garantindo que o Vault esta inicializado (vault-init.ps1)..." -ForegroundColor DarkCyan
& (Join-Path $PSScriptRoot '..\scripts\vault-init.ps1') -EnvFile $EnvFile | Out-Null

foreach ($cat in $Categoria) {
    $pasta = Join-Path $PSScriptRoot $cat
    if (-not (Test-Path $pasta)) { continue }

    $scripts = Get-ChildItem -Path $pasta -Filter 'Test-*.ps1' | Sort-Object Name
    foreach ($script in $scripts) {
        Write-Host ""
        Write-Host "########################################################" -ForegroundColor DarkCyan
        Write-Host "## $cat / $($script.Name)" -ForegroundColor DarkCyan
        Write-Host "########################################################" -ForegroundColor DarkCyan

        # Um teste que LANCA excecao (em vez de devolver um resultado com falha) nao pode derrubar
        # a suite inteira sem resumo: conta como uma falha daquele arquivo e a execucao segue.
        try {
            $resultados = & $script.FullName -EnvFile $EnvFile
        } catch {
            Write-Host "  [ERRO]  O arquivo de teste abortou: $($_.Exception.Message)" -ForegroundColor Red
            $resultados = @([pscustomobject]@{ Passed = $false; Name = "arquivo abortou: $($_.Exception.Message)" })
        }

        foreach ($r in $resultados) {
            if ($r.Passed) { $totalPassou++ } else { $totalFalhou++; $falhas += "[$cat/$($script.Name)] $($r.Name)" }
        }
    }
}

# As contas descartaveis dos testes (TST_*) passam pelo cadastro de contas (SYS.KAWASHI_CONTA) e
# sao apagadas do banco no fim de cada teste; o cadastro delas ficaria para sempre como "REMOVIDA".
# So sai o que e de teste E ja nao existe no banco.
$limpeza = "ALTER SESSION SET CONTAINER = FREEPDB1;`nDELETE FROM SYS.KAWASHI_CONTA WHERE USERNAME LIKE 'TST\_%' ESCAPE '\' AND USERNAME NOT IN (SELECT username FROM dba_users);`nCOMMIT;`nEXIT;`n"
$b64Limpeza = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($limpeza))
docker exec -i kawashi-oracle sh -c ('echo ' + $b64Limpeza + " | base64 -d | sqlplus -s '/ as sysdba'") 2>&1 | Out-Null

$duracao = (Get-Date) - $inicio

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "RESUMO: $totalPassou passaram, $totalFalhou falharam ($('{0:N1}' -f $duracao.TotalSeconds)s)" -ForegroundColor $(if ($totalFalhou -eq 0) { 'Green' } else { 'Red' })
if ($falhas.Count -gt 0) {
    Write-Host "Falhas:" -ForegroundColor Red
    $falhas | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}
Write-Host "========================================================" -ForegroundColor Cyan

exit $(if ($totalFalhou -eq 0) { 0 } else { 1 })
