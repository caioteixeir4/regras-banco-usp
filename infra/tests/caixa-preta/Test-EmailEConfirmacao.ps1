# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: as regras do passo 17 (17_email_e_confirmacao.sql) valem no BANCO, mesmo
    para quem contorna a API.

.DESCRIPTION
    No ambiente TESTE_INFRA, com uma conta de API de verdade (execucao, por proxy no _APP) e com o DBA:
      - os 6 ambientes tem as colunas novas, os gatilhos do convite e o parametro CONFIRMACAO_MINUTOS;
      - o e-mail so fica confirmado quando um convite que chegou POR E-MAIL e usado; convite entregue
        pela equipe nao confirma; e a API nao marca o e-mail como confirmado sozinha;
      - como o convite foi entregue nao muda depois (ORA-20113);
      - a ultima confirmacao com a passkey (TOKEN.VERIFICADO_EM) anda so para a frente e nunca para o
        futuro, nem pelo DBA (ORA-20112);
      - o desafio de confirmacao existe e e preso a um usuario; a tentativa de confirmacao conta para o
        bloqueio do IP, com o grupo do IP.
#>
[CmdletBinding()]
param(
    [string]$EnvFile
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Continue'
if (-not $EnvFile) { $EnvFile = Join-Path $PSScriptRoot '..\..\.env' }

Write-Host "== [CAIXA-PRETA] E-mail confirmado pelo convite e confirmacao com passkey: as travas valem no banco ==" -ForegroundColor Cyan

$createApi    = Join-Path $PSScriptRoot '..\..\scripts\create-api-account.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken   = Get-VaultToken -EnvFile $EnvFile
$amb = 'KAWASHI_ENV_TESTE_INFRA'
$L = "${amb}_LOGIN"
$S = "${amb}_SESSAO"
$G = "${amb}_LOG"
$results = @()
$exec = $null
$marca = 'TST_EML_' + (Get-Random -Maximum 999999)

function Invoke-Sys {
    param([string]$Sql)
    return (Invoke-SqlPlus -ConnectString '/ as sysdba' -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSET LINESIZE 400`nALTER SESSION SET CONTAINER = FREEPDB1;`n$Sql`nEXIT;`n") -join "`n"
}
function Invoke-Como {
    param([string]$Conn, [string]$Sql)
    return (Invoke-SqlPlus -ConnectString $Conn -Sql "SET PAGESIZE 0`nSET FEEDBACK ON`nSET LINESIZE 400`n$Sql`nEXIT;`n") -join "`n"
}
function Get-Senha {
    param([string]$Conta)
    $c = '-field=db_password'
    return ((docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv get $c "kawashi-secrets/api/$Conta" 2>$null) -join '').Trim()
}
function Get-Id {
    param([string]$Select)
    return [long]((Invoke-Sys "SELECT 'I=' || ($Select) FROM dual;") -replace '(?s).*I=(-?\d+).*', '$1')
}
function Get-Hash {
    param([string]$Texto)
    return (-join ([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Texto)) | ForEach-Object { $_.ToString('x2') }))
}

try {
    $exec = New-ThrowawayUsername -Prefix 'TST_EMLE'
    & $createApi -Username $exec -Ambiente 'TESTE_INFRA' -EnvFile $EnvFile *> $null
    $api = "$exec[${amb}_APP]/$(Get-Senha $exec)@//localhost:1521/FREEPDB1"

    # --- a estrutura nos 6 ambientes ------------------------------------------------------------
    $colunas = Invoke-Sys "SELECT 'C=' || COUNT(*) FROM dba_tab_columns WHERE owner LIKE 'KAWASHI\_ENV\_%' ESCAPE '\' AND (table_name, column_name) IN (('USUARIO','EMAIL_CONFIRMADO_EM'),('CONVITE','ENVIADO_POR_EMAIL'),('TOKEN','VERIFICADO_EM'),('TENTATIVA_LOGIN','IP_GRUPO'));"
    $gatilhos = Invoke-Sys "SELECT 'G=' || COUNT(*) FROM dba_triggers WHERE owner LIKE 'KAWASHI\_ENV\_%' ESCAPE '\' AND status = 'ENABLED' AND trigger_name IN ('CONVITE_ENVIO_TRG','CONVITE_CONFIRMA_EMAIL_TRG');"
    $param = Invoke-Sys "SELECT 'P=' || ((SELECT COUNT(*) FROM KAWASHI_ENV_TESTE_DEV_LOGIN.PARAMETRO_SEGURANCA WHERE CHAVE = 'CONFIRMACAO_MINUTOS') + (SELECT COUNT(*) FROM KAWASHI_ENV_TESTE_INFRA_LOGIN.PARAMETRO_SEGURANCA WHERE CHAVE = 'CONFIRMACAO_MINUTOS') + (SELECT COUNT(*) FROM KAWASHI_ENV_DEV_LOGIN.PARAMETRO_SEGURANCA WHERE CHAVE = 'CONFIRMACAO_MINUTOS') + (SELECT COUNT(*) FROM KAWASHI_ENV_INFRA_LOGIN.PARAMETRO_SEGURANCA WHERE CHAVE = 'CONFIRMACAO_MINUTOS') + (SELECT COUNT(*) FROM KAWASHI_ENV_HOMOLOG_LOGIN.PARAMETRO_SEGURANCA WHERE CHAVE = 'CONFIRMACAO_MINUTOS') + (SELECT COUNT(*) FROM KAWASHI_ENV_PROD_LOGIN.PARAMETRO_SEGURANCA WHERE CHAVE = 'CONFIRMACAO_MINUTOS')) FROM dual;"
    $results += New-TestResult -Name "Os 6 ambientes tem as 4 colunas novas (24), os 2 gatilhos do convite ligados (12) e o parametro CONFIRMACAO_MINUTOS (6)" -Passed (($colunas -match 'C=24') -and ($gatilhos -match 'G=12') -and ($param -match 'P=6')) -Details "$colunas $gatilhos $param"

    # --- e-mail confirmado so pelo convite que chegou por e-mail -----------------------------------
    $preparo = Invoke-Como $api @"
INSERT INTO $L.USUARIO (PESSOA_ID, EMAIL_CIFRADO, EMAIL_INDICE, HANDLE) VALUES (-31, 'v1:' || RPAD('x', 60, 'x'), LOWER(RAWTOHEX(STANDARD_HASH('$marca-1', 'SHA256'))), SUBSTR(LOWER(RAWTOHEX(STANDARD_HASH('$marca-h1', 'SHA256'))), 1, 43));
INSERT INTO $L.USUARIO (PESSOA_ID, EMAIL_CIFRADO, EMAIL_INDICE, HANDLE) VALUES (-32, 'v1:' || RPAD('x', 60, 'x'), LOWER(RAWTOHEX(STANDARD_HASH('$marca-2', 'SHA256'))), SUBSTR(LOWER(RAWTOHEX(STANDARD_HASH('$marca-h2', 'SHA256'))), 1, 43));
COMMIT;
"@
    $u1 = Get-Id "SELECT ID FROM $L.USUARIO WHERE EMAIL_INDICE = LOWER(RAWTOHEX(STANDARD_HASH('$marca-1', 'SHA256')))"
    $u2 = Get-Id "SELECT ID FROM $L.USUARIO WHERE EMAIL_INDICE = LOWER(RAWTOHEX(STANDARD_HASH('$marca-2', 'SHA256')))"
    $porEmail = Get-Hash "$marca-c1"
    $pelaEquipe = Get-Hash "$marca-c2"
    $convites = Invoke-Como $api @"
INSERT INTO $L.CONVITE (USUARIO_ID, TOKEN_HASH, FINALIDADE, CRIADO_POR, EXPIRA_EM, ENVIADO_POR_EMAIL) VALUES ($u1, '$porEmail', 'CADASTRO', 'USUARIO:1', SYS_EXTRACT_UTC(SYSTIMESTAMP) + INTERVAL '1' HOUR, TRUE);
INSERT INTO $L.CONVITE (USUARIO_ID, TOKEN_HASH, FINALIDADE, CRIADO_POR, EXPIRA_EM) VALUES ($u2, '$pelaEquipe', 'CADASTRO', 'SCRIPT', SYS_EXTRACT_UTC(SYSTIMESTAMP) + INTERVAL '1' HOUR);
COMMIT;
"@
    $direto = Invoke-Como $api "UPDATE $L.USUARIO SET EMAIL_CONFIRMADO_EM = SYS_EXTRACT_UTC(SYSTIMESTAMP) WHERE ID = $u2;"
    $usa = Invoke-Como $api "UPDATE $L.CONVITE SET USADO_EM = SYS_EXTRACT_UTC(SYSTIMESTAMP) WHERE TOKEN_HASH IN ('$porEmail', '$pelaEquipe');`nCOMMIT;"
    $confirmados = Invoke-Sys "SELECT 'E=' || LISTAGG(ID || ':' || CASE WHEN EMAIL_CONFIRMADO_EM IS NULL THEN 'nao' ELSE 'sim' END, ',') WITHIN GROUP (ORDER BY ID) FROM $L.USUARIO WHERE ID IN ($u1, $u2);"
    $results += New-TestResult -Name "Usar o convite que chegou POR E-MAIL confirma o e-mail (gatilho); o entregue pela equipe nao; e a API nao marca o e-mail como confirmado sozinha (ORA-01031/41900)" -Passed (($preparo -notmatch 'ORA-') -and ($convites -notmatch 'ORA-') -and ($usa -notmatch 'ORA-') -and ($direto -match 'ORA-(01031|41900)') -and ($confirmados -match "E=${u1}:sim,${u2}:nao")) -Details "$convites`n$direto`n$usa`n$confirmados"

    $troca = Invoke-Como $api "UPDATE $L.CONVITE SET ENVIADO_POR_EMAIL = TRUE WHERE TOKEN_HASH = '$pelaEquipe';"
    $trocaDba = Invoke-Como $engineerConn "ALTER SESSION SET CONTAINER = FREEPDB1;`nUPDATE $L.CONVITE SET ENVIADO_POR_EMAIL = FALSE WHERE TOKEN_HASH = '$porEmail';"
    $results += New-TestResult -Name "Como o convite foi entregue nao muda depois, nem pelo DBA (ORA-20113)" -Passed (($troca -match 'ORA-20113') -and ($trocaDba -match 'ORA-20113')) -Details "$troca`n$trocaDba"

    # --- a ultima confirmacao com a passkey ---------------------------------------------------------
    $hashToken = Get-Hash "$marca-t"
    $cria = Invoke-Como $api "INSERT INTO $S.TOKEN (USUARIO_ID, TOKEN_HASH, EXPIRA_EM, EXPIRA_ABSOLUTO_EM, VERIFICADO_EM) VALUES ($u1, '$hashToken', SYS_EXTRACT_UTC(SYSTIMESTAMP) + INTERVAL '15' MINUTE, SYS_EXTRACT_UTC(SYSTIMESTAMP) + INTERVAL '8' HOUR, SYS_EXTRACT_UTC(SYSTIMESTAMP) - INTERVAL '10' MINUTE);`nCOMMIT;"
    $avanca = Invoke-Como $api "UPDATE $S.TOKEN SET VERIFICADO_EM = SYS_EXTRACT_UTC(SYSTIMESTAMP) WHERE TOKEN_HASH = '$hashToken';`nCOMMIT;"
    $futuro = Invoke-Como $api "UPDATE $S.TOKEN SET VERIFICADO_EM = SYS_EXTRACT_UTC(SYSTIMESTAMP) + INTERVAL '1' HOUR WHERE TOKEN_HASH = '$hashToken';"
    $volta = Invoke-Como $api "UPDATE $S.TOKEN SET VERIFICADO_EM = SYS_EXTRACT_UTC(SYSTIMESTAMP) - INTERVAL '1' DAY WHERE TOKEN_HASH = '$hashToken';"
    $apaga = Invoke-Como $engineerConn "ALTER SESSION SET CONTAINER = FREEPDB1;`nUPDATE $S.TOKEN SET VERIFICADO_EM = NULL WHERE TOKEN_HASH = '$hashToken';"
    $results += New-TestResult -Name "A ultima confirmacao com a passkey (TOKEN.VERIFICADO_EM) anda para a frente; ir para o futuro, voltar ou ser apagada e recusado, ate para o DBA (ORA-20112)" -Passed (($cria -notmatch 'ORA-') -and ($avanca -notmatch 'ORA-') -and ($futuro -match 'ORA-20112') -and ($volta -match 'ORA-20112') -and ($apaga -match 'ORA-20112')) -Details "$cria`n$avanca`n$futuro`n$volta`n$apaga"

    # --- desafio e tentativa da confirmacao -----------------------------------------------------------
    $desafioSem = Invoke-Como $api "INSERT INTO $S.DESAFIO (VALOR, FINALIDADE, EXPIRA_EM) VALUES (RPAD('a', 43, 'b'), 'CONFIRMACAO', SYS_EXTRACT_UTC(SYSTIMESTAMP) + INTERVAL '5' MINUTE);"
    $tentativa = Invoke-Como $api "INSERT INTO $G.TENTATIVA_LOGIN (METODO, USUARIO_ID, IP_ORIGEM, IP_GRUPO, SUCESSO, MOTIVO) VALUES ('CONFIRMACAO', $u1, '2001:db8:9:9::5', '2001:db8:9:9::/64', FALSE, 'VERIFICACAO_FALHOU');`nROLLBACK;"
    $results += New-TestResult -Name "O desafio de confirmacao precisa de um usuario (CK_DESAFIO_CADASTRO); a confirmacao que falha entra na TENTATIVA_LOGIN, com o grupo do IP" -Passed (($desafioSem -match 'ORA-02290') -and ($tentativa -notmatch 'ORA-')) -Details "$desafioSem`n$tentativa"
}
finally {
    Write-Host "-> Limpando: tokens, convites, usuarios e conta de teste..."
    Invoke-Sys @"
DELETE FROM $S.TOKEN WHERE USUARIO_ID IN (SELECT ID FROM $L.USUARIO WHERE EMAIL_INDICE IN (LOWER(RAWTOHEX(STANDARD_HASH('$marca-1', 'SHA256'))), LOWER(RAWTOHEX(STANDARD_HASH('$marca-2', 'SHA256')))));
DELETE FROM $L.CONVITE WHERE USUARIO_ID IN (SELECT ID FROM $L.USUARIO WHERE EMAIL_INDICE IN (LOWER(RAWTOHEX(STANDARD_HASH('$marca-1', 'SHA256'))), LOWER(RAWTOHEX(STANDARD_HASH('$marca-2', 'SHA256')))));
DELETE FROM $L.USUARIO WHERE EMAIL_INDICE IN (LOWER(RAWTOHEX(STANDARD_HASH('$marca-1', 'SHA256'))), LOWER(RAWTOHEX(STANDARD_HASH('$marca-2', 'SHA256'))));
COMMIT;
"@ | Out-Null
    if ($exec) {
        Invoke-Como $engineerConn "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $exec CASCADE;" | Out-Null
        Invoke-Sys "DELETE FROM SYS.KAWASHI_CONTA WHERE USERNAME = '$exec';`nCOMMIT;" | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv metadata delete "kawashi-secrets/api/$exec" 2>&1 | Out-Null
    }
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
