# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-BRANCA: confere, direto nos catalogos internos do Oracle,
    que os parametros declarados em infra/oracle-init/02_global_hardening.sql
    e 10_advanced_hardening.sql estao realmente em vigor - nao so escritos no
    script (um ALTER SYSTEM com SCOPE=SPFILE, por exemplo, so vale depois de
    reiniciar a instancia; isto confirma que o valor EM MEMORIA bate com o
    pretendido).

.DESCRIPTION
    E "caixa-branca" porque usa conhecimento da implementacao interna (nomes
    de profile, de parametro de sistema, de funcao) para inspecionar o estado
    por tras do comportamento - diferente de um teste de caixa-preta, que so
    observaria o efeito (ex: "a conta trava depois de N tentativas").
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')

Write-Host "== [CAIXA-BRANCA] Parametros internos de hardening ==" -ForegroundColor Cyan

$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile

$sql = @'
SET PAGESIZE 0
SET FEEDBACK OFF
SET VERIFY OFF
SET LINESIZE 200
SELECT 'FAILED_LOGIN_ATTEMPTS=' || limit FROM dba_profiles WHERE profile = 'KAWASHI_SECURE_PROFILE' AND resource_name = 'FAILED_LOGIN_ATTEMPTS';
SELECT 'PASSWORD_VERIFY_FUNCTION=' || limit FROM dba_profiles WHERE profile = 'KAWASHI_SECURE_PROFILE' AND resource_name = 'PASSWORD_VERIFY_FUNCTION';
SELECT 'SESSIONS_PER_USER=' || limit FROM dba_profiles WHERE profile = 'KAWASHI_SECURE_PROFILE' AND resource_name = 'SESSIONS_PER_USER';
SELECT 'RESOURCE_LIMIT=' || upper(value) FROM v$parameter WHERE name = 'resource_limit';
SELECT 'SEC_MAX_FAILED_LOGIN_ATTEMPTS=' || value FROM v$parameter WHERE name = 'sec_max_failed_login_attempts';
SELECT 'DEFAULT_FAILED_LOGIN_ATTEMPTS=' || limit FROM dba_profiles WHERE profile = 'DEFAULT' AND resource_name = 'FAILED_LOGIN_ATTEMPTS';
EXIT;
'@

$output = (Invoke-SqlPlus -ConnectString $engineerConn -Sql $sql) -join "`n"

$casos = @(
    @{ Esperado = 'FAILED_LOGIN_ATTEMPTS=5';           Descricao = "Profile KAWASHI_SECURE_PROFILE: FAILED_LOGIN_ATTEMPTS esta em 5 (02_global_hardening.sql)" }
    @{ Esperado = 'PASSWORD_VERIFY_FUNCTION=KAWASHI_PASSWORD_VERIFY'; Descricao = "Profile KAWASHI_SECURE_PROFILE esta amarrado a funcao KAWASHI_PASSWORD_VERIFY" }
    @{ Esperado = 'SESSIONS_PER_USER=3';                Descricao = "Profile KAWASHI_SECURE_PROFILE: SESSIONS_PER_USER esta em 3" }
    @{ Esperado = 'RESOURCE_LIMIT=TRUE';                Descricao = "Parametro de sistema RESOURCE_LIMIT=TRUE (sem isto, SESSIONS_PER_USER/IDLE_TIME/CONNECT_TIME seriam ignorados silenciosamente)" }
    @{ Esperado = 'SEC_MAX_FAILED_LOGIN_ATTEMPTS=3';    Descricao = "Parametro de rede SEC_MAX_FAILED_LOGIN_ATTEMPTS esta em 3 (10_advanced_hardening.sql)" }
    @{ Esperado = 'DEFAULT_FAILED_LOGIN_ATTEMPTS=5';    Descricao = "Profile DEFAULT tambem recebeu o minimo de hardening (rede de seguranca contra usuario criado sem PROFILE explicito)" }
)

$results = foreach ($caso in $casos) {
    $passou = $output -match [regex]::Escape($caso.Esperado)
    New-TestResult -Name $caso.Descricao -Passed $passou -Details $(if (-not $passou) { "esperava encontrar '$($caso.Esperado)' na saida:`n$output" })
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
