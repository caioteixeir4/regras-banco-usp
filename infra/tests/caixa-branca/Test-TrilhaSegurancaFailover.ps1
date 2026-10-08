# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-BRANCA (resiliencia): forca KAWASHI_WRITE_SECURITY_LOG a
    falhar de verdade na gravacao principal, de um jeito seguro e controlado,
    e confirma que a "trava" de seguranca documentada em
    infra/oracle-init/04_security_procedures.sql - cair no fallback em vez de
    perder o evento OU travar quem chamou - realmente funciona.

.DESCRIPTION
    Isto nao e um teste hipotetico: o item 11 de infra/docs/bugs-primeiro-teste.md
    documenta que esse exato mecanismo de fallback ficou rodando por engano no
    lugar do log principal durante toda a vida do projeto (1782 vezes) sem
    ninguem perceber - ou seja, ele "funciona bem demais" no sentido de nunca
    quebrar nada visivelmente, o que e exatamente o risco de nunca testar essa
    trava de proposito.

    A falha e forcada chamando a procedure DIRETAMENTE (nao atraves de login/
    DDL/GRANT) com um P_DETAILS maior que a coluna DETAILS(4000) aguenta -
    garante ORA-12899 (value too large for column) na gravacao principal, sem
    mexer em nenhuma tabela, trigger ou privilegio do ambiente.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')

Write-Host "== [CAIXA-BRANCA] Resiliencia do mecanismo de log (fallback sob falha forcada) ==" -ForegroundColor Cyan

$results = @()
$marcador = "TESTE_FAILOVER_$((New-ThrowawayUsername -Prefix '').TrimStart('_'))"
$detalhesGigantes = $marcador + ('X' * 4500)

$sql = @"
ALTER SESSION SET CONTAINER = FREEPDB1;
BEGIN
    KAWASHI_WRITE_SECURITY_LOG('$marcador', '$detalhesGigantes');
END;
/
EXIT;
"@
$outChamada = (Invoke-SqlPlus -ConnectString '/ as sysdba' -Sql $sql) -join "`n"
$results += New-TestResult -Name "Chamar KAWASHI_WRITE_SECURITY_LOG com DETAILS maior que a coluna NAO propaga erro pra quem chamou (a procedure engole, por design)" -Passed ($outChamada -match 'PL/SQL procedure successfully completed') -Details $(if ($outChamada -notmatch 'PL/SQL procedure successfully completed') { $outChamada })

$sqlChecar = @"
ALTER SESSION SET CONTAINER = FREEPDB1;
SET PAGESIZE 0
SET FEEDBACK OFF
SELECT COUNT(*) FROM KAWASHI_SECURITY_LOG WHERE EVENT_TYPE = '$marcador';
SELECT COUNT(*) FROM KAWASHI_SECURITY_LOG_FALLBACK WHERE ERROR_MSG LIKE '%$marcador%';
EXIT;
"@
$outChecar = (Invoke-SqlPlus -ConnectString '/ as sysdba' -Sql $sqlChecar) -join "`n"
$linhas = $outChecar -split "`n" | Where-Object { $_ -match '^\s*\d+\s*$' } | ForEach-Object { [int]$_.Trim() }

$results += New-TestResult -Name "A gravacao PRINCIPAL nao recebeu o evento (confirma que a falha de verdade aconteceu, nao que o teste nao testou nada)" -Passed ($linhas[0] -eq 0) -Details $(if ($linhas[0] -ne 0) { "linhas na trilha principal=$($linhas[0])" })
$results += New-TestResult -Name "O FALLBACK recebeu o registro da falha, mencionando o evento original" -Passed ($linhas[1] -ge 1) -Details $(if ($linhas[1] -lt 1) { "linhas no fallback=$($linhas[1])" })

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
