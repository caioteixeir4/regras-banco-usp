# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-BRANCA: confirma que a trilha de auditoria PROPRIA do
    projeto (KAWASHI_SECURITY_LOG, alimentada pelos triggers de sistema em
    infra/oracle-init/05_context_triggers.sql) realmente registra os eventos
    que ela promete - login, logoff, DDL e concessao de privilegio - com os
    dados certos (usuario, objeto, tipo).

.DESCRIPTION
    Esta e a trilha de auditoria "propria" da Kawashi (nao a Unified Auditing
    nativa do Oracle, que ja e usada indiretamente por outros testes). Ela
    nunca tinha sido testada de forma automatizada ate agora, apesar de ser o
    mecanismo central do "SIEM" que da nome ao projeto (ver README) e de
    mapear diretamente pro criterio "registro integro do evento correspondente
    na trilha de auditoria" do Projeto de Pesquisa do TCC.

    Cria um usuario descartavel simples (fora do fluxo de create-team-member.ps1
    de proposito, pra manter SESSION_USER = o proprio usuario de teste, sem a
    complicacao de identidade de proxy) e usa ele para gerar, na ordem: um
    login, uma DDL (CREATE TABLE) e um logoff. Usa o ENGINEER_USER para gerar
    um GRANT observavel. Usa um login NORMAL como SYSTEM (nao "/ as sysdba")
    pra confirmar a isencao de SYS/SYSTEM documentada no trigger - "/ as
    sysdba" nao serve pra isso porque esse tipo de conexao nao dispara
    nenhum "AFTER LOGON ON DATABASE" (ver nota em 05_context_triggers.sql).
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [CAIXA-BRANCA] Trilha de auditoria propria (KAWASHI_SECURITY_LOG) ==" -ForegroundColor Cyan

$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$username = New-ThrowawayUsername -Prefix 'TST_LOG'
$senha = New-StrongPassword -Length 16 -AvoidSubstring $username
$tabela = "TESTE_LOG_$((New-ThrowawayUsername -Prefix '').TrimStart('_'))"
$results = @()

function Get-LogCount {
    param([string]$Where)
    # KAWASHI_SECURITY_LOG e OWNED BY SYS (criada em 03_dynamic_tables.sql, que
    # roda no bootstrap do container como SYS) - mesma restricao ja vista em
    # KAWASHI_PASSWORD_VERIFY: o role DBA do ENGINEER_USER nao alcanca objetos
    # de SYS por causa do O7_DICTIONARY_ACCESSIBILITY. "/ as sysdba" sempre pode.
    $sql = "ALTER SESSION SET CONTAINER = FREEPDB1;`nSET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT COUNT(*) FROM KAWASHI_SECURITY_LOG WHERE $Where;`nEXIT;`n"
    $out = (Invoke-SqlPlus -ConnectString '/ as sysdba' -Sql $sql) -join "`n"
    $numero = ($out -replace '[^\d]', '')
    return [int]($numero -as [int])
}

try {
    Invoke-SqlPlus -ConnectString $engineerConn -Sql @"
ALTER SESSION SET CONTAINER = FREEPDB1;
CREATE USER $username IDENTIFIED BY "$senha" PROFILE KAWASHI_SECURE_PROFILE DEFAULT TABLESPACE TS_KAWASHI_DATA;
ALTER USER $username QUOTA 10M ON TS_KAWASHI_DATA;
GRANT CREATE SESSION, CREATE TABLE TO $username;
EXIT;
"@ | Out-Null

    # --- Login + DDL + logoff, tudo numa unica sessao do usuario de teste -----
    $userConn = "$username/$senha@//localhost:1521/FREEPDB1"
    Invoke-SqlPlus -ConnectString $userConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nCREATE TABLE $tabela (id NUMBER);`nEXIT;`n" | Out-Null

    $loginCount = Get-LogCount -Where "db_user = '$username' AND event_type = 'SUCCESSFUL_LOGIN'"
    $results += New-TestResult -Name "Login de '$username' gerou um registro SUCCESSFUL_LOGIN em KAWASHI_SECURITY_LOG" -Passed ($loginCount -ge 1) -Details $(if ($loginCount -lt 1) { "contagem=$loginCount" })

    $logoffCount = Get-LogCount -Where "db_user = '$username' AND event_type = 'SESSION_END'"
    $results += New-TestResult -Name "Logoff de '$username' gerou um registro SESSION_END" -Passed ($logoffCount -ge 1) -Details $(if ($logoffCount -lt 1) { "contagem=$logoffCount" })

    $ddlCount = Get-LogCount -Where "db_user = '$username' AND event_type = 'DDL_MODIFICATION' AND details LIKE '%$tabela%' AND details LIKE '%TABLE%'"
    $results += New-TestResult -Name "CREATE TABLE de '$username' gerou DDL_MODIFICATION com o nome certo do objeto e o tipo certo" -Passed ($ddlCount -ge 1) -Details $(if ($ddlCount -lt 1) { "contagem=$ddlCount" })

    # --- GRANT feito pelo engenheiro, observado no beneficiario -----------------
    # NOTA: o GRANT precisa ser de uma ROLE/privilegio de sistema (nao de um
    # privilegio objeto a objeto) de proposito - e exatamente o caso que
    # ORA_DICT_OBJ_NAME nao cobre (ver correcao em 05_context_triggers.sql).
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nGRANT KAWASHI_READONLY TO $username;`nEXIT;`n" | Out-Null
    $grantCount = Get-LogCount -Where "event_type = 'PRIVILEGE_GRANT_ALERT' AND details LIKE '%$username%' AND details LIKE '%KAWASHI_READONLY%'"
    $results += New-TestResult -Name "GRANT de role para '$username' gerou PRIVILEGE_GRANT_ALERT com o comando completo (role + beneficiario)" -Passed ($grantCount -ge 1) -Details $(if ($grantCount -lt 1) { "contagem=$grantCount" })

    # --- Acesso administrativo (SYSTEM) fica registrado, mas como evento distinto --
    $sysConn = Get-SystemConnectString -EnvFile $EnvFile
    Invoke-SqlPlus -ConnectString $sysConn -Sql "SELECT 1 FROM DUAL;`nEXIT;`n" | Out-Null
    $privCount = Get-LogCount -Where "db_user = 'SYSTEM' AND event_type = 'PRIVILEGED_LOGIN'"
    $results += New-TestResult -Name "Login como SYSTEM gera PRIVILEGED_LOGIN (nao SUCCESSFUL_LOGIN - isencao documentada no trigger)" -Passed ($privCount -ge 1) -Details $(if ($privCount -lt 1) { "contagem=$privCount" })
}
finally {
    Write-Host "-> Limpando usuario descartavel..."
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $username CASCADE;`nEXIT;`n" | Out-Null
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
