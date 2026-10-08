# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-BRANCA: confere que cada role do projeto tem EXATAMENTE o
    conjunto de privilegios de sistema declarado nos scripts de bootstrap -
    nem a mais (violaria least privilege), nem a menos (quebraria o perfil
    correspondente).

.DESCRIPTION
    Consulta DBA_SYS_PRIVS diretamente por role e compara como CONJUNTO (nao
    so "contem os esperados") contra o que infra/oracle-init/01_setup_kawashi.sql
    e 06_access_management.sql declaram. Uma role com um privilegio A MAIS do
    que o documentado e, na pratica, um vazamento silencioso de permissao que
    nenhum teste de comportamento (caixa-preta) pegaria se ninguem soubesse
    testar justamente aquele privilegio extra.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')

Write-Host "== [CAIXA-BRANCA] Privilegios exatos de cada role ==" -ForegroundColor Cyan

$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile

# Privilegios esperados por role, exatamente como declarados nos scripts de
# bootstrap (ver referencias no .DESCRIPTION acima).
$rolesEsperadas = [ordered]@{
    'ROLE_KAWASHI_DEVELOPER'      = @('CREATE SESSION', 'CREATE TABLE', 'CREATE VIEW')
    'ROLE_KAWASHI_INFRA'          = @('CREATE SESSION', 'SELECT ANY DICTIONARY')
    'ROLE_KAWASHI_HOMOLOG_VIEWER' = @('CREATE SESSION')
    'KAWASHI_READWRITE'           = @('CREATE SESSION', 'CREATE TABLE', 'CREATE VIEW', 'CREATE SEQUENCE', 'CREATE PROCEDURE', 'CREATE TRIGGER')
    'KAWASHI_READONLY'            = @('CREATE SESSION')
}

$results = @()

foreach ($role in $rolesEsperadas.Keys) {
    $sql = "SET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT privilege FROM dba_sys_privs WHERE grantee = '$role' ORDER BY privilege;`nEXIT;`n"
    $output = (Invoke-SqlPlus -ConnectString $engineerConn -Sql $sql) -join "`n"
    $privilegiosReais = @($output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    $esperados = @($rolesEsperadas[$role] | Sort-Object)
    $reais = @($privilegiosReais | Sort-Object)

    $faltando = @($esperados | Where-Object { $_ -notin $reais })
    $aMais = @($reais | Where-Object { $_ -notin $esperados })
    $passou = ($faltando.Count -eq 0) -and ($aMais.Count -eq 0)

    $detalhe = ''
    if ($faltando.Count -gt 0) { $detalhe += "faltando: $($faltando -join ', '). " }
    if ($aMais.Count -gt 0) { $detalhe += "privilegios A MAIS nao documentados: $($aMais -join ', '). " }

    $results += New-TestResult -Name "Role $role tem exatamente os privilegios esperados ($($esperados -join ', '))" -Passed $passou -Details $detalhe
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
