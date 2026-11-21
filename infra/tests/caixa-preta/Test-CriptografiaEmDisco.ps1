# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: confirma que os dados do Kawashi estao cifrados EM DISCO (TDE,
    infra/scripts/enable-tde.ps1), olhando os arquivos do banco por fora, como faria quem
    copiasse o disco ou um backup.

.DESCRIPTION
    Nao basta o dicionario do Oracle dizer "ENCRYPTED=YES". O teste grava uma marca conhecida
    numa tabela de um schema de ambiente e procura essa marca, byte a byte, em todos os arquivos
    do banco (dados, undo e redo). Para a busca valer alguma coisa ha um CONTROLE POSITIVO: a
    mesma operacao feita numa tablespace que NAO e cifrada (SYSAUX) tem de ser encontrada. Sem
    esse controle, "nao achei" poderia ser so uma busca que nao funciona.

    As marcas sao montadas por concatenacao dentro do PL/SQL, para o texto completo nunca
    aparecer em um comando SQL (que o banco poderia guardar em auditoria ou cache em claro).

    Usa o ambiente TESTE_INFRA e apaga as duas tabelas no fim.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')

Write-Host "== [CAIXA-PRETA] Criptografia em disco (TDE): o arquivo copiado nao revela o dado ==" -ForegroundColor Cyan

$VaultToken = Get-VaultToken -EnvFile $EnvFile
$results = @()
$sufixo = '{0:D6}' -f (Get-Random -Maximum 999999)
$marcaCifrada = "KWTDECIFRADO$sufixo"
$marcaClara   = "KWTDECLARO$sufixo"
$schema = 'KAWASHI_ENV_TESTE_INFRA'

function Invoke-Sys {
    param([string]$Sql, [switch]$NaRaiz)
    $container = if ($NaRaiz) { '' } else { "ALTER SESSION SET CONTAINER = FREEPDB1;`n" }
    return (Invoke-SqlPlus -ConnectString '/ as sysdba' -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSET LINESIZE 300`n$container$Sql`nEXIT;`n") -join "`n"
}

# Procura um texto, byte a byte, em todos os arquivos do banco. Devolve os arquivos onde achou.
function Find-NosArquivosDoBanco {
    param([string]$Texto)
    $cmd = "grep -rlaF '$Texto' /opt/oracle/oradata /opt/oracle/product/26ai/dbhomeFree/dbs 2>/dev/null"
    return @(docker exec kawashi-oracle sh -c $cmd) | Where-Object { $_ }
}

try {
    # --- o que o banco declara -----------------------------------------------------
    $outWallet = Invoke-Sys -NaRaiz "SELECT 'C' || con_id || '=' || status || '/' || wallet_type FROM v`$encryption_wallet ORDER BY con_id;"
    $abertos = ([regex]::Matches($outWallet, 'C\d+=OPEN/')).Count
    $total   = ([regex]::Matches($outWallet, 'C\d+=')).Count
    $results += New-TestResult -Name "O keystore (cofre da chave mestra) esta ABERTO na raiz e em todos os PDBs" -Passed (($total -ge 2) -and ($abertos -eq $total)) -Details $outWallet

    $results += New-TestResult -Name "O keystore abre SOZINHO quando o banco sobe (AUTOLOGIN): reiniciar o container nao deixa os dados inacessiveis" -Passed ($outWallet -match 'C1=OPEN/(AUTOLOGIN|LOCAL_AUTOLOGIN)') -Details $outWallet

    $outTs = Invoke-Sys "SELECT 'TS=' || tablespace_name || ':' || encrypted FROM dba_tablespaces WHERE tablespace_name LIKE 'TS\_KAWASHI\_%' ESCAPE '\' OR tablespace_name = 'USERS' ORDER BY 1;"
    $cifradas = ([regex]::Matches($outTs, 'TS=\S+:YES')).Count
    $emClaro  = ([regex]::Matches($outTs, 'TS=\S+:NO')).Count
    $results += New-TestResult -Name "TODAS as tablespaces do Kawashi (TS_KAWASHI_*) e a USERS estao cifradas" -Passed (($cifradas -ge 9) -and ($emClaro -eq 0)) -Details $outTs

    $outAlg = Invoke-Sys "SELECT 'ALG=' || t.name || ':' || e.encryptionalg FROM v`$tablespace t JOIN v`$encrypted_tablespaces e ON e.ts# = t.ts# AND e.con_id = t.con_id WHERE t.name LIKE 'TS\_KAWASHI\_%' ESCAPE '\' OR t.name = 'USERS' ORDER BY 1;"
    $aes256 = ([regex]::Matches($outAlg, 'ALG=\S+:AES256')).Count
    $outros = ([regex]::Matches($outAlg, 'ALG=')).Count - $aes256
    $results += New-TestResult -Name "O algoritmo e AES-256 em todas elas" -Passed (($aes256 -ge 9) -and ($outros -eq 0)) -Details $outAlg

    $outNovo = Invoke-Sys -NaRaiz "SELECT 'P=' || value FROM v`$parameter WHERE name = 'encrypt_new_tablespaces';"
    $results += New-TestResult -Name "Tablespace criada no futuro ja nasce cifrada (ENCRYPT_NEW_TABLESPACES=ALWAYS)" -Passed ($outNovo -match 'P=ALWAYS') -Details $outNovo

    $outDono = Invoke-Sys "SELECT 'DONO=' || default_tablespace FROM dba_users WHERE username IN ('$schema', '${schema}_LOG') ORDER BY username;"
    $results += New-TestResult -Name "Os schemas de ambiente e de log guardam seus dados em tablespace cifrada" -Passed (($outDono -match 'DONO=') -and ($outDono -notmatch 'DONO=(SYSTEM|SYSAUX)')) -Details $outDono

    # --- o que o disco revela -------------------------------------------------------
    # CHR(...) || texto: o valor gravado e a marca inteira, mas o comando SQL nunca a contem.
    $p1c = $marcaCifrada.Substring(0, 6); $p2c = $marcaCifrada.Substring(6)
    $p1a = $marcaClara.Substring(0, 6);   $p2a = $marcaClara.Substring(6)
    Invoke-Sys @"
CREATE TABLE $schema.TST_TDE_CIFRADO (TEXTO VARCHAR2(100));
CREATE TABLE SYSTEM.TST_TDE_CLARO (TEXTO VARCHAR2(100)) TABLESPACE SYSAUX;
BEGIN
    FOR i IN 1..50 LOOP
        INSERT INTO $schema.TST_TDE_CIFRADO VALUES ('$p1c' || '$p2c');
        INSERT INTO SYSTEM.TST_TDE_CLARO VALUES ('$p1a' || '$p2a');
    END LOOP;
    COMMIT;
END;
/
ALTER SYSTEM CHECKPOINT;
"@ | Out-Null
    Invoke-Sys -NaRaiz "ALTER SYSTEM CHECKPOINT;`nALTER SYSTEM SWITCH LOGFILE;" | Out-Null

    $outLido = Invoke-Sys "SELECT 'LIDO=' || COUNT(*) FROM $schema.TST_TDE_CIFRADO WHERE TEXTO = '$p1c' || '$p2c';"
    $results += New-TestResult -Name "Para quem esta DENTRO do banco nada muda: a marca gravada na tablespace cifrada e lida normalmente (a cifra e transparente)" -Passed ($outLido -match 'LIDO=50') -Details $outLido

    $ondeClara = Find-NosArquivosDoBanco $marcaClara
    $results += New-TestResult -Name "CONTROLE POSITIVO: a marca gravada numa tablespace SEM cifra (SYSAUX) e encontrada em claro nos arquivos do banco (prova que a busca funciona)" -Passed ($ondeClara.Count -ge 1) -Details "arquivos: $($ondeClara -join ', ')"

    $ondeCifrada = Find-NosArquivosDoBanco $marcaCifrada
    $results += New-TestResult -Name "A marca gravada num schema de ambiente NAO aparece em nenhum arquivo do banco: nem nos dados, nem no undo, nem no redo" -Passed ($ondeCifrada.Count -eq 0) -Details "achada em: $($ondeCifrada -join ', ')"

    # --- a guarda da senha do keystore ---------------------------------------------
    $perm = ((docker exec kawashi-oracle sh -c "stat -c '%a' /opt/oracle/admin/FREE/wallet; stat -c '%a' /opt/oracle/admin/FREE/wallet/tde/ewallet.p12") -join ' ').Trim()
    $results += New-TestResult -Name "A pasta do keystore e o arquivo da chave so podem ser lidos pelo dono (700 e 600)" -Passed ($perm -eq '700 600') -Details "permissoes: $perm"

    $argCampo = '-field=keystore_password'
    $tamanho = (((docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv get $argCampo 'kawashi-secrets/tde' 2>$null) -join '').Trim()).Length
    $results += New-TestResult -Name "A senha do keystore tem copia no Vault (kawashi-secrets/tde), fora do banco" -Passed ($tamanho -ge 30) -Details "tamanho lido: $tamanho (se 0, rode infra/scripts/enable-tde.ps1 de novo: o Vault de desenvolvimento perde tudo ao reiniciar)"
}
finally {
    Write-Host "-> Limpando: as duas tabelas do teste..."
    Invoke-Sys "DROP TABLE $schema.TST_TDE_CIFRADO PURGE;`nDROP TABLE SYSTEM.TST_TDE_CLARO PURGE;" | Out-Null
    $sobrou = Invoke-Sys "SELECT 'SOBROU=' || COUNT(*) FROM dba_tables WHERE table_name IN ('TST_TDE_CIFRADO', 'TST_TDE_CLARO');"
    $results += New-TestResult -Name "Depois da limpeza as tabelas do teste nao existem mais" -Passed ($sobrou -match 'SOBROU=0') -Details $sobrou
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
