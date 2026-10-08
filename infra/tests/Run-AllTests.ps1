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
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\.env'),
    [ValidateSet('unitarios', 'caixa-branca', 'caixa-preta', 'outros')]
    [string[]]$Categoria = @('unitarios', 'caixa-branca', 'caixa-preta', 'outros')
)

$ErrorActionPreference = 'Stop'
$inicio = Get-Date
$totalPassou = 0
$totalFalhou = 0
$falhas = @()

foreach ($cat in $Categoria) {
    $pasta = Join-Path $PSScriptRoot $cat
    if (-not (Test-Path $pasta)) { continue }

    $scripts = Get-ChildItem -Path $pasta -Filter 'Test-*.ps1' | Sort-Object Name
    foreach ($script in $scripts) {
        Write-Host ""
        Write-Host "########################################################" -ForegroundColor DarkCyan
        Write-Host "## $cat / $($script.Name)" -ForegroundColor DarkCyan
        Write-Host "########################################################" -ForegroundColor DarkCyan

        $resultados = & $script.FullName -EnvFile $EnvFile

        foreach ($r in $resultados) {
            if ($r.Passed) { $totalPassou++ } else { $totalFalhou++; $falhas += "[$cat/$($script.Name)] $($r.Name)" }
        }
    }
}

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
