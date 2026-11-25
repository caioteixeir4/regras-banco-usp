# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: confirma que a ancora do log no Vault (infra/scripts/ancorar-log.ps1)
    pega o ataque que o encadeamento sozinho nao pega: um DBA que altera o log E recalcula a
    corrente inteira.

.DESCRIPTION
    Test-SchemaLogSomenteInsercao.ps1 prova que a view V_LOG_ALTERACAO_QUEBRAS acusa adulteracao
    "parcial". Aqui o adversario e mais forte: ele tem DBA, altera uma linha ja ancorada e refaz
    todos os hashes dali em diante, de modo que a view volta a ficar VAZIA. O teste confirma
    primeiro que esse ataque de fato engana a view (senao nao estaria provando nada) e depois que
    a conferencia contra o Vault o denuncia. Tambem cobre o DBA que apaga o fim do log e ajusta a
    numeracao, e que o script se recusa a ancorar por cima de uma divergencia.

    Usa o ambiente TESTE_INFRA e devolve a corrente e o Vault ao estado inicial no fim.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')

Write-Host "== [CAIXA-PRETA] Ancora do log no Vault: pega o DBA que recalcula a corrente ==" -ForegroundColor Cyan

$createApi    = Join-Path $PSScriptRoot '..\..\scripts\create-api-account.ps1'
$ancorar      = Join-Path $PSScriptRoot '..\..\scripts\ancorar-log.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken   = Get-VaultToken -EnvFile $EnvFile
$log          = 'KAWASHI_ENV_TESTE_INFRA_LOG'
$marca        = 'TST_ANC_' + (Get-Random -Maximum 999999)
$results = @()
$api = $null
$estadoInicial = $null

# O mesmo conteudo que o trigger usa para o hash (11_schema_log.sql). E o que um DBA
# mal-intencionado usaria para refazer a corrente.
$conteudo = "NVL(HASH_ANTERIOR, '-') || '|' || ORDEM || '|' || TABELA || '|' || REGISTRO_ID || '|' || ACAO || '|' || USUARIO || '|' || TO_CHAR(DATA_HORA, 'YYYY-MM-DD`"T`"HH24:MI:SS.FF6') || '|' || DETALHE"

function Invoke-Dba {
    param([string]$Sql)
    return (Invoke-SqlPlus -ConnectString $engineerConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSET LINESIZE 300`nALTER SESSION SET CONTAINER = FREEPDB1;`n$Sql`nEXIT;`n") -join "`n"
}

function Invoke-Ancora {
    param([string]$Acao)
    $saida = (& $ancorar -Acao $Acao -Ambiente 'TESTE_INFRA' -EnvFile $EnvFile *>&1 | ForEach-Object { "$_" }) -join "`n"
    return [pscustomobject]@{ Codigo = $LASTEXITCODE; Saida = $saida }
}

function Get-Ancora {
    param([string]$Campo)
    $argCampo = "-field=$Campo"
    return ((docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv get $argCampo 'kawashi-secrets/log-ancora/TESTE_INFRA' 2>$null) -join '').Trim()
}

# Refaz a corrente a partir de uma ordem, como um DBA faria para esconder uma alteracao.
function Invoke-RecalculoDaCorrente {
    param([long]$APartirDe)
    Invoke-Dba @"
DECLARE
    v_ant VARCHAR2(64);
BEGIN
    SELECT MAX(HASH) KEEP (DENSE_RANK LAST ORDER BY ORDEM) INTO v_ant FROM $log.LOG_ALTERACAO WHERE ORDEM < $APartirDe;
    FOR l IN (SELECT ORDEM FROM $log.LOG_ALTERACAO WHERE ORDEM >= $APartirDe ORDER BY ORDEM) LOOP
        UPDATE $log.LOG_ALTERACAO SET HASH_ANTERIOR = v_ant WHERE ORDEM = l.ORDEM;
        UPDATE $log.LOG_ALTERACAO SET HASH = LOWER(RAWTOHEX(STANDARD_HASH($conteudo, 'SHA256'))) WHERE ORDEM = l.ORDEM
            RETURNING HASH INTO v_ant;
    END LOOP;
    UPDATE $log.LOG_CADEIA SET ULTIMO_HASH = v_ant, ULTIMA_ORDEM = (SELECT NVL(MAX(ORDEM), 0) FROM $log.LOG_ALTERACAO)
     WHERE TABELA = 'LOG_ALTERACAO';
    COMMIT;
END;
/
"@ | Out-Null
}

try {
    $api = New-ThrowawayUsername -Prefix 'TST_APIA'
    & $createApi -Username $api -Ambiente 'TESTE_INFRA' -EnvFile $EnvFile *> $null
    $argCampo = '-field=db_password'
    $senha = ((docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv get $argCampo "kawashi-secrets/api/$api" 2>&1) -join '').Trim()
    $conn = "$api[KAWASHI_ENV_TESTE_INFRA_APP]/$senha@//localhost:1521/FREEPDB1"
    function Add-LinhaDeLog {
        param([int]$Registro)
        Invoke-SqlPlus -ConnectString $conn -Sql "INSERT INTO $log.LOG_ALTERACAO (TABELA, REGISTRO_ID, ACAO, USUARIO) VALUES ('PESSOA', $Registro, 'INSERT', '$marca');`nCOMMIT;`nEXIT;`n" | Out-Null
    }

    $estadoInicial = (Invoke-Dba "SELECT ULTIMA_ORDEM || '|' || NVL(ULTIMO_HASH, '-') FROM $log.LOG_CADEIA WHERE TABELA = 'LOG_ALTERACAO';").Trim()
    docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv metadata delete 'kawashi-secrets/log-ancora/TESTE_INFRA' 2>&1 | Out-Null

    # --- ancorar e conferir, caminho feliz ----------------------------------------
    Add-LinhaDeLog 1; Add-LinhaDeLog 2
    $ordemAncorada = [long]((Invoke-Dba "SELECT 'O=' || MAX(ORDEM) FROM $log.LOG_ALTERACAO WHERE USUARIO = '$marca';") -replace '[^\d]', '')
    $hashNoBanco   = (Invoke-Dba "SELECT 'H=' || HASH FROM $log.LOG_ALTERACAO WHERE ORDEM = $ordemAncorada;") -replace '(?s).*H=', '' -replace '\s', ''

    $r = Invoke-Ancora 'Ancorar'
    $okAncora = ($r.Codigo -eq 0) -and ((Get-Ancora 'ordem') -eq "$ordemAncorada") -and ((Get-Ancora 'hash') -eq $hashNoBanco)
    $results += New-TestResult -Name "Ancorar grava no Vault o numero e o hash da ultima linha do log (kawashi-secrets/log-ancora/<AMBIENTE>)" -Passed $okAncora -Details "codigo=$($r.Codigo) ordem=$(Get-Ancora 'ordem') esperado=$ordemAncorada`n$($r.Saida)"

    $r = Invoke-Ancora 'Conferir'
    $results += New-TestResult -Name "Conferir logo depois de ancorar: banco e Vault batem (codigo 0)" -Passed (($r.Codigo -eq 0) -and ($r.Saida -match 'bate com a ancora')) -Details $r.Saida

    Add-LinhaDeLog 3
    $r = Invoke-Ancora 'Conferir'
    $results += New-TestResult -Name "Linhas NOVAS depois da ancora nao sao divergencia: o log pode crescer" -Passed ($r.Codigo -eq 0) -Details $r.Saida

    # --- o ataque que o encadeamento sozinho nao pega ------------------------------
    Invoke-Dba "UPDATE $log.LOG_ALTERACAO SET REGISTRO_ID = 999 WHERE ORDEM = $ordemAncorada;`nCOMMIT;" | Out-Null
    Invoke-RecalculoDaCorrente -APartirDe $ordemAncorada
    $outView = Invoke-Dba "SELECT 'QUEBRAS=' || COUNT(*) FROM $log.V_LOG_ALTERACAO_QUEBRAS;"
    $results += New-TestResult -Name "Precondicao do ataque: um DBA altera uma linha e recalcula a corrente inteira, e a view de conferencia volta a ficar VAZIA (o encadeamento sozinho nao ve)" -Passed ($outView -match 'QUEBRAS=0') -Details $outView

    $r = Invoke-Ancora 'Conferir'
    $results += New-TestResult -Name "A conferencia contra o Vault DENUNCIA esse ataque: a linha ancorada mudou (codigo 1)" -Passed (($r.Codigo -eq 1) -and ($r.Saida -match 'mudou depois de ancorada')) -Details "codigo=$($r.Codigo)`n$($r.Saida)"

    $r = Invoke-Ancora 'Ancorar'
    $results += New-TestResult -Name "Ancorar se RECUSA a gravar por cima de uma divergencia (nao legitima o log adulterado): codigo 1 e a ancora antiga continua no Vault" -Passed (($r.Codigo -eq 1) -and ((Get-Ancora 'hash') -eq $hashNoBanco)) -Details "codigo=$($r.Codigo) hash no vault=$(Get-Ancora 'hash')`n$($r.Saida)"

    # --- o DBA apaga o fim do log e ajusta a numeracao -----------------------------
    Invoke-Dba "DELETE FROM $log.LOG_ALTERACAO WHERE ORDEM >= $ordemAncorada;`nCOMMIT;" | Out-Null
    Invoke-RecalculoDaCorrente -APartirDe $ordemAncorada
    $outView2 = Invoke-Dba "SELECT 'QUEBRAS=' || COUNT(*) FROM $log.V_LOG_ALTERACAO_QUEBRAS;"
    $r = Invoke-Ancora 'Conferir'
    $results += New-TestResult -Name "O DBA apaga o fim do log e ajusta o controle (view vazia de novo): a conferencia contra o Vault acusa que a linha ancorada sumiu e que o log encolheu" -Passed (($outView2 -match 'QUEBRAS=0') -and ($r.Codigo -eq 1) -and ($r.Saida -match 'nao existe mais') -and ($r.Saida -match 'encolheu')) -Details "$outView2`ncodigo=$($r.Codigo)`n$($r.Saida)"

    # --- os outros dois logs encadeados (LOG_SEGURANCA e LOG_PERMISSAO) tambem tem ancora ----------
    $ordemP = [long]((Invoke-Dba "SELECT 'O=' || NVL(MAX(ORDEM), 0) FROM $log.LOG_PERMISSAO;") -replace '[^\d]', '')
    if ($ordemP -gt 0) {
        Invoke-Ancora 'Ancorar' | Out-Null   # o LOG_ALTERACAO esta adulterado por este teste: ele recusa, os outros ancoram
        $ancoraP = ((docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv get '-field=ordem' 'kawashi-secrets/log-ancora/TESTE_INFRA/LOG_PERMISSAO' 2>$null) -join '').Trim()
        $hashP = (Invoke-Dba "SELECT 'H=' || HASH FROM $log.LOG_PERMISSAO WHERE ORDEM = $ordemP;") -replace '(?s).*H=', '' -replace '\s', ''
        Invoke-Dba "UPDATE $log.LOG_PERMISSAO SET HASH = RPAD('0', 64, '0') WHERE ORDEM = $ordemP;`nCOMMIT;" | Out-Null
        $conf = Invoke-Ancora 'Conferir'
        Invoke-Dba "UPDATE $log.LOG_PERMISSAO SET HASH = '$hashP' WHERE ORDEM = $ordemP;`nCOMMIT;" | Out-Null
        $results += New-TestResult -Name "LOG_SEGURANCA e LOG_PERMISSAO tambem sao ancorados (log-ancora/<AMBIENTE>/<TABELA>), e adulterar a linha ancorada do LOG_PERMISSAO e acusado" -Passed (($ancoraP -eq "$ordemP") -and ($conf.Codigo -eq 1) -and ($conf.Saida -match 'DIVERGENCIA\] TESTE_INFRA LOG_PERMISSAO') -and ($conf.Saida -match 'mudou depois de ancorada')) -Details "ancora=$ancoraP esperado=$ordemP codigo=$($conf.Codigo)`n$($conf.Saida)"
    }
}
finally {
    Write-Host "-> Limpando: linhas do teste, estado da corrente, ancora no Vault e conta descartavel..."
    if ($estadoInicial) {
        $p = $estadoInicial.Split('|')
        $hashInicial = if ($p[1] -eq '-') { 'NULL' } else { "'$($p[1])'" }
        Invoke-Dba "DELETE FROM $log.LOG_ALTERACAO WHERE USUARIO = '$marca';`nUPDATE $log.LOG_CADEIA SET ULTIMA_ORDEM = $($p[0]), ULTIMO_HASH = $hashInicial WHERE TABELA = 'LOG_ALTERACAO';`nCOMMIT;" | Out-Null
        $outLimpo = Invoke-Dba "SELECT 'QUEBRAS=' || COUNT(*) FROM $log.V_LOG_ALTERACAO_QUEBRAS;"
        $results += New-TestResult -Name "Depois da limpeza a corrente do ambiente de teste volta a estar inteira" -Passed ($outLimpo -match 'QUEBRAS=0') -Details $outLimpo
    }
    foreach ($caminho in 'log-ancora/TESTE_INFRA', 'log-ancora/TESTE_INFRA/LOG_SEGURANCA', 'log-ancora/TESTE_INFRA/LOG_PERMISSAO') {
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv metadata delete "kawashi-secrets/$caminho" 2>&1 | Out-Null
    }
    if ($api) {
        Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $api CASCADE;`nEXIT;`n" | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv metadata delete "kawashi-secrets/api/$api" 2>&1 | Out-Null
    }
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results