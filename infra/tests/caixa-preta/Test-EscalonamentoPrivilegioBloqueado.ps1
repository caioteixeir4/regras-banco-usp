# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: confirma que um usuario comum (sem ADMIN OPTION em
    nada) NAO consegue conceder roles/privilegios a si mesmo ou a outra conta
    - a defesa mais basica contra escalonamento de privilegio silencioso.

.DESCRIPTION
    So observa o resultado de tentativas de GRANT feitas pelo proprio usuario
    de teste contra si mesmo e contra uma terceira conta - nunca inspeciona
    catalogo pra decidir o resultado.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [CAIXA-PRETA] Usuario comum nao consegue se autoconceder privilegio ==" -ForegroundColor Cyan

$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$username = New-ThrowawayUsername -Prefix 'TST_ESCAL'
$senha = New-StrongPassword -Length 16 -AvoidSubstring $username
$terceiro = New-ThrowawayUsername -Prefix 'TST_VITIMA'
$senhaTerceiro = New-StrongPassword -Length 16 -AvoidSubstring $terceiro
$results = @()

try {
    Invoke-SqlPlus -ConnectString $engineerConn -Sql @"
ALTER SESSION SET CONTAINER = FREEPDB1;
CREATE USER $username IDENTIFIED BY "$senha" PROFILE KAWASHI_SECURE_PROFILE DEFAULT TABLESPACE TS_KAWASHI_DATA;
GRANT CREATE SESSION TO $username;
CREATE USER $terceiro IDENTIFIED BY "$senhaTerceiro" PROFILE KAWASHI_SECURE_PROFILE DEFAULT TABLESPACE TS_KAWASHI_DATA;
GRANT CREATE SESSION TO $terceiro;
EXIT;
"@ | Out-Null

    $userConn = "$username/$senha@//localhost:1521/FREEPDB1"

    $outSelf = (Invoke-SqlPlus -ConnectString $userConn -Sql "GRANT DBA TO $username;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "'$username' NAO consegue se autoconceder DBA (ORA-01031)" -Passed ($outSelf -match 'ORA-01031') -Details $(if ($outSelf -notmatch 'ORA-01031') { $outSelf })

    # Oracle responde ORA-01924 (nao ORA-01031) quando quem tenta conceder nem
    # teria visibilidade de que a role existe - ambos confirmam a negacao.
    $outRoleSelf = (Invoke-SqlPlus -ConnectString $userConn -Sql "GRANT ROLE_KAWASHI_INFRA TO $username;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "'$username' NAO consegue se autoconceder uma role do projeto" -Passed ($outRoleSelf -match 'ORA-01031|ORA-01924') -Details $(if ($outRoleSelf -notmatch 'ORA-01031|ORA-01924') { $outRoleSelf })

    $outTerceiro = (Invoke-SqlPlus -ConnectString $userConn -Sql "GRANT CREATE TABLE TO $terceiro;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "'$username' NAO consegue conceder privilegio a OUTRA conta (ORA-01031)" -Passed ($outTerceiro -match 'ORA-01031') -Details $(if ($outTerceiro -notmatch 'ORA-01031') { $outTerceiro })

    # Controle positivo: o proprio ENGINEER_USER (DBA de verdade) consegue
    # conceder normalmente - confirma que o teste esta checando ausencia de
    # privilegio, nao algum outro erro generico de ambiente.
    $outEngineer = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nGRANT CREATE TABLE TO $terceiro;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "(controle positivo) ENGINEER_USER consegue conceder o mesmo privilegio normalmente" -Passed ($outEngineer -match 'Grant succeeded') -Details $(if ($outEngineer -notmatch 'Grant succeeded') { $outEngineer })
}
finally {
    Write-Host "-> Limpando usuarios descartaveis..."
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $username CASCADE;`nDROP USER $terceiro CASCADE;`nEXIT;`n" | Out-Null
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
