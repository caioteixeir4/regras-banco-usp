# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: o convite de vinculo (18_convite_de_vinculo.sql) guarda quem convidou,
    quando e de onde sem que ninguem consiga mudar depois, e so o convidado aceita.

.DESCRIPTION
    No ambiente TESTE_INFRA, com uma conta de API de verdade (execucao, por proxy no _APP) e com o DBA:
      - os 6 ambientes tem CONVITE_VINCULO, a coluna USUARIO_EMPRESA.CONVITE_VINCULO_ID e os 2 gatilhos;
      - a API tem de dizer quem convidou (USUARIO:<id> igual ao id informado); a hora e do banco;
      - quem convidou, IP, hora, empresa e cargo nao mudam: a API nem tem permissao, e o DBA e barrado
        pelo gatilho (ORA-20114); ninguem apaga convite;
      - aceitar so o proprio convidado; a resposta e uma so;
      - cada convite e cada resposta vao sozinhos para o LOG_PERMISSAO e para o LOG_SEGURANCA (com o IP).
#>
[CmdletBinding()]
param(
    [string]$EnvFile
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Continue'
if (-not $EnvFile) { $EnvFile = Join-Path $PSScriptRoot '..\..\.env' }

Write-Host "== [CAIXA-PRETA] Convite de vinculo: quem convidou fica registrado e nao muda ==" -ForegroundColor Cyan

$createApi    = Join-Path $PSScriptRoot '..\..\scripts\create-api-account.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken   = Get-VaultToken -EnvFile $EnvFile
$amb = 'KAWASHI_ENV_TESTE_INFRA'
$L = "${amb}_LOGIN"
$G = "${amb}_LOG"
$results = @()
$exec = $null
$marca = 'TST_CVV_' + (Get-Random -Maximum 999999)
$empresa = -1 * (Get-Random -Minimum 100000 -Maximum 999999)   # TESTE_INFRA nao tem EMPRESA: sem chave estrangeira, um id qualquer

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
    $exec = New-ThrowawayUsername -Prefix 'TST_CVVE'
    & $createApi -Username $exec -Ambiente 'TESTE_INFRA' -EnvFile $EnvFile *> $null
    $api = "$exec[${amb}_APP]/$(Get-Senha $exec)@//localhost:1521/FREEPDB1"

    # --- a estrutura nos 6 ambientes ------------------------------------------------------------
    $tabelas = Invoke-Sys "SELECT 'T=' || COUNT(*) FROM dba_tables WHERE owner LIKE 'KAWASHI\_ENV\_%\_LOGIN' ESCAPE '\' AND table_name = 'CONVITE_VINCULO';"
    $colunas = Invoke-Sys "SELECT 'C=' || COUNT(*) FROM dba_tab_columns WHERE owner LIKE 'KAWASHI\_ENV\_%\_LOGIN' ESCAPE '\' AND table_name = 'USUARIO_EMPRESA' AND column_name = 'CONVITE_VINCULO_ID';"
    $gatilhos = Invoke-Sys "SELECT 'G=' || COUNT(*) FROM dba_triggers WHERE owner LIKE 'KAWASHI\_ENV\_%' ESCAPE '\' AND status = 'ENABLED' AND trigger_name IN ('CONVITE_VINCULO_TRG','CONVITE_VINCULO_LOG_TRG');"
    $results += New-TestResult -Name "Os 6 ambientes tem CONVITE_VINCULO (6), a coluna USUARIO_EMPRESA.CONVITE_VINCULO_ID (6) e os 2 gatilhos ligados (12)" -Passed (($tabelas -match 'T=6') -and ($colunas -match 'C=6') -and ($gatilhos -match 'G=12')) -Details "$tabelas $colunas $gatilhos"

    # --- dados de teste, gravados como a API -----------------------------------------------------
    $preparo = Invoke-Como $api @"
INSERT INTO $L.USUARIO (PESSOA_ID, EMAIL_CIFRADO, EMAIL_INDICE, HANDLE) VALUES (-41, 'v1:' || RPAD('x', 60, 'x'), LOWER(RAWTOHEX(STANDARD_HASH('$marca-adm', 'SHA256'))), SUBSTR(LOWER(RAWTOHEX(STANDARD_HASH('$marca-h1', 'SHA256'))), 1, 43));
INSERT INTO $L.USUARIO (PESSOA_ID, EMAIL_CIFRADO, EMAIL_INDICE, HANDLE) VALUES (-42, 'v1:' || RPAD('x', 60, 'x'), LOWER(RAWTOHEX(STANDARD_HASH('$marca-cvd', 'SHA256'))), SUBSTR(LOWER(RAWTOHEX(STANDARD_HASH('$marca-h2', 'SHA256'))), 1, 43));
INSERT INTO $L.PERFIL (EMPRESA_ID, NOME, FIXO, ATUALIZADO_POR) VALUES ($empresa, 'ADMINISTRADOR', TRUE, 'USUARIO:1');
INSERT INTO $L.PERFIL (EMPRESA_ID, NOME, ATUALIZADO_POR) VALUES ($empresa, 'OPERADOR', 'USUARIO:1');
COMMIT;
"@
    $adm = Get-Id "SELECT ID FROM $L.USUARIO WHERE EMAIL_INDICE = LOWER(RAWTOHEX(STANDARD_HASH('$marca-adm', 'SHA256')))"
    $cvd = Get-Id "SELECT ID FROM $L.USUARIO WHERE EMAIL_INDICE = LOWER(RAWTOHEX(STANDARD_HASH('$marca-cvd', 'SHA256')))"
    $ope = Get-Id "SELECT ID FROM $L.PERFIL WHERE EMPRESA_ID = $empresa AND NOME = 'OPERADOR'"

    # --- quem convidou: a API tem de dizer, e a hora e do banco ------------------------------------
    $semAutor = Invoke-Como $api "INSERT INTO $L.CONVITE_VINCULO (USUARIO_ID, EMPRESA_ID, PERFIL_ID, CONVIDADO_POR, CONVIDADO_POR_USUARIO_ID, IP_ORIGEM, EXPIRA_EM) VALUES ($cvd, $empresa, $ope, 'USUARIO:999', $adm, '203.0.113.9', SYS_EXTRACT_UTC(SYSTIMESTAMP) + INTERVAL '7' DAY);"
    $cria = Invoke-Como $api "INSERT INTO $L.CONVITE_VINCULO (USUARIO_ID, EMPRESA_ID, PERFIL_ID, CONVIDADO_POR, CONVIDADO_POR_USUARIO_ID, IP_ORIGEM, CRIADO_EM, EXPIRA_EM) VALUES ($cvd, $empresa, $ope, 'USUARIO:$adm', $adm, '203.0.113.9', TIMESTAMP '2000-01-01 00:00:00', SYS_EXTRACT_UTC(SYSTIMESTAMP) + INTERVAL '7' DAY);`nCOMMIT;"
    $id = Get-Id "SELECT ID FROM $L.CONVITE_VINCULO WHERE USUARIO_ID = $cvd AND EMPRESA_ID = $empresa"
    $hora = Invoke-Sys "SELECT 'H=' || CASE WHEN CRIADO_EM > SYS_EXTRACT_UTC(SYSTIMESTAMP) - INTERVAL '5' MINUTE THEN 'agora' ELSE 'informada' END FROM $L.CONVITE_VINCULO WHERE ID = $id;"
    $results += New-TestResult -Name "A API tem de dizer quem convidou (USUARIO:<id> igual ao id; senao ORA-20114); a hora do convite e a do banco (a informada, de 2000, e ignorada)" -Passed (($preparo -notmatch 'ORA-') -and ($semAutor -match 'ORA-20114') -and ($cria -notmatch 'ORA-') -and ($hora -match 'H=agora')) -Details "$semAutor`n$cria`n$hora"

    # --- quem convidou, IP e hora nao mudam ------------------------------------------------------
    $apiMuda = @(
        (Invoke-Como $api "UPDATE $L.CONVITE_VINCULO SET CONVIDADO_POR = 'USUARIO:1' WHERE ID = $id;"),
        (Invoke-Como $api "UPDATE $L.CONVITE_VINCULO SET IP_ORIGEM = '10.0.0.1' WHERE ID = $id;"),
        (Invoke-Como $api "DELETE FROM $L.CONVITE_VINCULO WHERE ID = $id;"))
    $dbaMuda = @(
        (Invoke-Como $engineerConn "ALTER SESSION SET CONTAINER = FREEPDB1;`nUPDATE $L.CONVITE_VINCULO SET CONVIDADO_POR = 'OUTRO' WHERE ID = $id;"),
        (Invoke-Como $engineerConn "ALTER SESSION SET CONTAINER = FREEPDB1;`nUPDATE $L.CONVITE_VINCULO SET CRIADO_EM = CRIADO_EM - 1 WHERE ID = $id;"),
        (Invoke-Como $engineerConn "ALTER SESSION SET CONTAINER = FREEPDB1;`nDELETE FROM $L.CONVITE_VINCULO WHERE ID = $id;"))
    $results += New-TestResult -Name "Quem convidou, IP e hora nao mudam e o convite nao se apaga: a API nem tem permissao (ORA-01031/41900) e o DBA e barrado pelo gatilho (ORA-20114)" -Passed ((@($apiMuda | Where-Object { $_ -notmatch 'ORA-(01031|41900)' }).Count -eq 0) -and (@($dbaMuda | Where-Object { $_ -notmatch 'ORA-20114' }).Count -eq 0)) -Details (($apiMuda + $dbaMuda) -join "`n")

    # --- so o convidado aceita; a resposta e uma so ------------------------------------------------
    $outro = Invoke-Como $api "UPDATE $L.CONVITE_VINCULO SET SITUACAO = 'ACEITO', RESPONDIDO_POR = 'USUARIO:$adm', IP_RESPOSTA = '203.0.113.10' WHERE ID = $id;"
    $aceita = Invoke-Como $api "UPDATE $L.CONVITE_VINCULO SET SITUACAO = 'ACEITO', RESPONDIDO_POR = 'USUARIO:$cvd', IP_RESPOSTA = '203.0.113.10' WHERE ID = $id;`nCOMMIT;"
    $deNovo = Invoke-Como $api "UPDATE $L.CONVITE_VINCULO SET SITUACAO = 'RECUSADO', RESPONDIDO_POR = 'USUARIO:$cvd' WHERE ID = $id;"
    $results += New-TestResult -Name "Aceitar, so o proprio convidado (outro e recusado, ORA-20114); depois de respondido, a resposta nao muda (ORA-20114)" -Passed (($outro -match 'ORA-20114') -and ($aceita -notmatch 'ORA-') -and ($deNovo -match 'ORA-20114')) -Details "$outro`n$aceita`n$deNovo"

    # --- os logs ----------------------------------------------------------------------------------
    $perm = Invoke-Sys "SELECT 'P=' || LISTAGG(EVENTO || ':' || FEITO_POR, ',') WITHIN GROUP (ORDER BY ORDEM) FROM $G.LOG_PERMISSAO WHERE EMPRESA_ID = $empresa AND USUARIO_ID = $cvd;"
    $seg = Invoke-Sys "SELECT 'S=' || LISTAGG(EVENTO || ':' || FEITO_POR || ':' || IP_ORIGEM, ',') WITHIN GROUP (ORDER BY ORDEM) FROM $G.LOG_SEGURANCA WHERE USUARIO_ID = $cvd AND EVENTO LIKE 'VINCULO_CONVI%';"
    $results += New-TestResult -Name "Convite e resposta vao SOZINHOS para o LOG_PERMISSAO (com quem fez) e o LOG_SEGURANCA (com o IP de cada um)" -Passed (($perm -match "P=VINCULO_CONVIDADO:USUARIO:${adm},CONVITE_ACEITO:USUARIO:$cvd") -and ($seg -match "S=VINCULO_CONVIDADO:USUARIO:${adm}:203\.0\.113\.9,VINCULO_CONVITE_RESPONDIDO:USUARIO:${cvd}:203\.0\.113\.10")) -Details "$perm`n$seg"
}
finally {
    Write-Host "-> Limpando: convites, perfis, usuarios e conta de teste (os logs ficam, de proposito)..."
    # O convite nao sai nem pelo DBA: a limpeza desliga o gatilho so pelo tempo de apagar as linhas de teste.
    Invoke-Sys @"
ALTER TRIGGER $L.CONVITE_VINCULO_TRG DISABLE;
DELETE FROM $L.CONVITE_VINCULO WHERE EMPRESA_ID = $empresa;
COMMIT;
ALTER TRIGGER $L.CONVITE_VINCULO_TRG ENABLE;
DELETE FROM $L.PERFIL WHERE EMPRESA_ID = $empresa;
DELETE FROM $L.USUARIO WHERE EMAIL_INDICE IN (LOWER(RAWTOHEX(STANDARD_HASH('$marca-adm', 'SHA256'))), LOWER(RAWTOHEX(STANDARD_HASH('$marca-cvd', 'SHA256'))));
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
