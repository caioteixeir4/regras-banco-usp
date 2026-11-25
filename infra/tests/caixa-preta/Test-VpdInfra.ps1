# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: com o VPD (19_vpd_infra.sql), quem e do time de Infra entra no ambiente e nao
    ve nem altera nenhuma linha das tabelas de negocio; o time de Desenvolvimento e a API nao mudam.

.DESCRIPTION
    No ambiente TESTE_DEV (o que tem as tabelas da API), com duas pessoas descartaveis que entram por
    proxy no schema do ambiente, como o time faz de verdade:
      - a politica KAWASHI_INFRA_NAO_VE esta nas 5 tabelas de negocio dos ambientes que as tem;
      - a pessoa de perfil Infra le 0 linhas de cada tabela (o SYS ve as linhas de verdade) e nao
        consegue inserir nem alterar;
      - a pessoa de perfil Desenvolvedor, pelo mesmo caminho, ve as mesmas linhas que o SYS;
      - a pessoa de Infra nao consegue tirar a politica.
#>
[CmdletBinding()]
param(
    [string]$EnvFile
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Continue'
if (-not $EnvFile) { $EnvFile = Join-Path $PSScriptRoot '..\..\.env' }

Write-Host "== [CAIXA-PRETA] VPD: a equipe de Infra nao ve linha de negocio ==" -ForegroundColor Cyan

$amb = 'KAWASHI_ENV_TESTE_DEV'
$results = @()
$infra = New-ThrowawayUsername -Prefix 'TST_VPDI'
$dev = New-ThrowawayUsername -Prefix 'TST_VPDD'
# Senha descartavel, so deste teste (nunca aparece): letras, numeros e simbolo, como a politica de senha pede.
$senha = 'Vpd_' + [guid]::NewGuid().ToString('N').Substring(0, 16) + '#9a'
$tabelas = @('EMPRESA', 'FILIAL', 'PESSOA', 'CONTATO', 'ENDERECO')

function Invoke-Sys {
    param([string]$Sql)
    return (Invoke-SqlPlus -ConnectString '/ as sysdba' -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSET LINESIZE 400`nALTER SESSION SET CONTAINER = FREEPDB1;`n$Sql`nEXIT;`n") -join "`n"
}
function Invoke-Como {
    param([string]$Conn, [string]$Sql)
    return (Invoke-SqlPlus -ConnectString $Conn -Sql "SET PAGESIZE 0`nSET FEEDBACK ON`nSET LINESIZE 400`n$Sql`nEXIT;`n") -join "`n"
}
function Get-Contagens {
    param([string]$Conn)
    $sql = ($tabelas | ForEach-Object { "SELECT '$_=' || COUNT(*) FROM $amb.$_;" }) -join "`n"
    $saida = if ($Conn) { Invoke-Como $Conn $sql } else { Invoke-Sys $sql }
    return (($tabelas | ForEach-Object { [regex]::Match($saida, "$_=(\d+)").Value }) -join ' ')
}

try {
    $preparo = Invoke-Sys @"
CREATE USER $infra IDENTIFIED BY "$senha";
CREATE USER $dev IDENTIFIED BY "$senha";
GRANT CREATE SESSION TO $infra;
GRANT CREATE SESSION TO $dev;
ALTER USER $amb GRANT CONNECT THROUGH $infra;
ALTER USER $amb GRANT CONNECT THROUGH $dev;
EXEC SYS.KAWASHI_REGISTRAR_CONTA('$infra', 'PESSOA', 'Infra', 'Teste VPD Infra', 'Teste', 'INFRA');
EXEC SYS.KAWASHI_REGISTRAR_CONTA('$dev', 'PESSOA', 'Desenvolvedor', 'Teste VPD Dev', 'Teste', 'DEV');
SELECT 'OK' FROM dual;
"@
    $connInfra = "$infra[$amb]/$senha@//localhost:1521/FREEPDB1"
    $connDev = "$dev[$amb]/$senha@//localhost:1521/FREEPDB1"

    # --- as politicas ------------------------------------------------------------------------------
    $politicas = Invoke-Sys "SELECT 'P=' || COUNT(*) FROM dba_policies WHERE object_owner = '$amb' AND policy_name = 'KAWASHI_INFRA_NAO_VE' AND enable = 'YES';"
    $results += New-TestResult -Name "A politica KAWASHI_INFRA_NAO_VE esta ligada nas 5 tabelas de negocio do TESTE_DEV (o ambiente que as tem)" -Passed (($preparo -notmatch 'ORA-') -and ($politicas -match 'P=5')) -Details "$preparo`n$politicas"

    # --- o que cada um ve -------------------------------------------------------------------------------
    $sys = Get-Contagens $null
    $deInfra = Get-Contagens $connInfra
    $deDev = Get-Contagens $connDev
    $temLinhas = ($sys -match 'PESSOA=[1-9]') -and ($sys -match 'EMPRESA=[1-9]')
    $results += New-TestResult -Name "A pessoa de Infra, entrando por proxy no ambiente, le 0 linhas de cada tabela de negocio (o SYS ve as linhas de verdade)" -Passed ($temLinhas -and ($deInfra -eq 'EMPRESA=0 FILIAL=0 PESSOA=0 CONTATO=0 ENDERECO=0')) -Details "SYS: $sys`nInfra: $deInfra"
    $results += New-TestResult -Name "A pessoa de Desenvolvimento, pelo mesmo caminho, ve as mesmas linhas que o SYS (o VPD so afeta a Infra)" -Passed ($temLinhas -and ($deDev -eq $sys)) -Details "SYS: $sys`nDev: $deDev"

    # --- nem altera ------------------------------------------------------------------------------------
    $insere = Invoke-Como $connInfra "INSERT INTO $amb.EMPRESA (CNPJ, RAZAO_SOCIAL) VALUES ('11222333000181', 'Infra tentando');"
    $altera = Invoke-Como $connInfra "UPDATE $amb.PESSOA SET NOME = 'alterado pela infra';"
    $results += New-TestResult -Name "A pessoa de Infra nao insere (ORA-28115, violacao da politica) e o UPDATE nao acha nenhuma linha (0 linhas)" -Passed (($insere -match 'ORA-28115') -and ($altera -match '0 rows updated')) -Details "$insere`n$altera"

    # --- nem tira a politica ---------------------------------------------------------------------------
    $tira = Invoke-Como $connInfra "EXEC DBMS_RLS.DROP_POLICY('$amb', 'PESSOA', 'KAWASHI_INFRA_NAO_VE');"
    $depois = Invoke-Sys "SELECT 'P=' || COUNT(*) FROM dba_policies WHERE object_owner = '$amb' AND policy_name = 'KAWASHI_INFRA_NAO_VE';"
    $results += New-TestResult -Name "A pessoa de Infra nao consegue tirar a politica (sem permissao no DBMS_RLS), e as 5 continuam" -Passed (($tira -match 'PLS-00201|ORA-06550|ORA-01031|ORA-28104') -and ($depois -match 'P=5')) -Details "$tira`n$depois"
}
finally {
    Write-Host "-> Limpando: as duas pessoas de teste..."
    Invoke-Sys @"
DROP USER $infra CASCADE;
DROP USER $dev CASCADE;
DELETE FROM SYS.KAWASHI_CONTA WHERE USERNAME IN ('$infra', '$dev');
COMMIT;
"@ | Out-Null
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
