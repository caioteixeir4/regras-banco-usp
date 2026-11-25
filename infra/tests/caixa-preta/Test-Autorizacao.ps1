# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: as regras da autorizacao (14_autorizacao.sql) valem no BANCO, mesmo para
    quem contorna a API: entra com a conta de execucao da API, e com a do DBA, e tenta furar cada
    trava.

.DESCRIPTION
    No ambiente TESTE_INFRA, com uma conta de API de verdade (execucao, por proxy no _APP):
      - os 6 ambientes tem as tabelas da autorizacao;
      - a API nao apaga nada, nao se promove a administrador da plataforma, nao grava no
        LOG_PERMISSAO nem na lista de permissoes;
      - a API tem de dizer quem fez cada mudanca (USUARIO:<id> ou SCRIPT:<nome>);
      - permissao exclusiva do ADMINISTRADOR nao vai para outro perfil; o ADMINISTRADOR nao recebe
        nem perde permissao, nao muda de nome e nao e desativado;
      - o perfil do vinculo e da mesma empresa (chave composta);
      - a empresa nunca fica sem administrador ativo;
      - cada troca de cargo vai sozinha para o LOG_PERMISSAO, com de/para e quem; mudanca feita pelo
        DBA fica com o nome do DBA; o log e encadeado (adulteracao aparece na view de quebras);
      - conceder e revogar administrador da plataforma registra quem e vai para o LOG_SEGURANCA.
#>
[CmdletBinding()]
param(
    [string]$EnvFile
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Continue'
if (-not $EnvFile) { $EnvFile = Join-Path $PSScriptRoot '..\..\.env' }

Write-Host "== [CAIXA-PRETA] Autorizacao: as travas valem no banco ==" -ForegroundColor Cyan

$createApi    = Join-Path $PSScriptRoot '..\..\scripts\create-api-account.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken   = Get-VaultToken -EnvFile $EnvFile
$engenheiro   = (Get-EngineerCredentials -EnvFile $EnvFile).User.ToUpper()
$amb = 'KAWASHI_ENV_TESTE_INFRA'
$L = "${amb}_LOGIN"
$results = @()
$exec = $null
$marca = 'TST_AUT_' + (Get-Random -Maximum 999999)
$empresa = -1 * (Get-Random -Minimum 100000 -Maximum 999999)   # TESTE_INFRA nao tem EMPRESA: sem chave estrangeira, um id qualquer
$outra = $empresa - 1

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
    $exec = New-ThrowawayUsername -Prefix 'TST_AUTE'
    & $createApi -Username $exec -Ambiente 'TESTE_INFRA' -EnvFile $EnvFile *> $null
    $api = "$exec[${amb}_APP]/$(Get-Senha $exec)@//localhost:1521/FREEPDB1"

    # --- as tabelas ---------------------------------------------------------------------
    $tabelas = Invoke-Sys "SELECT 'T=' || COUNT(*) FROM dba_tables WHERE (owner LIKE 'KAWASHI\_ENV\_%\_LOGIN' ESCAPE '\' AND table_name IN ('ADMIN_PLATAFORMA','PERMISSAO','PERFIL','PERFIL_PERMISSAO','USUARIO_EMPRESA')) OR (owner LIKE 'KAWASHI\_ENV\_%\_LOG' ESCAPE '\' AND table_name = 'LOG_PERMISSAO');"
    $gatilhos = Invoke-Sys "SELECT 'G=' || COUNT(*) FROM dba_triggers WHERE owner LIKE 'KAWASHI\_ENV\_%' ESCAPE '\' AND status = 'ENABLED' AND trigger_name IN ('ADMIN_PLATAFORMA_LOG_TRG','PERFIL_TRG','PERFIL_PERMISSAO_TRG','USUARIO_EMPRESA_TRG','USUARIO_EMPRESA_ADMIN_TRG','LOG_PERMISSAO_CADEIA_TRG');"
    $results += New-TestResult -Name "Os 6 ambientes tem as 5 tabelas da autorizacao no _LOGIN e o LOG_PERMISSAO no _LOG (36), com os 6 gatilhos ligados em cada um (36)" -Passed (($tabelas -match 'T=36') -and ($gatilhos -match 'G=36')) -Details "$tabelas $gatilhos"

    # --- dados de teste, gravados como a API -----------------------------------------------
    $preparo = Invoke-Como $api @"
INSERT INTO $L.USUARIO (PESSOA_ID, EMAIL_CIFRADO, EMAIL_INDICE, HANDLE) VALUES (-11, 'v1:' || RPAD('x', 60, 'x'), LOWER(RAWTOHEX(STANDARD_HASH('$marca-1', 'SHA256'))), SUBSTR(LOWER(RAWTOHEX(STANDARD_HASH('$marca-h1', 'SHA256'))), 1, 43));
INSERT INTO $L.USUARIO (PESSOA_ID, EMAIL_CIFRADO, EMAIL_INDICE, HANDLE) VALUES (-12, 'v1:' || RPAD('x', 60, 'x'), LOWER(RAWTOHEX(STANDARD_HASH('$marca-2', 'SHA256'))), SUBSTR(LOWER(RAWTOHEX(STANDARD_HASH('$marca-h2', 'SHA256'))), 1, 43));
INSERT INTO $L.PERFIL (EMPRESA_ID, NOME, FIXO, ATUALIZADO_POR) VALUES ($empresa, 'ADMINISTRADOR', TRUE, 'USUARIO:1');
INSERT INTO $L.PERFIL (EMPRESA_ID, NOME, ATUALIZADO_POR) VALUES ($empresa, 'OPERADOR', 'USUARIO:1');
INSERT INTO $L.PERFIL (EMPRESA_ID, NOME, FIXO, ATUALIZADO_POR) VALUES ($outra, 'ADMINISTRADOR', TRUE, 'USUARIO:1');
COMMIT;
"@
    $u1 = Get-Id "SELECT ID FROM $L.USUARIO WHERE EMAIL_INDICE = LOWER(RAWTOHEX(STANDARD_HASH('$marca-1', 'SHA256')))"
    $u2 = Get-Id "SELECT ID FROM $L.USUARIO WHERE EMAIL_INDICE = LOWER(RAWTOHEX(STANDARD_HASH('$marca-2', 'SHA256')))"
    $adm = Get-Id "SELECT ID FROM $L.PERFIL WHERE EMPRESA_ID = $empresa AND NOME = 'ADMINISTRADOR'"
    $ope = Get-Id "SELECT ID FROM $L.PERFIL WHERE EMPRESA_ID = $empresa AND NOME = 'OPERADOR'"
    $admOutra = Get-Id "SELECT ID FROM $L.PERFIL WHERE EMPRESA_ID = $outra AND NOME = 'ADMINISTRADOR'"
    $vinculo = Invoke-Como $api "INSERT INTO $L.USUARIO_EMPRESA (USUARIO_ID, EMPRESA_ID, PERFIL_ID, ATUALIZADO_POR) VALUES ($u1, $empresa, $adm, 'USUARIO:1');`nCOMMIT;"
    $results += New-TestResult -Name "Preparo: a conta da API cria usuarios, perfis e o vinculo do administrador (com o autor informado)" -Passed (($preparo -notmatch 'ORA-') -and ($vinculo -notmatch 'ORA-') -and $u1 -gt 0 -and $adm -gt 0) -Details "$preparo`n$vinculo"

    # --- o que a API nao consegue ------------------------------------------------------------
    $semAutor = Invoke-Como $api "INSERT INTO $L.PERFIL (EMPRESA_ID, NOME, ATUALIZADO_POR) VALUES ($empresa, 'SEM_AUTOR', 'eu mesmo');"
    $results += New-TestResult -Name "A API tem de dizer quem fez: autor fora do formato USUARIO:<id> / SCRIPT:<nome> e recusado (ORA-20104)" -Passed ($semAutor -match 'ORA-20104') -Details $semAutor

    $apaga = @(
        (Invoke-Como $api "DELETE FROM $L.USUARIO_EMPRESA WHERE USUARIO_ID = $u1;"),
        (Invoke-Como $api "DELETE FROM $L.PERFIL WHERE ID = $ope;"),
        (Invoke-Como $api "DELETE FROM $L.PERFIL_PERMISSAO;"),
        (Invoke-Como $api "INSERT INTO $L.ADMIN_PLATAFORMA (USUARIO_ID, CONCEDIDO_POR, MOTIVO) VALUES ($u1, 'API', 'me promovendo');"),
        (Invoke-Como $api "INSERT INTO $L.PERMISSAO (CODIGO, DESCRICAO) VALUES ('TUDO', 'tudo');"),
        (Invoke-Como $api "INSERT INTO ${amb}_LOG.LOG_PERMISSAO (ORDEM, EVENTO, EMPRESA_ID, FEITO_POR, HASH) VALUES (0, 'PERFIL_TROCADO', $empresa, 'forjado', '-');"))
    $todasRecusadas = @($apaga | Where-Object { $_ -notmatch 'ORA-(01031|41900|00942)' }).Count -eq 0
    $results += New-TestResult -Name "A API nao apaga vinculo, perfil nem permissao; nao se promove a administrador da plataforma; nao cria permissao; nao grava no LOG_PERMISSAO (ORA-01031/41900)" -Passed $todasRecusadas -Details ($apaga -join "`n")

    # --- permissoes exclusivas e o ADMINISTRADOR fixo ------------------------------------------
    $exclusiva = Invoke-Como $api "INSERT INTO $L.PERFIL_PERMISSAO (PERFIL_ID, PERMISSAO_ID, ATUALIZADO_POR) SELECT $ope, ID, 'USUARIO:1' FROM $L.PERMISSAO WHERE CODIGO = 'PERFIL_GERENCIAR';"
    $noFixo = Invoke-Como $api "INSERT INTO $L.PERFIL_PERMISSAO (PERFIL_ID, PERMISSAO_ID, ATUALIZADO_POR) SELECT $adm, ID, 'USUARIO:1' FROM $L.PERMISSAO WHERE CODIGO = 'EMPRESA_LER';"
    $renomeia = Invoke-Como $api "UPDATE $L.PERFIL SET NOME = 'CHEFE', ATUALIZADO_POR = 'USUARIO:1' WHERE ID = $adm;"
    $desativa = Invoke-Como $api "UPDATE $L.PERFIL SET ATIVO = FALSE, ATUALIZADO_POR = 'USUARIO:1' WHERE ID = $adm;"
    # A API nem tem UPDATE no PERFIL (16_endurecimento.sql); a trava do ADMINISTRADOR fixo vale ate para o DBA.
    $renomeiaDba = Invoke-Como $engineerConn "ALTER SESSION SET CONTAINER = FREEPDB1;`nUPDATE $L.PERFIL SET NOME = 'CHEFE' WHERE ID = $adm;"
    $desativaDba = Invoke-Como $engineerConn "ALTER SESSION SET CONTAINER = FREEPDB1;`nUPDATE $L.PERFIL SET ATIVO = FALSE WHERE ID = $adm;"
    $comum = Invoke-Como $api "INSERT INTO $L.PERFIL_PERMISSAO (PERFIL_ID, PERMISSAO_ID, ATUALIZADO_POR) SELECT $ope, ID, 'USUARIO:1' FROM $L.PERMISSAO WHERE CODIGO = 'PESSOA_LER';`nCOMMIT;"
    $results += New-TestResult -Name "Permissao exclusiva nao vai para outro perfil (ORA-20108); o ADMINISTRADOR nao recebe permissao (20107); a API nao altera perfil (ORA-01031/41900) e nem o DBA renomeia ou desativa o ADMINISTRADOR (20101); permissao comum entra normalmente" -Passed (($exclusiva -match 'ORA-20108') -and ($noFixo -match 'ORA-20107') -and ($renomeia -match 'ORA-(01031|41900)') -and ($desativa -match 'ORA-(01031|41900)') -and ($renomeiaDba -match 'ORA-20101') -and ($desativaDba -match 'ORA-20101') -and ($comum -notmatch 'ORA-')) -Details "$exclusiva`n$noFixo`n$renomeia`n$desativa`n$renomeiaDba`n$desativaDba`n$comum"

    # --- perfil da mesma empresa e pelo menos um administrador ----------------------------------
    $deOutra = Invoke-Como $api "INSERT INTO $L.USUARIO_EMPRESA (USUARIO_ID, EMPRESA_ID, PERFIL_ID, ATUALIZADO_POR) VALUES ($u2, $empresa, $admOutra, 'USUARIO:1');"
    $results += New-TestResult -Name "O perfil do vinculo tem de ser da mesma empresa: perfil de outra empresa e recusado pela chave composta (ORA-02291)" -Passed ($deOutra -match 'ORA-02291') -Details $deOutra

    $ultimo = Invoke-Como $api "UPDATE $L.USUARIO_EMPRESA SET PERFIL_ID = $ope, ATUALIZADO_POR = 'USUARIO:1' WHERE USUARIO_ID = $u1 AND EMPRESA_ID = $empresa;"
    $desliga = Invoke-Como $api "UPDATE $L.USUARIO_EMPRESA SET ATIVO = FALSE, ATUALIZADO_POR = 'USUARIO:1' WHERE USUARIO_ID = $u1 AND EMPRESA_ID = $empresa;"
    $segundo = Invoke-Como $api "INSERT INTO $L.USUARIO_EMPRESA (USUARIO_ID, EMPRESA_ID, PERFIL_ID, ATUALIZADO_POR) VALUES ($u2, $empresa, $adm, 'USUARIO:1');`nCOMMIT;"
    $agora = Invoke-Como $api "UPDATE $L.USUARIO_EMPRESA SET PERFIL_ID = $ope, ATUALIZADO_POR = 'USUARIO:$u2' WHERE USUARIO_ID = $u1 AND EMPRESA_ID = $empresa;`nCOMMIT;"
    $results += New-TestResult -Name "A empresa nunca fica sem administrador: rebaixar ou desativar o unico e recusado pelo banco (ORA-20103); com um segundo administrador, o primeiro sai do cargo" -Passed (($ultimo -match 'ORA-20103') -and ($desliga -match 'ORA-20103') -and ($segundo -notmatch 'ORA-') -and ($agora -notmatch 'ORA-')) -Details "$ultimo`n$desliga`n$segundo`n$agora"

    # --- o log das trocas -----------------------------------------------------------------------
    $troca = Invoke-Sys "SELECT 'L=' || EVENTO || '|' || PERFIL_ANTERIOR || '|' || PERFIL_NOVO || '|' || FEITO_POR FROM ${amb}_LOG.LOG_PERMISSAO WHERE EMPRESA_ID = $empresa AND USUARIO_ID = $u1 ORDER BY ORDEM;"
    $results += New-TestResult -Name "Cada troca de cargo vai SOZINHA para o LOG_PERMISSAO (gatilho, nao a API): vinculo criado e depois ADMINISTRADOR -> OPERADOR, com quem fez" -Passed (($troca -match "L=VINCULO_CRIADO\|\|ADMINISTRADOR\|USUARIO:1") -and ($troca -match "L=PERFIL_TROCADO\|ADMINISTRADOR\|OPERADOR\|USUARIO:$u2")) -Details $troca

    Invoke-Como $engineerConn "ALTER SESSION SET CONTAINER = FREEPDB1;`nUPDATE $L.USUARIO_EMPRESA SET PERFIL_ID = $adm WHERE USUARIO_ID = $u1 AND EMPRESA_ID = $empresa;`nCOMMIT;" | Out-Null
    $peloDba = Invoke-Sys "SELECT 'D=' || PERFIL_ANTERIOR || '>' || PERFIL_NOVO || '|' || FEITO_POR FROM ${amb}_LOG.LOG_PERMISSAO WHERE EMPRESA_ID = $empresa AND USUARIO_ID = $u1 ORDER BY ORDEM DESC FETCH FIRST 1 ROW ONLY;"
    $results += New-TestResult -Name "Mudanca de cargo feita direto no banco pelo DBA tambem vai para o log, com o nome dele (nao da para mudar escondido)" -Passed ($peloDba -match "D=OPERADOR>ADMINISTRADOR\|$engenheiro") -Details $peloDba

    $antes = Invoke-Sys "SELECT 'Q=' || COUNT(*) FROM ${amb}_LOG.V_LOG_PERMISSAO_QUEBRAS;"
    Invoke-Sys "UPDATE ${amb}_LOG.LOG_PERMISSAO SET PERFIL_NOVO = 'ALTERADO' WHERE EMPRESA_ID = $empresa AND EVENTO = 'VINCULO_CRIADO' AND USUARIO_ID = $u1;`nCOMMIT;" | Out-Null
    $quebra = Invoke-Sys "SELECT 'Q=' || PROBLEMA FROM ${amb}_LOG.V_LOG_PERMISSAO_QUEBRAS;"
    Invoke-Sys "UPDATE ${amb}_LOG.LOG_PERMISSAO SET PERFIL_NOVO = 'ADMINISTRADOR' WHERE EMPRESA_ID = $empresa AND EVENTO = 'VINCULO_CRIADO' AND USUARIO_ID = $u1;`nCOMMIT;" | Out-Null
    $depois = Invoke-Sys "SELECT 'Q=' || COUNT(*) FROM ${amb}_LOG.V_LOG_PERMISSAO_QUEBRAS;"
    $results += New-TestResult -Name "O LOG_PERMISSAO e encadeado: alterar uma linha (mesmo como DBA) aparece na view de quebras; desfeita a alteracao, a corrente fecha de novo" -Passed (($antes -match 'Q=0') -and ($quebra -match 'conteudo alterado') -and ($depois -match 'Q=0')) -Details "$antes`n$quebra`n$depois"

    # --- administrador da plataforma ------------------------------------------------------------
    Invoke-Como $engineerConn "ALTER SESSION SET CONTAINER = FREEPDB1;`nINSERT INTO $L.ADMIN_PLATAFORMA (USUARIO_ID, CONCEDIDO_POR, MOTIVO) VALUES ($u1, 'inventado', '$marca');`nCOMMIT;" | Out-Null
    $concedido = Invoke-Sys "SELECT 'C=' || CONCEDIDO_POR FROM $L.ADMIN_PLATAFORMA WHERE USUARIO_ID = $u1;"
    Invoke-Como $engineerConn "ALTER SESSION SET CONTAINER = FREEPDB1;`nDELETE FROM $L.ADMIN_PLATAFORMA WHERE USUARIO_ID = $u1;`nCOMMIT;" | Out-Null
    $logs = Invoke-Sys "SELECT 'S=' || LISTAGG(EVENTO || ':' || FEITO_POR, ',') WITHIN GROUP (ORDER BY ORDEM) FROM ${amb}_LOG.LOG_SEGURANCA WHERE USUARIO_ID = $u1 AND EVENTO LIKE 'ADMIN_PLATAFORMA%';"
    $results += New-TestResult -Name "Conceder administrador da plataforma grava QUEM concedeu (o nome informado e ignorado) e vai para o LOG_SEGURANCA; revogar tambem" -Passed (($concedido -match "C=$engenheiro") -and ($logs -match "S=ADMIN_PLATAFORMA_CONCEDIDO:$engenheiro,ADMIN_PLATAFORMA_REVOGADO:$engenheiro")) -Details "$concedido`n$logs"
}
finally {
    Write-Host "-> Limpando: conta de teste e linhas de teste da autorizacao (os logs ficam, de proposito)..."
    Invoke-Sys @"
DELETE FROM $L.ADMIN_PLATAFORMA WHERE USUARIO_ID IN (SELECT ID FROM $L.USUARIO WHERE EMAIL_INDICE IN (LOWER(RAWTOHEX(STANDARD_HASH('$marca-1', 'SHA256'))), LOWER(RAWTOHEX(STANDARD_HASH('$marca-2', 'SHA256')))));
DELETE FROM $L.USUARIO_EMPRESA WHERE EMPRESA_ID IN ($empresa, $outra);
DELETE FROM $L.PERFIL_PERMISSAO WHERE PERFIL_ID IN (SELECT ID FROM $L.PERFIL WHERE EMPRESA_ID IN ($empresa, $outra));
DELETE FROM $L.PERFIL WHERE EMPRESA_ID IN ($empresa, $outra);
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
