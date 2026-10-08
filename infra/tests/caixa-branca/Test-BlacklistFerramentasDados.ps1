# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-BRANCA: confirma que KAWASHI_FORBIDDEN_TOOLS (usada pela
    REGRA 4 de KAWASHI_CONTEXT_SECURITY_TRG) contem os padroes esperados e que
    a logica de match (LIKE, case-insensitive via UPPER) realmente bloqueia o
    que deveria e deixa passar o que deveria.

.DESCRIPTION
    Nao da pra testar esta regra via uma conexao de verdade (black-box): o
    CLIENT_PROGRAM_NAME que o trigger le e definido pelo cliente de rede na
    hora do logon, nao e algo que de pra fingir rodando sqlplus por dentro de
    um "docker exec" (ver racional completo no cabecalho deste teste, analogo
    ao de Test-BloqueioOsUserInseguro.ps1). Por isso aqui reproduzimos a MESMA
    condicao WHERE do trigger (ver 05_context_triggers.sql, Regra 4) num
    SELECT direto, tratando-a como a unidade de logica sob teste.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')

Write-Host "== [CAIXA-BRANCA] Dados e logica de match da blacklist de ferramentas ==" -ForegroundColor Cyan

$results = @()

# KAWASHI_FORBIDDEN_TOOLS e OWNED BY SYS (criada em 03_dynamic_tables.sql, que
# roda no bootstrap como SYS) - mesma restricao ja vista varias vezes nesta
# suite (O7_DICTIONARY_ACCESSIBILITY): o role DBA do ENGINEER_USER nao alcanca
# objetos de SYS por padrao. "/ as sysdba" sempre pode.
$sqlPadroes = @'
ALTER SESSION SET CONTAINER = FREEPDB1;
SET PAGESIZE 0
SET FEEDBACK OFF
SELECT tool_pattern FROM KAWASHI_FORBIDDEN_TOOLS ORDER BY tool_pattern;
EXIT;
'@
$outPadroes = (Invoke-SqlPlus -ConnectString '/ as sysdba' -Sql $sqlPadroes) -join "`n"
foreach ($padraoEsperado in '%PYTHON%', '%TOAD%', '%SQLMAP%', '%EXCEL%') {
    $results += New-TestResult -Name "Blacklist contem o padrao $padraoEsperado" -Passed ($outPadroes -match [regex]::Escape($padraoEsperado)) -Details $(if ($outPadroes -notmatch [regex]::Escape($padraoEsperado)) { $outPadroes })
}

function Test-ProgramaBloqueado {
    param([string]$NomePrograma)
    # Replica EXATAMENTE a condicao da Regra 4 do trigger: o programa (ja em
    # UPPER, como o trigger faz) contra cada padrao da tabela via LIKE.
    $sql = "ALTER SESSION SET CONTAINER = FREEPDB1;`nSET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT COUNT(*) FROM KAWASHI_FORBIDDEN_TOOLS WHERE '$($NomePrograma.ToUpper())' LIKE TOOL_PATTERN;`nEXIT;`n"
    $out = ((Invoke-SqlPlus -ConnectString '/ as sysdba' -Sql $sql) -join "`n").Trim()
    $numero = [regex]::Match($out, '\d+$')
    return $numero.Success -and ([int]$numero.Value -gt 0)
}

$casos = @(
    @{ Programa = 'python3.11';        DeveriaBloquear = $true;  Descricao = 'cliente Python' }
    @{ Programa = 'Toad.exe';          DeveriaBloquear = $true;  Descricao = 'Toad for Oracle' }
    @{ Programa = 'sqlmap';            DeveriaBloquear = $true;  Descricao = 'sqlmap (ferramenta de SQLi)' }
    @{ Programa = 'EXCEL.EXE';         DeveriaBloquear = $true;  Descricao = 'Excel (ODBC/consulta externa)' }
    @{ Programa = 'sqlplus.exe';       DeveriaBloquear = $false; Descricao = 'sqlplus (ferramenta oficial, nunca deveria ser bloqueada)' }
    @{ Programa = 'sqldeveloper.exe';  DeveriaBloquear = $false; Descricao = 'SQL Developer (ferramenta oficial da Oracle)' }
    @{ Programa = 'java.exe';          DeveriaBloquear = $false; Descricao = 'cliente Java/JDBC generico (microsservico Spring)' }
)

foreach ($caso in $casos) {
    $bloqueado = Test-ProgramaBloqueado -NomePrograma $caso.Programa
    $passou = ($bloqueado -eq $caso.DeveriaBloquear)
    $veredito = if ($caso.DeveriaBloquear) { 'E bloqueado' } else { 'NAO e bloqueado' }
    $results += New-TestResult -Name "$($caso.Descricao) ('$($caso.Programa)') $veredito pela blacklist" -Passed $passou -Details $(if (-not $passou) { "esperado bloqueado=$($caso.DeveriaBloquear), observado=$bloqueado" })
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
