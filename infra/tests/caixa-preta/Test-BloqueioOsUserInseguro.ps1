# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: confirma que a REGRA 3 de KAWASHI_CONTEXT_SECURITY_TRG
    (infra/oracle-init/05_context_triggers.sql) - a unica das 4 regras do
    trigger de logon que bloqueia de verdade, nao so registra e deixa passar -
    realmente rejeita login vindo de um usuario de sistema operacional
    "ROOT"/"ADMINISTRATOR"/"GUEST".

.DESCRIPTION
    Nenhum teste anterior tinha exercitado esta regra - era so codigo lido,
    nunca observado em acao. So o comportamento externo importa aqui: muda o
    usuario de SO que o cliente sqlplus roda (via "docker exec -u root") e
    observa se o login e aceito ou negado.

.NOTES
    ACHADO TESTANDO AO VIVO (nao e bug no codigo da Kawashi, e uma
    caracteristica do proprio Oracle que vale documentar): esta regra bloqueia
    de verdade um usuario comum (so CREATE SESSION), mas NAO bloqueia nenhuma
    conta com a role DBA - confirmado concedendo DBA a um usuario descartavel
    e repetindo o mesmo teste. Ou seja, a unica conta que este controle
    efetivamente NAO protege e justamente a mais privilegiada do sistema
    (ENGINEER_USER, que tem DBA). Isso nao e um "bug" que da pra corrigir
    dentro do trigger (a excecao nao vem de nenhuma linha deste codigo - o
    trigger trata TODAS as contas igual, exceto o RETURN explicito pra
    SYS/SYSTEM) - e uma limitacao do proprio mecanismo de trigger de logon do
    Oracle para sessoes com privilegio suficiente, que fica registrada aqui
    como teste (em vez de só numa nota em algum canto) para o caso de um dia
    isso mudar - ou pra evitar que alguem assuma por engano que esta regra
    tambem protege contas administrativas.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [CAIXA-PRETA] Bloqueio de usuario de SO inseguro (REGRA 3) ==" -ForegroundColor Cyan

$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$results = @()

function Invoke-SqlPlusComoOsUser {
    param([string]$OsUser, [string]$ConnectString, [string]$Sql)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Sql)
    $b64 = [Convert]::ToBase64String($bytes)
    $innerCmd = 'echo ' + $b64 + ' | base64 -d | sqlplus -s "$ORACLE_CONNSTR"'
    if ($OsUser) {
        return docker exec -u $OsUser -i -e ORACLE_CONNSTR="$ConnectString" kawashi-oracle sh -c "$innerCmd" 2>&1
    }
    return docker exec -i -e ORACLE_CONNSTR="$ConnectString" kawashi-oracle sh -c "$innerCmd" 2>&1
}

$username = New-ThrowawayUsername -Prefix 'TST_ROOTB'
$senha = New-StrongPassword -Length 16 -AvoidSubstring $username
$usernameDba = New-ThrowawayUsername -Prefix 'TST_ROOTB_DBA'
$senhaDba = New-StrongPassword -Length 16 -AvoidSubstring $usernameDba

try {
    Invoke-SqlPlus -ConnectString $engineerConn -Sql @"
ALTER SESSION SET CONTAINER = FREEPDB1;
CREATE USER $username IDENTIFIED BY "$senha" PROFILE KAWASHI_SECURE_PROFILE DEFAULT TABLESPACE TS_KAWASHI_DATA;
GRANT CREATE SESSION TO $username;
CREATE USER $usernameDba IDENTIFIED BY "$senhaDba" PROFILE KAWASHI_SECURE_PROFILE DEFAULT TABLESPACE TS_KAWASHI_DATA;
GRANT CREATE SESSION TO $usernameDba;
GRANT DBA TO $usernameDba;
EXIT;
"@ | Out-Null

    $userConn = "$username/$senha@//localhost:1521/FREEPDB1"
    $dbaConn = "$usernameDba/$senhaDba@//localhost:1521/FREEPDB1"

    $outNormal = (Invoke-SqlPlusComoOsUser -OsUser $null -ConnectString $userConn -Sql "SELECT 1 FROM DUAL;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Usuario comum conecta normalmente quando o SO do cliente NAO e root/administrator/guest (controle negativo)" -Passed ($outNormal -notmatch 'ORA-\d{5}') -Details $(if ($outNormal -match 'ORA-\d{5}') { $outNormal })

    $outRoot = (Invoke-SqlPlusComoOsUser -OsUser 'root' -ConnectString $userConn -Sql "SELECT 1 FROM DUAL;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Usuario comum (so CREATE SESSION) e REJEITADO quando o SO do cliente e 'root' (ORA-20003)" -Passed ($outRoot -match 'ORA-20003') -Details $(if ($outRoot -notmatch 'ORA-20003') { $outRoot })

    $outRootDba = (Invoke-SqlPlusComoOsUser -OsUser 'root' -ConnectString $dbaConn -Sql "SELECT 1 FROM DUAL;`nEXIT;`n") -join "`n"
    $naoBloqueou = $outRootDba -notmatch 'ORA-\d{5}'
    $results += New-TestResult -Name "[LIMITACAO CONHECIDA] Uma conta com role DBA NAO e bloqueada mesmo com SO 'root' - documentado, nao e bug do codigo Kawashi" -Passed $naoBloqueou -Details $(if (-not $naoBloqueou) { "Comportamento mudou! Revisar nota deste teste: $outRootDba" })
}
finally {
    Write-Host "-> Limpando usuarios descartaveis..."
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $username CASCADE;`nDROP USER $usernameDba CASCADE;`nEXIT;`n" | Out-Null
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
