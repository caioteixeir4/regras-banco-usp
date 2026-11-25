# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: os termos (LGPD, 15_aceite_de_termos.sql) e o endurecimento da revisao
    (16_endurecimento.sql) valem no BANCO, mesmo para quem contorna a API.

.DESCRIPTION
    No ambiente TESTE_INFRA, com uma conta de API de verdade (execucao, por proxy no _APP) e com o
    DBA:
      - os 6 ambientes tem TERMO e ACEITE_TERMO, com os gatilhos ligados;
      - a API nao publica termo, nao altera nem apaga aceite;
      - publicar-termo.ps1 publica versao nova: o banco calcula o SHA-256 (igual ao do arquivo) e
        grava quem publicou; a versao nova passa a ser a vigente;
      - termo publicado nao muda nem sai, nem pelo DBA (ORA-20111);
      - o aceite tem a hora do banco (a informada e ignorada), e unico por versao e vai para o
        LOG_SEGURANCA (TERMO_ACEITO);
      - token revogado nao volta, o teto nao aumenta e dono/empresa nao mudam (ORA-20112);
      - da conta (USUARIO) a API so muda ATIVO; perfil, nada.
#>
[CmdletBinding()]
param(
    [string]$EnvFile
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Continue'
if (-not $EnvFile) { $EnvFile = Join-Path $PSScriptRoot '..\..\.env' }

Write-Host "== [CAIXA-PRETA] Termos (LGPD) e endurecimento: as travas valem no banco ==" -ForegroundColor Cyan

$createApi  = Join-Path $PSScriptRoot '..\..\scripts\create-api-account.ps1'
$publicar   = Join-Path $PSScriptRoot '..\..\scripts\publicar-termo.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken = Get-VaultToken -EnvFile $EnvFile
$engenheiro = (Get-EngineerCredentials -EnvFile $EnvFile).User.ToUpper()
$amb = 'KAWASHI_ENV_TESTE_INFRA'
$L = "${amb}_LOGIN"
$S = "${amb}_SESSAO"
$results = @()
$exec = $null
$marca = 'TST_TRM_' + (Get-Random -Maximum 999999)
$versao = 'T' + (Get-Random -Maximum 99999999)
$arquivo = Join-Path ([System.IO.Path]::GetTempPath()) "$marca.txt"

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

try {
    $exec = New-ThrowawayUsername -Prefix 'TST_TRME'
    & $createApi -Username $exec -Ambiente 'TESTE_INFRA' -EnvFile $EnvFile *> $null
    $api = "$exec[${amb}_APP]/$(Get-Senha $exec)@//localhost:1521/FREEPDB1"

    # --- as tabelas -------------------------------------------------------------------------
    $tabelas = Invoke-Sys "SELECT 'T=' || COUNT(*) FROM dba_tables WHERE owner LIKE 'KAWASHI\_ENV\_%\_LOGIN' ESCAPE '\' AND table_name IN ('TERMO','ACEITE_TERMO');"
    $gatilhos = Invoke-Sys "SELECT 'G=' || COUNT(*) FROM dba_triggers WHERE owner LIKE 'KAWASHI\_ENV\_%' ESCAPE '\' AND status = 'ENABLED' AND trigger_name IN ('TERMO_TRG','ACEITE_TERMO_TRG','TOKEN_IMUTAVEL_TRG');"
    $results += New-TestResult -Name "Os 6 ambientes tem TERMO e ACEITE_TERMO (12) e os gatilhos do termo, do aceite e do token ligados (18)" -Passed (($tabelas -match 'T=12') -and ($gatilhos -match 'G=18')) -Details "$tabelas $gatilhos"

    # --- a API nao publica ------------------------------------------------------------------
    $publicaApi = Invoke-Como $api "INSERT INTO $L.TERMO (DOCUMENTO, VERSAO, TEXTO, HASH_TEXTO, PUBLICADO_POR) VALUES ('TERMOS_DE_USO', '$versao', 'forjado', RPAD('0', 64, '0'), 'API');"
    $results += New-TestResult -Name "A API nao publica termo (so le): INSERT no TERMO recusado (ORA-01031/41900)" -Passed ($publicaApi -match 'ORA-(01031|41900)') -Details $publicaApi

    # --- publicar versao nova pelo script ------------------------------------------------------
    $texto = "Termos de uso de teste $marca. Texto com acentos: aceitação, política, ção, não. " + ('Linha de enchimento. ' * 200)
    [System.IO.File]::WriteAllText($arquivo, $texto, [System.Text.UTF8Encoding]::new($false))
    $hashArquivo = -join ([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.UTF8Encoding]::new($false).GetBytes($texto.Trim())) | ForEach-Object { $_.ToString('x2') })
    $saidaPub = (& powershell -NoProfile -ExecutionPolicy Bypass -File $publicar -Ambiente TESTE_INFRA -Documento TERMOS_DE_USO -Versao $versao -Arquivo $arquivo -EnvFile $EnvFile 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $gravado = Invoke-Sys "SELECT 'P=' || HASH_TEXTO || '|' || PUBLICADO_POR || '|' || DBMS_LOB.GETLENGTH(TEXTO) FROM $L.TERMO WHERE VERSAO = '$versao';"
    $vigente = Invoke-Sys "SELECT 'V=' || VERSAO FROM $L.TERMO WHERE DOCUMENTO = 'TERMOS_DE_USO' AND ID = (SELECT MAX(ID) FROM $L.TERMO WHERE DOCUMENTO = 'TERMOS_DE_USO');"
    $results += New-TestResult -Name "publicar-termo.ps1 publica versao nova (texto de $($texto.Trim().Length) caracteres, com acentos): o banco calcula o SHA-256 igual ao do arquivo, grava quem publicou (o engenheiro) e a versao nova vira a vigente" -Passed (($saidaPub -match 'Publicado:') -and ($gravado -match "P=$hashArquivo\|$engenheiro\|$($texto.Trim().Length)") -and ($vigente -match "V=$versao")) -Details "$saidaPub`n$gravado`n$vigente"
    $termo = Get-Id "SELECT ID FROM $L.TERMO WHERE VERSAO = '$versao'"

    $repete = (& powershell -NoProfile -ExecutionPolicy Bypass -File $publicar -Ambiente TESTE_INFRA -Documento TERMOS_DE_USO -Versao $versao -Arquivo $arquivo -EnvFile $EnvFile 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $mudaDba = Invoke-Como $engineerConn "ALTER SESSION SET CONTAINER = FREEPDB1;`nUPDATE $L.TERMO SET TEXTO = 'outro texto' WHERE ID = $termo;"
    $apagaDba = Invoke-Como $engineerConn "ALTER SESSION SET CONTAINER = FREEPDB1;`nDELETE FROM $L.TERMO WHERE ID = $termo;"
    $results += New-TestResult -Name "Termo publicado nao muda nem sai, nem pelo DBA (ORA-20111); a mesma versao nao se publica duas vezes" -Passed (($mudaDba -match 'ORA-20111') -and ($apagaDba -match 'ORA-20111') -and ($repete -match 'Ja existe a versao')) -Details "$mudaDba`n$apagaDba`n$repete"

    # --- o aceite ---------------------------------------------------------------------------------
    $preparo = Invoke-Como $api @"
INSERT INTO $L.USUARIO (PESSOA_ID, EMAIL_CIFRADO, EMAIL_INDICE, HANDLE) VALUES (-21, 'v1:' || RPAD('x', 60, 'x'), LOWER(RAWTOHEX(STANDARD_HASH('$marca', 'SHA256'))), SUBSTR(LOWER(RAWTOHEX(STANDARD_HASH('$marca-h', 'SHA256'))), 1, 43));
COMMIT;
"@
    $u = Get-Id "SELECT ID FROM $L.USUARIO WHERE EMAIL_INDICE = LOWER(RAWTOHEX(STANDARD_HASH('$marca', 'SHA256')))"
    $aceite = Invoke-Como $api "INSERT INTO $L.ACEITE_TERMO (USUARIO_ID, TERMO_ID, IP_ORIGEM, ACEITO_EM) VALUES ($u, $termo, '203.0.113.5', TIMESTAMP '2000-01-01 00:00:00');`nCOMMIT;"
    $dupla = Invoke-Como $api "INSERT INTO $L.ACEITE_TERMO (USUARIO_ID, TERMO_ID, IP_ORIGEM) VALUES ($u, $termo, '203.0.113.5');"
    $hora = Invoke-Sys "SELECT 'A=' || CASE WHEN ACEITO_EM > SYS_EXTRACT_UTC(SYSTIMESTAMP) - INTERVAL '5' MINUTE THEN 'agora' ELSE TO_CHAR(ACEITO_EM) END || '|' || IP_ORIGEM FROM $L.ACEITE_TERMO WHERE USUARIO_ID = $u;"
    $log = Invoke-Sys "SELECT 'S=' || EVENTO || '|' || DETALHE || '|' || FEITO_POR || '|' || IP_ORIGEM FROM ${amb}_LOG.LOG_SEGURANCA WHERE USUARIO_ID = $u AND EVENTO = 'TERMO_ACEITO';"
    $results += New-TestResult -Name "O aceite fica com a hora do banco (a data informada, de 2000, e ignorada), e unico por versao (ORA-00001) e vai sozinho para o LOG_SEGURANCA com a versao, quem e o IP" -Passed (($preparo -notmatch 'ORA-') -and ($aceite -notmatch 'ORA-') -and ($dupla -match 'ORA-00001') -and ($hora -match 'A=agora\|203\.0\.113\.5') -and ($log -match "S=TERMO_ACEITO\|TERMOS_DE_USO versao $versao\|USUARIO:$u\|203\.0\.113\.5")) -Details "$aceite`n$dupla`n$hora`n$log"

    $mexeAceite = @(
        (Invoke-Como $api "UPDATE $L.ACEITE_TERMO SET TERMO_ID = $termo WHERE USUARIO_ID = $u;"),
        (Invoke-Como $api "DELETE FROM $L.ACEITE_TERMO WHERE USUARIO_ID = $u;"))
    $results += New-TestResult -Name "A API nao altera nem apaga aceite (ORA-01031/41900): o registro do que foi aceito nao some" -Passed (@($mexeAceite | Where-Object { $_ -notmatch 'ORA-(01031|41900)' }).Count -eq 0) -Details ($mexeAceite -join "`n")

    # --- conta e perfil -----------------------------------------------------------------------
    $handle = Invoke-Como $api "UPDATE $L.USUARIO SET HANDLE = 'trocado' WHERE ID = $u;"
    $email = Invoke-Como $api "UPDATE $L.USUARIO SET EMAIL_INDICE = 'trocado' WHERE ID = $u;"
    $ativo = Invoke-Como $api "UPDATE $L.USUARIO SET ATIVO = FALSE WHERE ID = $u;`nUPDATE $L.USUARIO SET ATIVO = TRUE WHERE ID = $u;`nCOMMIT;"
    $results += New-TestResult -Name "Da conta, a API so liga e desliga (ATIVO); trocar HANDLE ou e-mail e recusado (ORA-01031/41900)" -Passed (($handle -match 'ORA-(01031|41900)') -and ($email -match 'ORA-(01031|41900)') -and ($ativo -notmatch 'ORA-')) -Details "$handle`n$email`n$ativo"

    # --- o token -------------------------------------------------------------------------------
    $hashToken = (-join ([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($marca)) | ForEach-Object { $_.ToString('x2') }))
    $cria = Invoke-Como $api "INSERT INTO $S.TOKEN (USUARIO_ID, TOKEN_HASH, EXPIRA_EM, EXPIRA_ABSOLUTO_EM, EMPRESA_ID) VALUES ($u, '$hashToken', SYS_EXTRACT_UTC(SYSTIMESTAMP) + INTERVAL '15' MINUTE, SYS_EXTRACT_UTC(SYSTIMESTAMP) + INTERVAL '8' HOUR, 1);`nCOMMIT;"
    $renova = Invoke-Como $api "UPDATE $S.TOKEN SET EXPIRA_EM = SYS_EXTRACT_UTC(SYSTIMESTAMP) + INTERVAL '20' MINUTE WHERE TOKEN_HASH = '$hashToken';`nCOMMIT;"
    $teto = Invoke-Como $api "UPDATE $S.TOKEN SET EXPIRA_ABSOLUTO_EM = EXPIRA_ABSOLUTO_EM + INTERVAL '30' DAY WHERE TOKEN_HASH = '$hashToken';"
    $empresa = Invoke-Como $api "UPDATE $S.TOKEN SET EMPRESA_ID = 2 WHERE TOKEN_HASH = '$hashToken';"
    $revoga = Invoke-Como $api "UPDATE $S.TOKEN SET REVOGADO_EM = SYS_EXTRACT_UTC(SYSTIMESTAMP), MOTIVO_REVOGACAO = 'LOGOUT' WHERE TOKEN_HASH = '$hashToken';`nCOMMIT;"
    $volta = Invoke-Como $api "UPDATE $S.TOKEN SET REVOGADO_EM = NULL, MOTIVO_REVOGACAO = NULL WHERE TOKEN_HASH = '$hashToken';"
    $voltaDba = Invoke-Como $engineerConn "ALTER SESSION SET CONTAINER = FREEPDB1;`nUPDATE $S.TOKEN SET REVOGADO_EM = NULL, MOTIVO_REVOGACAO = NULL WHERE TOKEN_HASH = '$hashToken';"
    $results += New-TestResult -Name "Token: renovar dentro do teto passa; aumentar o teto, trocar a empresa e desrevogar sao recusados pelo banco, ate para o DBA (ORA-20112)" -Passed (($cria -notmatch 'ORA-') -and ($renova -notmatch 'ORA-') -and ($teto -match 'ORA-20112') -and ($empresa -match 'ORA-20112') -and ($revoga -notmatch 'ORA-') -and ($volta -match 'ORA-20112') -and ($voltaDba -match 'ORA-20112')) -Details "$cria`n$renova`n$teto`n$empresa`n$revoga`n$volta`n$voltaDba"
}
finally {
    Write-Host "-> Limpando: termo, aceite, token e conta de teste (os logs ficam, de proposito)..."
    # O termo nao sai nem pelo DBA: a limpeza desliga o gatilho so pelo tempo de apagar a versao de teste.
    Invoke-Sys @"
DELETE FROM $S.TOKEN WHERE USUARIO_ID IN (SELECT ID FROM $L.USUARIO WHERE EMAIL_INDICE = LOWER(RAWTOHEX(STANDARD_HASH('$marca', 'SHA256'))));
DELETE FROM $L.ACEITE_TERMO WHERE TERMO_ID IN (SELECT ID FROM $L.TERMO WHERE VERSAO = '$versao');
ALTER TRIGGER $L.TERMO_TRG DISABLE;
DELETE FROM $L.TERMO WHERE VERSAO = '$versao';
COMMIT;
ALTER TRIGGER $L.TERMO_TRG ENABLE;
DELETE FROM $L.USUARIO WHERE EMAIL_INDICE = LOWER(RAWTOHEX(STANDARD_HASH('$marca', 'SHA256')));
COMMIT;
"@ | Out-Null
    Remove-Item -LiteralPath $arquivo -ErrorAction SilentlyContinue
    if ($exec) {
        Invoke-Como $engineerConn "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $exec CASCADE;" | Out-Null
        Invoke-Sys "DELETE FROM SYS.KAWASHI_CONTA WHERE USERNAME = '$exec';`nCOMMIT;" | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv metadata delete "kawashi-secrets/api/$exec" 2>&1 | Out-Null
    }
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
