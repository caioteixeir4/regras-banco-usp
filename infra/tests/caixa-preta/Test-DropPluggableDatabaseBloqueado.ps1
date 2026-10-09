# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA (seguranca): confirma que NINGUEM alem de SYS/SYSTEM
    em nivel de CDB consegue derrubar o banco inteiro (DROP PLUGGABLE
    DATABASE, o equivalente Oracle de "DROP DATABASE") - nem um usuario comum,
    nem ENGINEER_USER (que tem DBA, mas so dentro do PDB FREEPDB1).

.DESCRIPTION
    Arquitetura multitenant do Oracle: cada "banco" deste projeto
    (FREEPDB1) e um PDB (Pluggable Database) dentro de um CDB (Container
    Database). Derrubar um PDB inteiro so e possivel conectado ao CDB$ROOT,
    com privilegio de nivel de CDB - nenhuma conta deste projeto (nem a mais
    privilegiada, ENGINEER_USER/DBA) tem esse privilegio, de proposito. Isso
    e verificado em DUAS camadas independentes:
      1. Nem usuario comum nem ENGINEER_USER conseguem trocar de container
         pro CDB$ROOT (ORA-01031) - sem isso, nem chegam perto do comando.
      2. Mesmo tentando o DROP PLUGGABLE DATABASE direto de dentro do PDB
         (sem trocar de container), o Oracle recusa a operacao de forma
         estrutural (ORA-65040), independente de privilegio.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [CAIXA-PRETA/SEGURANCA] DROP PLUGGABLE DATABASE (equivalente a DROP DATABASE) ==" -ForegroundColor Cyan

$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$username = New-ThrowawayUsername -Prefix 'TST_DROPDB'
$senha = New-StrongPassword -Length 16 -AvoidSubstring $username
$results = @()

try {
    Invoke-SqlPlus -ConnectString $engineerConn -Sql @"
ALTER SESSION SET CONTAINER = FREEPDB1;
CREATE USER $username IDENTIFIED BY "$senha" PROFILE KAWASHI_SECURE_PROFILE DEFAULT TABLESPACE TS_KAWASHI_DATA;
GRANT CREATE SESSION TO $username;
EXIT;
"@ | Out-Null
    $userConn = "$username/$senha@//localhost:1521/FREEPDB1"

    $outUserCdb = (Invoke-SqlPlus -ConnectString $userConn -Sql "ALTER SESSION SET CONTAINER = CDB`$ROOT;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Usuario comum NAO consegue trocar para CDB`$ROOT (ORA-01031)" -Passed ($outUserCdb -match 'ORA-01031') -Details $(if ($outUserCdb -notmatch 'ORA-01031') { $outUserCdb })

    $outEngineerCdb = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = CDB`$ROOT;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "ENGINEER_USER (DBA dentro do PDB) TAMBEM nao consegue trocar para CDB`$ROOT (ORA-01031)" -Passed ($outEngineerCdb -match 'ORA-01031') -Details $(if ($outEngineerCdb -notmatch 'ORA-01031') { $outEngineerCdb })

    $outUserDrop = (Invoke-SqlPlus -ConnectString $userConn -Sql "DROP PLUGGABLE DATABASE FREEPDB1 INCLUDING DATAFILES;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Usuario comum: DROP PLUGGABLE DATABASE direto do PDB e recusado estruturalmente (ORA-65040)" -Passed ($outUserDrop -match 'ORA-65040') -Details $(if ($outUserDrop -notmatch 'ORA-65040') { $outUserDrop })

    $outEngineerDrop = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP PLUGGABLE DATABASE FREEPDB1 INCLUDING DATAFILES;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "ENGINEER_USER: DROP PLUGGABLE DATABASE direto do PDB TAMBEM e recusado estruturalmente (ORA-65040)" -Passed ($outEngineerDrop -match 'ORA-65040') -Details $(if ($outEngineerDrop -notmatch 'ORA-65040') { $outEngineerDrop })
}
finally {
    Write-Host "-> Limpando usuario descartavel..."
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $username CASCADE;`nEXIT;`n" | Out-Null
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
