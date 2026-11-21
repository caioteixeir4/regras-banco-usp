# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: confirma que infra/scripts/create-api-account.ps1 cria uma conta de
    SERVICO (a API) que entra num ambiente via proxy authentication - e so nele - com o perfil
    de servico (pool de conexoes de verdade), sem objetos proprios e sem nenhum caminho para
    outro ambiente.

.DESCRIPTION
    Fecha o ponto em aberto "conta de API por ambiente" (ver TODO em 09_environments.sql): ate
    aqui so existia a KAWASHI_SPRING_USER, uma conta unica sem relacao com os 6 ambientes.
    O modelo agora e o mesmo das pessoas - a API entra como CONTA[KAWASHI_ENV_<AMBIENTE>] - mas
    com KAWASHI_SERVICE_PROFILE (50 sessoes, sem expirar), que e o que um pool JDBC precisa
    (ver item 14 de infra/docs/bugs-primeiro-teste.md).

    Cobre: credenciais no Vault, login via proxy (schema corrente + usuario de proxy), DDL via
    proxy (o Flyway da API precisa criar tabelas), isolamento (DEV e PROD recusam), perfil de
    servico e conta aberta, privilegios minimos, pool de 8 sessoes simultaneas, e as falhas que nao podem deixar nada pela metade (conta duplicada,
    PROD, nome reservado, arquivo .env ja existente).
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env'),
    [int]$ConexoesSimultaneas = 8
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')

Write-Host "== [CAIXA-PRETA] Conta de API via proxy (create-api-account.ps1) ==" -ForegroundColor Cyan

$createApi    = Join-Path $PSScriptRoot '..\..\scripts\create-api-account.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken   = Get-VaultToken -EnvFile $EnvFile
$results = @()
$contasParaLimpar = @()
$arquivosParaLimpar = @()

function Get-CampoDoVault {
    param([string]$Conta, [string]$Campo)
    # O argumento "-field=..." e montado antes numa string: escrito direto na chamada nativa, o
    # PowerShell nao interpola "$Campo" (mesma armadilha do item 6 de bugs-primeiro-teste.md).
    $argCampo = "-field=$Campo"
    return ((docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv get $argCampo "kawashi-secrets/api/$Conta" 2>&1) -join '').Trim()
}

function Start-ConexaoDemorada {
    param([string]$ConnectString)
    # Mesma tecnica de Test-LimiteSessoesAplicacao.ps1: consulta CPU-bound curta que mantem a
    # sessao aberta por um instante, sem depender de DBMS_LOCK/DBMS_SESSION.
    $sql = "SELECT /*+ NO_MERGE */ COUNT(*) FROM (SELECT LEVEL FROM DUAL CONNECT BY LEVEL <= 500000);`nEXIT;`n"
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($sql)
    $b64 = [Convert]::ToBase64String($bytes)
    $innerCmd = 'echo ' + $b64 + ' | base64 -d | sqlplus -s "$ORACLE_CONNSTR"'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'docker'
    $psi.Arguments = "exec -i -e ORACLE_CONNSTR=$ConnectString kawashi-oracle sh -c `"$innerCmd`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    return [System.Diagnostics.Process]::Start($psi)
}

try {
    # --- conta basica, ambiente TESTE_DEV ----------------------------------------
    $api = New-ThrowawayUsername -Prefix 'TST_API'
    $contasParaLimpar += $api
    & $createApi -Username $api -Ambiente 'TESTE_DEV' -EnvFile $EnvFile *> $null

    $senha    = Get-CampoDoVault -Conta $api -Campo 'db_password'
    $jdbcUser = Get-CampoDoVault -Conta $api -Campo 'jdbc_user'
    $okVault = ($senha.Length -ge 20) -and ($jdbcUser -eq "$api[KAWASHI_ENV_TESTE_DEV_APP]")
    $results += New-TestResult -Name "As credenciais da conta de API ficam no Vault (kawashi-secrets/api/<conta>), com o usuario JDBC no formato CONTA[SCHEMA]" -Passed $okVault -Details $(if (-not $okVault) { "jdbc_user='$jdbcUser' tamanho da senha=$($senha.Length)" })

    $conn = "$api[KAWASHI_ENV_TESTE_DEV_APP]/$senha@//localhost:1521/FREEPDB1"

    $outProxy = (Invoke-SqlPlus -ConnectString $conn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || '|' || SYS_CONTEXT('USERENV','PROXY_USER') FROM DUAL;`nEXIT;`n") -join "`n"
    $esperado = "KAWASHI_ENV_TESTE_DEV_APP|$api"
    $results += New-TestResult -Name "Login via proxy: a conta de EXECUCAO (papel padrao) entra no schema _APP do ambiente (CURRENT_SCHEMA) e o Oracle registra a conta como PROXY_USER" -Passed ($outProxy -match [regex]::Escape($esperado)) -Details $(if ($outProxy -notmatch [regex]::Escape($esperado)) { $outProxy })

    # --- as duas contas: execucao nao mexe em estrutura, migracao e a dona -----------
    $tabelaTeste = 'TST_API_DDL_' + (Get-Random -Maximum 99999)
    $outDdlExec = (Invoke-SqlPlus -ConnectString $conn -Sql "CREATE TABLE $tabelaTeste (ID NUMBER);`nCREATE TABLE KAWASHI_ENV_TESTE_DEV.$tabelaTeste (ID NUMBER);`nEXIT;`n") -join "`n"
    $criouAlgo = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nALTER SESSION SET CONTAINER = FREEPDB1;`nSELECT 'TABELAS=' || COUNT(*) FROM dba_tables WHERE table_name = '$tabelaTeste';`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "A conta de EXECUCAO NAO consegue criar tabela, nem no schema _APP nem no schema do ambiente (quem invadir a API nao mexe em estrutura)" -Passed (($outDdlExec -match 'ORA-\d{5}') -and ($criouAlgo -match 'TABELAS=0')) -Details "$outDdlExec | $criouAlgo"

    $outDono = (Invoke-SqlPlus -ConnectString "$api[KAWASHI_ENV_TESTE_DEV]/$senha@//localhost:1521/FREEPDB1" -Sql "SELECT 1 FROM DUAL;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "A conta de EXECUCAO NAO consegue entrar como o dono das tabelas (KAWASHI_ENV_TESTE_DEV): ORA-01017" -Passed ($outDono -match 'ORA-01017') -Details $outDono

    $apiMig = New-ThrowawayUsername -Prefix 'TST_APIM'
    $contasParaLimpar += $apiMig
    & $createApi -Username $apiMig -Ambiente 'TESTE_DEV' -Papel 'Migracao' -EnvFile $EnvFile *> $null
    $senhaMig = Get-CampoDoVault -Conta $apiMig -Campo 'db_password'
    $connMig  = "$apiMig[KAWASHI_ENV_TESTE_DEV]/$senhaMig@//localhost:1521/FREEPDB1"
    $outDdl = (Invoke-SqlPlus -ConnectString $connMig -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT 'SCHEMA=' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') FROM DUAL;`nCREATE TABLE $tabelaTeste (ID NUMBER);`nDROP TABLE $tabelaTeste PURGE;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "A conta de MIGRACAO (-Papel Migracao) entra como o dono e consegue criar e apagar tabela (o Flyway da API precisa disso)" -Passed (($outDdl -match 'SCHEMA=KAWASHI_ENV_TESTE_DEV(\s|$)') -and ($outDdl -notmatch 'ORA-\d{5}')) -Details $outDdl
    $outMigApp = (Invoke-SqlPlus -ConnectString "$apiMig[KAWASHI_ENV_TESTE_DEV_APP]/$senhaMig@//localhost:1521/FREEPDB1" -Sql "SELECT 1 FROM DUAL;`nEXIT;`n") -join "`n"
    $papelNoVault = Get-CampoDoVault -Conta $apiMig -Campo 'papel'
    $results += New-TestResult -Name "Cada conta so tem o seu caminho: a de MIGRACAO nao entra no schema _APP, e o papel fica registrado no Vault" -Passed (($outMigApp -match 'ORA-01017') -and ($papelNoVault -eq 'Migracao')) -Details "$outMigApp | papel=$papelNoVault"

    # --- isolamento: so o ambiente pedido ----------------------------------------
    $outDev  = (Invoke-SqlPlus -ConnectString "$api[KAWASHI_ENV_DEV]/$senha@//localhost:1521/FREEPDB1" -Sql "SELECT 1 FROM DUAL;`nEXIT;`n") -join "`n"
    $outProd = (Invoke-SqlPlus -ConnectString "$api[KAWASHI_ENV_PROD]/$senha@//localhost:1521/FREEPDB1" -Sql "SELECT 1 FROM DUAL;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Isolamento: a conta liberada em TESTE_DEV NAO alcanca KAWASHI_ENV_DEV nem KAWASHI_ENV_PROD (ORA-01017)" -Passed (($outDev -match 'ORA-01017') -and ($outProd -match 'ORA-01017')) -Details $(if (-not (($outDev -match 'ORA-01017') -and ($outProd -match 'ORA-01017'))) { "DEV: $outDev`nPROD: $outProd" })

    # --- perfil de servico, conta aberta, privilegios minimos --------------------
    $outConta = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nALTER SESSION SET CONTAINER = FREEPDB1;`nSELECT profile || '|' || account_status FROM dba_users WHERE username = '$api';`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "A conta usa KAWASHI_SERVICE_PROFILE (nao o de pessoa) e esta OPEN, sem senha expirada (um pool JDBC nao responde ao prompt de troca)" -Passed ($outConta -match 'KAWASHI_SERVICE_PROFILE\|OPEN') -Details $(if ($outConta -notmatch 'KAWASHI_SERVICE_PROFILE\|OPEN') { $outConta })

    $outPriv = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nALTER SESSION SET CONTAINER = FREEPDB1;`nSELECT (SELECT LISTAGG(privilege, ',') WITHIN GROUP (ORDER BY privilege) FROM dba_sys_privs WHERE grantee = '$api') || '|roles=' || (SELECT COUNT(*) FROM dba_role_privs WHERE grantee = '$api') FROM DUAL;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Privilegio minimo: a conta tem SO CREATE SESSION e nenhuma role (nada proprio - tudo que a API cria pertence ao schema do ambiente)" -Passed ($outPriv -match '^\s*CREATE SESSION\|roles=0\s*$') -Details $(if ($outPriv -notmatch '^\s*CREATE SESSION\|roles=0\s*$') { $outPriv })

    # --- pool de verdade ---------------------------------------------------------
    $procs = 1..$ConexoesSimultaneas | ForEach-Object { Start-ConexaoDemorada -ConnectString $conn }
    $pico = 0
    for ($i = 0; $i -lt 10; $i++) {
        $outSess = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT COUNT(*) FROM v`$session WHERE username = 'KAWASHI_ENV_TESTE_DEV_APP';`nEXIT;`n") -join "`n"
        $atual = [int](($outSess -replace '[^\d]', '') -as [int])
        if ($atual -gt $pico) { $pico = $atual }
        Start-Sleep -Milliseconds 300
    }
    $procs | ForEach-Object { $_.WaitForExit(30000) | Out-Null }
    $saidas = ($procs | ForEach-Object { ($_.StandardOutput.ReadToEnd() + $_.StandardError.ReadToEnd()) }) -join "`n"
    $results += New-TestResult -Name "Pool: $ConexoesSimultaneas sessoes proxyadas simultaneas (mais que as 3 do perfil de pessoa) - nenhuma rejeitada (ORA-02391), pico observado: $pico" -Passed (($saidas -notmatch 'ORA-02391') -and ($pico -ge 4)) -Details $(if (-not (($saidas -notmatch 'ORA-02391') -and ($pico -ge 4))) { "pico=$pico`n$saidas" })


    # --- falhas que nao podem deixar nada pela metade ----------------------------
    $erroDuplicada = ''
    try { & $createApi -Username $api -Ambiente 'DEV' -EnvFile $EnvFile *> $null } catch { $erroDuplicada = $_.Exception.Message }
    $outVazou = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT COUNT(*) FROM dba_proxies WHERE proxy = '$api' AND client = 'KAWASHI_ENV_DEV';`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Conta duplicada: o script falha com ORA-01920 e NAO concede proxy nenhum a conta que ja existia (mesma lacuna ja corrigida no onboarding de pessoas)" -Passed (($erroDuplicada -match 'ORA-01920') -and (($outVazou -replace '[^\d]', '') -eq '0')) -Details $(if (-not (($erroDuplicada -match 'ORA-01920') -and (($outVazou -replace '[^\d]', '') -eq '0'))) { "erro='$erroDuplicada' proxies_em_DEV=$outVazou" })

    $erroProd = ''
    try { & $createApi -Username 'TST_API_PROD_X' -Ambiente 'PROD' -EnvFile $EnvFile *> $null } catch { $erroProd = $_.Exception.Message }
    $outProdCriada = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nALTER SESSION SET CONTAINER = FREEPDB1;`nSELECT COUNT(*) FROM dba_users WHERE username = 'TST_API_PROD_X';`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "-Ambiente PROD e recusado e nenhuma conta e criada (producao nao e alcancada por proxy, igual as pessoas)" -Passed (($erroProd -match 'PROD') -and (($outProdCriada -replace '[^\d]', '') -eq '0')) -Details $(if (-not (($erroProd -match 'PROD') -and (($outProdCriada -replace '[^\d]', '') -eq '0'))) { "erro='$erroProd' contas=$outProdCriada" })

    $erroReservado = ''
    try { & $createApi -Username 'KAWASHI_ENV_FALSO' -Ambiente 'TESTE_DEV' -EnvFile $EnvFile *> $null } catch { $erroReservado = $_.Exception.Message }
    $results += New-TestResult -Name "Nome com prefixo KAWASHI_ENV_ e recusado (nao deixa uma conta de API colidir com um schema de ambiente)" -Passed ($erroReservado -match 'reservado') -Details $(if ($erroReservado -notmatch 'reservado') { $erroReservado })

    # --- -OutEnvFile: gera o .env local e nunca sobrescreve ----------------------
    $arquivoEnv = Join-Path ([System.IO.Path]::GetTempPath()) ("tst_api_" + (Get-Random -Maximum 999999) + ".env")
    $arquivosParaLimpar += $arquivoEnv
    $apiEnv = New-ThrowawayUsername -Prefix 'TST_APIE'
    $contasParaLimpar += $apiEnv
    & $createApi -Username $apiEnv -Ambiente 'TESTE_DEV' -OutEnvFile $arquivoEnv -EnvFile $EnvFile *> $null
    $conteudo = if (Test-Path -LiteralPath $arquivoEnv) { Get-Content -LiteralPath $arquivoEnv -Raw } else { '' }
    $senhaEnv = Get-CampoDoVault -Conta $apiEnv -Campo 'db_password'
    $okEnv = ($conteudo -match "DB_USER=$([regex]::Escape($apiEnv))\[KAWASHI_ENV_TESTE_DEV_APP\]") -and $conteudo.Contains("DB_PASSWORD=$senhaEnv") -and ($conteudo -match 'DB_URL=jdbc:oracle:thin:@//localhost:1521/FREEPDB1') -and ($conteudo -match 'DB_SCHEMA=KAWASHI_ENV_TESTE_DEV\s')
    $results += New-TestResult -Name "-OutEnvFile grava DB_URL, DB_SCHEMA, DB_USER (CONTA[SCHEMA_APP]) e DB_PASSWORD (a mesma do Vault) para desenvolvimento local" -Passed $okEnv -Details $(if (-not $okEnv) { "arquivo existe=$(Test-Path -LiteralPath $arquivoEnv)" })

    $apiEnv2 = New-ThrowawayUsername -Prefix 'TST_APIF'
    $erroSobrescrita = ''
    try { & $createApi -Username $apiEnv2 -Ambiente 'TESTE_DEV' -OutEnvFile $arquivoEnv -EnvFile $EnvFile *> $null } catch { $erroSobrescrita = $_.Exception.Message }
    $outCriada2 = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nALTER SESSION SET CONTAINER = FREEPDB1;`nSELECT COUNT(*) FROM dba_users WHERE username = '$apiEnv2';`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "-OutEnvFile nunca troca uma credencial: arquivo que ja tem a conta de execucao recusa outra, e a recusa vem ANTES de criar a conta (nada pela metade)" -Passed (($erroSobrescrita -match 'ja existe') -and (($outCriada2 -replace '[^\d]', '') -eq '0')) -Details $(if (-not (($erroSobrescrita -match 'ja existe') -and (($outCriada2 -replace '[^\d]', '') -eq '0'))) { "erro='$erroSobrescrita' contas=$outCriada2" })
    $apiEnvMig = New-ThrowawayUsername -Prefix 'TST_APIG'
    $contasParaLimpar += $apiEnvMig
    & $createApi -Username $apiEnvMig -Ambiente 'TESTE_DEV' -Papel 'Migracao' -OutEnvFile $arquivoEnv -EnvFile $EnvFile *> $null
    $conteudo2 = Get-Content -LiteralPath $arquivoEnv -Raw
    $okAcrescimo = $conteudo2.Contains("DB_PASSWORD=$senhaEnv") -and ($conteudo2 -match "DB_MIGRACAO_USER=$([regex]::Escape($apiEnvMig))\[KAWASHI_ENV_TESTE_DEV\]\s") -and ($conteudo2 -match 'DB_MIGRACAO_PASSWORD=\S{20,}') -and (([regex]::Matches($conteudo2, '(?m)^DB_URL=')).Count -eq 1) -and (([regex]::Matches($conteudo2, '(?m)^DB_SCHEMA=')).Count -eq 1)
    $results += New-TestResult -Name "-OutEnvFile com -Papel Migracao ACRESCENTA a segunda conta ao mesmo arquivo, sem tocar na primeira e sem repetir DB_URL/DB_SCHEMA" -Passed $okAcrescimo -Details $(if (-not $okAcrescimo) { "chaves: " + ((($conteudo2 -split "`n") | ForEach-Object { ($_ -split '=', 2)[0] }) -join ',') })
}
finally {
    Write-Host "-> Limpando contas descartaveis, segredos no Vault e arquivos temporarios..."
    foreach ($u in $contasParaLimpar) {
        Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $u CASCADE;`nEXIT;`n" | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv metadata delete "kawashi-secrets/api/$u" 2>&1 | Out-Null
    }
    foreach ($f in $arquivosParaLimpar) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
    }
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
