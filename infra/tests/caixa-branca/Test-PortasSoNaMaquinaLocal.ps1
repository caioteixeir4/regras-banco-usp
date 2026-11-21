# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-BRANCA: o docker-compose.yml publica as portas do banco (1521) e do Vault (8200)
    so na interface local da maquina (127.0.0.1), e nunca para a rede inteira.

.DESCRIPTION
    Sem o IP na frente, o Docker publica a porta em todas as interfaces, e qualquer um no mesmo
    Wi-Fi alcanca o Oracle e o Vault (este em HTTP puro, aceitando o token root em modo -dev).
    Este teste le o docker-compose.yml. O estado AO VIVO do container e conferido todo dia pela
    rotina-diaria.ps1, que acusa a porta exposta ate o container ser recriado.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')

Write-Host "== [CAIXA-BRANCA] Portas publicadas so na maquina local ==" -ForegroundColor Cyan

$compose = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\docker-compose.yml'))
$results = @()

# Linhas de porta publicadas ("- algo:porta"), ignorando comentarios.
$portas = @([regex]::Matches($compose, '(?m)^\s*-\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -match ':\d+$' -and $_ -notmatch '=' })

$results += New-TestResult -Name "O banco (1521) e publicado so em 127.0.0.1" -Passed ($portas -contains '127.0.0.1:1521:1521') -Details "portas no compose: $($portas -join ', ')"
$results += New-TestResult -Name "O Vault (8200) e publicado so em 127.0.0.1" -Passed ($portas -contains '127.0.0.1:8200:8200') -Details "portas no compose: $($portas -join ', ')"
$abertas = @($portas | Where-Object { $_ -notmatch '^127\.0\.0\.1:' })
$results += New-TestResult -Name "Nenhuma porta do compose fica aberta para a rede (toda publicacao comeca com 127.0.0.1)" -Passed ($abertas.Count -eq 0) -Details "abertas: $($abertas -join ', ')"

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
