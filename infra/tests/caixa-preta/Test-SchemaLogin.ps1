# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: os schemas do login (13_schema_login.sql) dao a API exatamente o que ela
    precisa, e nada que permita afrouxar regras, apagar sessoes ou mexer no historico.

.DESCRIPTION
    Confere, com contas de API de verdade (execucao e migracao) no ambiente TESTE_INFRA:
      - ninguem loga nos schemas _LOGIN e _SESSAO;
      - a conta de execucao tem exatamente as permissoes previstas (login so por passkey); a de
        migracao, nenhuma (nem enxerga e-mails nem chaves de passkey);
      - a API le os parametros mas nao os altera; mudanca feita pelo DBA vai sozinha para o
        LOG_SEGURANCA, com quem fez e o valor antigo e novo;
      - o LOG_SEGURANCA e encadeado: alterar uma linha aparece na view de quebras;
      - a hora das tentativas e do servidor, em UTC;
      - o job de limpeza apaga o token vencido ha mais de 7 dias e o desafio de passkey vencido ha
        mais de 1 dia, e deixa o resto;
      - a chave USUARIO -> PESSOA existe onde a PESSOA existe, e a procedure que a cria so atende
        o proprio ambiente.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Continue'

Write-Host "== [CAIXA-PRETA] Schemas do login: a API so faz o que precisa ==" -ForegroundColor Cyan

$createApi    = Join-Path $PSScriptRoot '..\..\scripts\create-api-account.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken   = Get-VaultToken -EnvFile $EnvFile
$amb = 'KAWASHI_ENV_TESTE_INFRA'
$results = @()
$exec = $null; $mig = $null; $usuarioId = $null
$marca = 'TST_LOGIN_' + (Get-Random -Maximum 999999)

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

try {
    $exec = New-ThrowawayUsername -Prefix 'TST_LGNE'
    $mig  = New-ThrowawayUsername -Prefix 'TST_LGNM'
    & $createApi -Username $exec -Ambiente 'TESTE_INFRA' -EnvFile $EnvFile *> $null
    & $createApi -Username $mig -Ambiente 'TESTE_INFRA' -Papel Migracao -EnvFile $EnvFile *> $null
    $connExec = "$exec[${amb}_APP]/$(Get-Senha $exec)@//localhost:1521/FREEPDB1"
    $connMig  = "$mig[$amb]/$(Get-Senha $mig)@//localhost:1521/FREEPDB1"

    # --- os schemas ------------------------------------------------------------------
    $donos = Invoke-Sys "SELECT 'D=' || COUNT(*) || ':' || SUM(CASE WHEN authentication_type = 'NONE' THEN 1 ELSE 0 END) FROM dba_users WHERE REGEXP_LIKE(username, '^KAWASHI_ENV_[A-Z_]+_(LOGIN|SESSAO)$');"
    $sessao = Invoke-Sys "SELECT 'S=' || COUNT(*) FROM dba_sys_privs WHERE REGEXP_LIKE(grantee, '^KAWASHI_ENV_[A-Z_]+_(LOGIN|SESSAO)$');"
    $results += New-TestResult -Name "Os 6 ambientes tem _LOGIN e _SESSAO (12 schemas), todos NO AUTHENTICATION e sem privilegio de sistema: ninguem loga neles" -Passed (($donos -match 'D=12:12') -and ($sessao -match 'S=0')) -Details "$donos $sessao"

    # --- permissoes exatas (o sqlplus quebra a linha longa: a comparacao ignora espacos e quebras) ---
    $privs = Invoke-Sys "SELECT 'P=' || LISTAGG(REPLACE(owner, '${amb}_', '') || '.' || table_name || ':' || privilege, ',') WITHIN GROUP (ORDER BY owner, table_name, privilege) FROM dba_tab_privs WHERE grantee = '${amb}_APP' AND owner IN ('${amb}_LOGIN', '${amb}_SESSAO');"
    # Inclui as tabelas da autorizacao (14), dos termos (15) e o endurecimento (16), todas no _LOGIN.
    $esperado = 'P=LOGIN.ACEITE_TERMO:INSERT,LOGIN.ACEITE_TERMO:SELECT,LOGIN.ADMIN_PLATAFORMA:SELECT,LOGIN.CODIGO_RECUPERACAO:INSERT,LOGIN.CODIGO_RECUPERACAO:SELECT,LOGIN.CODIGO_RECUPERACAO:UPDATE,' +
        'LOGIN.CONVITE:INSERT,LOGIN.CONVITE:SELECT,LOGIN.CONVITE:UPDATE,LOGIN.CONVITE_VINCULO:INSERT,LOGIN.CONVITE_VINCULO:SELECT,LOGIN.PARAMETRO_SEGURANCA:SELECT,' +
        'LOGIN.PASSKEY:INSERT,LOGIN.PASSKEY:SELECT,LOGIN.PASSKEY:UPDATE,LOGIN.PERFIL:INSERT,LOGIN.PERFIL:SELECT,' +
        'LOGIN.PERFIL_PERMISSAO:INSERT,LOGIN.PERFIL_PERMISSAO:SELECT,LOGIN.PERFIL_PERMISSAO:UPDATE,LOGIN.PERMISSAO:SELECT,LOGIN.TERMO:SELECT,' +
        'LOGIN.USUARIO:INSERT,LOGIN.USUARIO:SELECT,LOGIN.USUARIO_EMPRESA:INSERT,LOGIN.USUARIO_EMPRESA:SELECT,LOGIN.USUARIO_EMPRESA:UPDATE,' +
        'SESSAO.BLOQUEIO_IP:INSERT,SESSAO.BLOQUEIO_IP:SELECT,SESSAO.BLOQUEIO_IP:UPDATE,SESSAO.DESAFIO:INSERT,SESSAO.DESAFIO:SELECT,' +
        'SESSAO.DESAFIO:UPDATE,SESSAO.TOKEN:INSERT,SESSAO.TOKEN:SELECT,SESSAO.TOKEN:UPDATE'
    # Permissao por coluna: do USUARIO, a API so liga e desliga (ATIVO).
    $colunas = Invoke-Sys "SELECT 'C=' || LISTAGG(table_name || '.' || column_name || ':' || privilege, ',') WITHIN GROUP (ORDER BY table_name, column_name) FROM dba_col_privs WHERE grantee = '${amb}_APP' AND owner IN ('${amb}_LOGIN', '${amb}_SESSAO');"
    # Por coluna: do USUARIO so ATIVO; do convite de vinculo, so as colunas da resposta (passo 18).
    $colunasEsperadas = 'C=CONVITE_VINCULO.IP_RESPOSTA:UPDATE,CONVITE_VINCULO.RESPONDIDO_POR:UPDATE,CONVITE_VINCULO.SITUACAO:UPDATE,USUARIO.ATIVO:UPDATE'
    $results += New-TestResult -Name "A conta de execucao da API tem EXATAMENTE: passkey, convite, codigo de recuperacao, permissao de perfil, vinculo com empresa, token, desafio e bloqueio de IP (ler, criar, alterar); usuario e perfil (ler e criar; do usuario, UPDATE so na coluna ATIVO); aceite de termos (ler e criar); convite de vinculo (ler, criar e, so nas colunas da resposta, alterar); parametros, termos, lista de permissoes e administradores da plataforma (so ler). Nenhum DELETE" -Passed ((($privs -replace '\s', '') -eq $esperado) -and (($colunas -replace '\s', '') -eq $colunasEsperadas)) -Details "obtido:  $($privs -replace '\s', '') $colunas`nesperado: $esperado $colunasEsperadas"

    $migPriv = Invoke-Sys "SELECT 'M=' || COUNT(*) FROM dba_tab_privs WHERE grantee = '$amb' AND owner IN ('${amb}_LOGIN', '${amb}_SESSAO');"
    $migLe = Invoke-Como $connMig "SELECT COUNT(*) FROM ${amb}_LOGIN.USUARIO;"
    $results += New-TestResult -Name "A conta de MIGRACAO (dona das tabelas de cadastro) nao tem nada no login: nem le os e-mails cifrados nem as chaves das passkeys (ORA-00942)" -Passed (($migPriv -match 'M=0') -and ($migLe -match 'ORA-00942')) -Details "$migPriv`n$migLe"

    $leParam = Invoke-Como $connExec "SELECT 'N=' || COUNT(*) FROM ${amb}_LOGIN.PARAMETRO_SEGURANCA;"
    $mudaParam = Invoke-Como $connExec "UPDATE ${amb}_LOGIN.PARAMETRO_SEGURANCA SET VALOR = 999 WHERE CHAVE = 'TOKEN_MINUTOS';"
    $apagaToken = Invoke-Como $connExec "DELETE FROM ${amb}_SESSAO.TOKEN;"
    $apagaLog = Invoke-Como $connExec "DELETE FROM ${amb}_LOG.LOG_SEGURANCA;"
    $results += New-TestResult -Name "A API le os 11 parametros (o 11o, CONFIRMACAO_MINUTOS, veio no passo 17) mas NAO os altera, nao apaga token e nao apaga log de seguranca (ORA-01031/41900)" -Passed (($leParam -match 'N=11') -and ($mudaParam -match 'ORA-(01031|41900)') -and ($apagaToken -match 'ORA-(01031|41900)') -and ($apagaLog -match 'ORA-(01031|41900)')) -Details "$leParam`n$mudaParam`n$apagaToken`n$apagaLog"

    # --- parametro alterado vai para o log sozinho ----------------------------------------
    $antes = Invoke-Sys "SELECT 'V=' || VALOR FROM ${amb}_LOGIN.PARAMETRO_SEGURANCA WHERE CHAVE = 'IP_MAX_FALHAS';"
    $valorAntes = ($antes -replace '(?s).*V=(\d+).*', '$1')
    Invoke-Como $engineerConn "ALTER SESSION SET CONTAINER = FREEPDB1;`nUPDATE ${amb}_LOGIN.PARAMETRO_SEGURANCA SET VALOR = 77 WHERE CHAVE = 'IP_MAX_FALHAS';`nCOMMIT;" | Out-Null
    $registro = Invoke-Sys "SELECT 'L=' || DETALHE || '|' || FEITO_POR FROM ${amb}_LOG.LOG_SEGURANCA WHERE EVENTO = 'PARAMETRO_ALTERADO' ORDER BY ORDEM DESC FETCH FIRST 1 ROW ONLY;"
    Invoke-Como $engineerConn "ALTER SESSION SET CONTAINER = FREEPDB1;`nUPDATE ${amb}_LOGIN.PARAMETRO_SEGURANCA SET VALOR = $valorAntes WHERE CHAVE = 'IP_MAX_FALHAS';`nCOMMIT;" | Out-Null
    $engenheiro = (Get-EngineerCredentials -EnvFile $EnvFile).User.ToUpper()
    $results += New-TestResult -Name "Mudar um parametro direto no banco (como DBA) gera sozinho uma linha PARAMETRO_ALTERADO no LOG_SEGURANCA, com o valor antigo, o novo e quem mudou" -Passed ($registro -match "L=IP_MAX_FALHAS: $valorAntes -> 77\|$engenheiro") -Details $registro

    # --- corrente do LOG_SEGURANCA ----------------------------------------------------------
    Invoke-Como $connExec "INSERT INTO ${amb}_LOG.LOG_SEGURANCA (EVENTO, DETALHE, FEITO_POR, ORDEM, HASH) VALUES ('LOGIN', '$marca', 'API', 999999, 'forjado');`nCOMMIT;" | Out-Null
    $linha = Invoke-Sys "SELECT 'R=' || ORDEM || '|' || HASH FROM ${amb}_LOG.LOG_SEGURANCA WHERE DETALHE = '$marca';"
    $results += New-TestResult -Name "Quem insere no LOG_SEGURANCA nao escolhe numero nem hash: os forjados sao ignorados e o banco grava os dele" -Passed (($linha -match 'R=\d+\|[0-9a-f]{64}') -and ($linha -notmatch '999999|forjado')) -Details $linha

    $quebrasAntes = Invoke-Sys "SELECT 'Q=' || COUNT(*) FROM ${amb}_LOG.V_LOG_SEGURANCA_QUEBRAS;"
    Invoke-Sys "UPDATE ${amb}_LOG.LOG_SEGURANCA SET DETALHE = '$marca-ALTERADO' WHERE DETALHE = '$marca';`nCOMMIT;" | Out-Null
    $quebras = Invoke-Sys "SELECT 'Q=' || PROBLEMA FROM ${amb}_LOG.V_LOG_SEGURANCA_QUEBRAS;"
    Invoke-Sys "UPDATE ${amb}_LOG.LOG_SEGURANCA SET DETALHE = '$marca' WHERE DETALHE = '$marca-ALTERADO';`nCOMMIT;" | Out-Null
    $quebrasDepois = Invoke-Sys "SELECT 'Q=' || COUNT(*) FROM ${amb}_LOG.V_LOG_SEGURANCA_QUEBRAS;"
    $results += New-TestResult -Name "O LOG_SEGURANCA e encadeado: alterar uma linha (mesmo como DBA) aparece na view de quebras; desfeita a alteracao, a corrente volta a fechar" -Passed (($quebrasAntes -match 'Q=0') -and ($quebras -match 'conteudo alterado') -and ($quebrasDepois -match 'Q=0')) -Details "$quebrasAntes`n$quebras`n$quebrasDepois"

    # --- hora do servidor, em UTC ---------------------------------------------------------
    Invoke-Como $connExec "INSERT INTO ${amb}_LOG.TENTATIVA_LOGIN (METODO, IP_ORIGEM, SUCESSO, MOTIVO, DATA_HORA) VALUES ('PASSKEY', '$marca', FALSE, 'VERIFICACAO_FALHOU', TIMESTAMP '2000-01-01 00:00:00');`nCOMMIT;" | Out-Null
    $hora = Invoke-Sys "SELECT 'H=' || ROUND(ABS(CAST(DATA_HORA AS DATE) - CAST(SYS_EXTRACT_UTC(SYSTIMESTAMP) AS DATE)) * 86400) FROM ${amb}_LOG.TENTATIVA_LOGIN WHERE IP_ORIGEM = '$marca';"
    $padrao = Invoke-Sys "SELECT 'DEF=' || data_default_vc FROM dba_tab_columns WHERE owner = '${amb}_SESSAO' AND table_name = 'TOKEN' AND column_name = 'CRIADO_EM';"
    $segundos = [int](($hora -replace '(?s).*H=(\d+).*', '$1'))
    $results += New-TestResult -Name "A hora da tentativa e a do servidor em UTC (a informada e ignorada), e as colunas nascem em UTC: SYS_EXTRACT_UTC(SYSTIMESTAMP)" -Passed (($segundos -le 120) -and ($padrao -match 'DEF=SYS_EXTRACT_UTC\(SYSTIMESTAMP\)')) -Details "$hora $padrao"

    # --- job de limpeza -----------------------------------------------------------------
    Invoke-Sys @"
INSERT INTO ${amb}_LOGIN.USUARIO (PESSOA_ID, EMAIL_CIFRADO, EMAIL_INDICE, HANDLE)
VALUES (-1, 'v1:' || RPAD('x', 60, 'x'), LOWER(RAWTOHEX(STANDARD_HASH('$marca', 'SHA256'))), SUBSTR(LOWER(RAWTOHEX(STANDARD_HASH('$marca-h', 'SHA256'))), 1, 43));
INSERT INTO ${amb}_SESSAO.DESAFIO (VALOR, FINALIDADE, EXPIRA_EM) VALUES (SUBSTR(LOWER(RAWTOHEX(STANDARD_HASH('$marca-dv', 'SHA256'))), 1, 43), 'LOGIN', SYS_EXTRACT_UTC(SYSTIMESTAMP) - INTERVAL '2' DAY);
INSERT INTO ${amb}_SESSAO.DESAFIO (VALOR, FINALIDADE, EXPIRA_EM) VALUES (SUBSTR(LOWER(RAWTOHEX(STANDARD_HASH('$marca-dn', 'SHA256'))), 1, 43), 'LOGIN', SYS_EXTRACT_UTC(SYSTIMESTAMP) + INTERVAL '5' MINUTE);
INSERT INTO ${amb}_SESSAO.TOKEN (USUARIO_ID, TOKEN_HASH, CRIADO_EM, ULTIMO_USO_EM, EXPIRA_EM, EXPIRA_ABSOLUTO_EM)
SELECT ID, LOWER(RAWTOHEX(STANDARD_HASH('$marca-velho', 'SHA256'))), SYS_EXTRACT_UTC(SYSTIMESTAMP) - INTERVAL '9' DAY,
       SYS_EXTRACT_UTC(SYSTIMESTAMP) - INTERVAL '9' DAY, SYS_EXTRACT_UTC(SYSTIMESTAMP) - INTERVAL '8' DAY, SYS_EXTRACT_UTC(SYSTIMESTAMP) - INTERVAL '8' DAY
  FROM ${amb}_LOGIN.USUARIO WHERE EMAIL_INDICE = LOWER(RAWTOHEX(STANDARD_HASH('$marca', 'SHA256')));
INSERT INTO ${amb}_SESSAO.TOKEN (USUARIO_ID, TOKEN_HASH, EXPIRA_EM, EXPIRA_ABSOLUTO_EM)
SELECT ID, LOWER(RAWTOHEX(STANDARD_HASH('$marca-novo', 'SHA256'))), SYS_EXTRACT_UTC(SYSTIMESTAMP) + INTERVAL '15' MINUTE, SYS_EXTRACT_UTC(SYSTIMESTAMP) + INTERVAL '8' HOUR
  FROM ${amb}_LOGIN.USUARIO WHERE EMAIL_INDICE = LOWER(RAWTOHEX(STANDARD_HASH('$marca', 'SHA256')));
COMMIT;
"@ | Out-Null
    Invoke-Sys "EXEC DBMS_SCHEDULER.RUN_JOB('KAWASHI_LIMPEZA_SESSAO_JOB');" | Out-Null
    $restam = Invoke-Sys "SELECT 'T=' || SUM(CASE WHEN TOKEN_HASH = LOWER(RAWTOHEX(STANDARD_HASH('$marca-velho', 'SHA256'))) THEN 1 ELSE 0 END) || ':' || SUM(CASE WHEN TOKEN_HASH = LOWER(RAWTOHEX(STANDARD_HASH('$marca-novo', 'SHA256'))) THEN 1 ELSE 0 END) FROM ${amb}_SESSAO.TOKEN;"
    $desafios = Invoke-Sys "SELECT 'D=' || SUM(CASE WHEN VALOR = SUBSTR(LOWER(RAWTOHEX(STANDARD_HASH('$marca-dv', 'SHA256'))), 1, 43) THEN 1 ELSE 0 END) || ':' || SUM(CASE WHEN VALOR = SUBSTR(LOWER(RAWTOHEX(STANDARD_HASH('$marca-dn', 'SHA256'))), 1, 43) THEN 1 ELSE 0 END) FROM ${amb}_SESSAO.DESAFIO;"
    $results += New-TestResult -Name "O job de limpeza apaga o token vencido ha mais de 7 dias e o desafio de passkey vencido ha mais de 1 dia, e deixa os validos (quem apaga e o banco, nao a API)" -Passed (($restam -match 'T=0:1') -and ($desafios -match 'D=0:1')) -Details "$restam $desafios"

    # --- chave USUARIO -> PESSOA e a procedure que a cria ------------------------------------
    $fk = Invoke-Sys "SELECT 'FK=' || COUNT(*) FROM dba_constraints WHERE owner = 'KAWASHI_ENV_TESTE_DEV_LOGIN' AND constraint_name = 'FK_USUARIO_PESSOA' AND r_owner = 'KAWASHI_ENV_TESTE_DEV';"
    $peloDono = Invoke-Como $connMig "EXEC SYS.KAWASHI_LIGAR_LOGIN_PESSOA;"
    $peloEngenheiro = Invoke-Como $engineerConn "ALTER SESSION SET CONTAINER = FREEPDB1;`nEXEC SYS.KAWASHI_LIGAR_LOGIN_PESSOA;"
    $pelaApi = Invoke-Como $connExec "EXEC SYS.KAWASHI_LIGAR_LOGIN_PESSOA;"
    $results += New-TestResult -Name "Onde a PESSOA existe (TESTE_DEV), USUARIO aponta para ela (FK entre schemas). A procedure que liga a chave so e chamavel pelo schema do ambiente (o afterMigrate da API): nem o DBA nem a conta de execucao a enxergam (PLS-00201)" -Passed (($fk -match 'FK=1') -and ($peloDono -match 'successfully completed') -and ($peloEngenheiro -match 'PLS-00201') -and ($pelaApi -match 'PLS-00201')) -Details "$fk`n$peloDono`n$peloEngenheiro`n$pelaApi"
}
finally {
    Write-Host "-> Limpando: contas de teste e linhas de teste do login..."
    Invoke-Sys "DELETE FROM ${amb}_SESSAO.DESAFIO WHERE VALOR IN (SUBSTR(LOWER(RAWTOHEX(STANDARD_HASH('$marca-dv', 'SHA256'))), 1, 43), SUBSTR(LOWER(RAWTOHEX(STANDARD_HASH('$marca-dn', 'SHA256'))), 1, 43));`nCOMMIT;" | Out-Null
    Invoke-Sys "DELETE FROM ${amb}_SESSAO.TOKEN WHERE USUARIO_ID IN (SELECT ID FROM ${amb}_LOGIN.USUARIO WHERE EMAIL_INDICE = LOWER(RAWTOHEX(STANDARD_HASH('$marca', 'SHA256'))));`nDELETE FROM ${amb}_LOGIN.USUARIO WHERE EMAIL_INDICE = LOWER(RAWTOHEX(STANDARD_HASH('$marca', 'SHA256')));`nCOMMIT;" | Out-Null
    foreach ($u in @($exec, $mig)) {
        if (-not $u) { continue }
        Invoke-Como $engineerConn "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $u CASCADE;" | Out-Null
        Invoke-Sys "DELETE FROM SYS.KAWASHI_CONTA WHERE USERNAME = '$u';`nCOMMIT;" | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv metadata delete "kawashi-secrets/api/$u" 2>&1 | Out-Null
    }
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
