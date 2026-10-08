# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-BRANCA: confere, direto nos catalogos internos do Oracle,
    que o usuario de aplicacao (SPRING_APP_USER, hoje KAWASHI_SPRING_USER) saiu
    de infra/oracle-init/06_access_management.sql com exatamente o hardening
    pretendido - inclusive os dois pontos que ja foram bug neste projeto (ver
    itens 2 e 4 de infra/docs/bugs-primeiro-teste.md).

.DESCRIPTION
    Esta e a conta que o microsservico Java/Spring vai usar de verdade (via
    pool de conexao JDBC) quando existir - diferente das contas de pessoa
    criadas por create-team-member.ps1, ninguem troca a senha dela
    interativamente, entao qualquer coisa errada aqui so apareceria quando o
    pool de conexao da aplicacao falhasse em produção.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')

Write-Host "== [CAIXA-BRANCA] Hardening interno do usuario de aplicacao (Spring) ==" -ForegroundColor Cyan

$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$appUser = (Get-SpringAppCredentials -EnvFile $EnvFile).User

$sql = @"
SET PAGESIZE 0
SET FEEDBACK OFF
SET LINESIZE 200
SELECT 'PROFILE=' || profile FROM dba_users WHERE username = '$appUser';
SELECT 'DEFAULT_TABLESPACE=' || default_tablespace FROM dba_users WHERE username = '$appUser';
SELECT 'PASSWORD_EXPIRADA=' || CASE WHEN account_status LIKE '%EXPIRED%' THEN 'SIM' ELSE 'NAO' END FROM dba_users WHERE username = '$appUser';
SELECT 'QUOTA_DATA=' || CASE WHEN max_bytes = -1 THEN 'UNLIMITED' ELSE TO_CHAR(max_bytes) END FROM dba_ts_quotas WHERE username = '$appUser' AND tablespace_name = 'TS_KAWASHI_DATA';
SELECT 'TEM_UNLIMITED_TABLESPACE=' || CASE WHEN EXISTS (
    SELECT 1 FROM dba_sys_privs WHERE grantee = '$appUser' AND privilege = 'UNLIMITED TABLESPACE'
) THEN 'SIM' ELSE 'NAO' END FROM dual;
SELECT 'TEM_DB_DEVELOPER_ROLE=' || CASE WHEN EXISTS (
    SELECT 1 FROM dba_role_privs WHERE grantee = '$appUser' AND granted_role = 'DB_DEVELOPER_ROLE'
) THEN 'SIM' ELSE 'NAO' END FROM dual;
SELECT 'TEM_KAWASHI_READWRITE=' || CASE WHEN EXISTS (
    SELECT 1 FROM dba_role_privs WHERE grantee = '$appUser' AND granted_role = 'KAWASHI_READWRITE'
) THEN 'SIM' ELSE 'NAO' END FROM dual;
SELECT 'SESSIONS_PER_USER=' || limit FROM dba_profiles WHERE profile = 'KAWASHI_SERVICE_PROFILE' AND resource_name = 'SESSIONS_PER_USER';
SELECT 'IDLE_TIME=' || limit FROM dba_profiles WHERE profile = 'KAWASHI_SERVICE_PROFILE' AND resource_name = 'IDLE_TIME';
SELECT 'CONNECT_TIME=' || limit FROM dba_profiles WHERE profile = 'KAWASHI_SERVICE_PROFILE' AND resource_name = 'CONNECT_TIME';
SELECT 'PASSWORD_LIFE_TIME=' || limit FROM dba_profiles WHERE profile = 'KAWASHI_SERVICE_PROFILE' AND resource_name = 'PASSWORD_LIFE_TIME';
EXIT;
"@
$output = (Invoke-SqlPlus -ConnectString $engineerConn -Sql $sql) -join "`n"

$casos = @(
    @{ Esperado = 'PROFILE=KAWASHI_SERVICE_PROFILE';     Descricao = "Usuario de aplicacao '$appUser' usa PROFILE=KAWASHI_SERVICE_PROFILE (nao o de pessoa - ver item 14 de bugs-primeiro-teste.md)" }
    @{ Esperado = 'DEFAULT_TABLESPACE=TS_KAWASHI_DATA';  Descricao = "Tablespace padrao e TS_KAWASHI_DATA (nao a USERS generica da imagem)" }
    @{ Esperado = 'PASSWORD_EXPIRADA=NAO';               Descricao = "Senha NAO esta expirada (PASSWORD EXPIRE removido de proposito - um pool JDBC nao responde ao prompt de troca, ver item 4 de bugs-primeiro-teste.md)" }
    @{ Esperado = 'QUOTA_DATA=UNLIMITED';                Descricao = "Quota ilimitada em TS_KAWASHI_DATA (o espaco dedicado e seguro da aplicacao)" }
    @{ Esperado = 'TEM_UNLIMITED_TABLESPACE=NAO';        Descricao = "NAO tem o privilegio de sistema UNLIMITED TABLESPACE (revogado - so pode gravar no seu proprio tablespace dedicado)" }
    @{ Esperado = 'TEM_DB_DEVELOPER_ROLE=NAO';           Descricao = "NAO tem DB_DEVELOPER_ROLE (role generica da imagem, revogada por fugir do RBAC proprio)" }
    @{ Esperado = 'TEM_KAWASHI_READWRITE=SIM';           Descricao = "Tem a role KAWASHI_READWRITE (privilegios minimos pra criar/manter seus proprios objetos)" }
    @{ Esperado = 'SESSIONS_PER_USER=50';                Descricao = "KAWASHI_SERVICE_PROFILE permite 50 sessoes simultaneas (acomoda um pool de conexoes real, nao as 3 do profile de pessoa)" }
    @{ Esperado = 'IDLE_TIME=UNLIMITED';                 Descricao = "KAWASHI_SERVICE_PROFILE nao derruba conexao pooled por ociosidade (reciclagem e responsabilidade do proprio pool)" }
    @{ Esperado = 'CONNECT_TIME=UNLIMITED';              Descricao = "KAWASHI_SERVICE_PROFILE nao forca reconexao periodica (evita erros intermitentes num pool de producao)" }
    @{ Esperado = 'PASSWORD_LIFE_TIME=UNLIMITED';        Descricao = "KAWASHI_SERVICE_PROFILE nao expira a senha sozinho (ninguem responderia ao prompt interativo - mesmo racional do item 4)" }
)

$results = foreach ($caso in $casos) {
    $passou = $output -match [regex]::Escape($caso.Esperado)
    New-TestResult -Name $caso.Descricao -Passed $passou -Details $(if (-not $passou) { "esperava encontrar '$($caso.Esperado)' na saida:`n$output" })
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
