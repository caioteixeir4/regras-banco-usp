# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: confirma que toda conta criada pelos scripts entra no cadastro de
    contas (infra/oracle-init/12_cadastro_de_contas.sql), que o painel mostra cargo, liberacoes
    e a situacao da senha contra o limite de 90 dias, e que ninguem escreve no cadastro por fora.

.DESCRIPTION
    Cobre pessoa (create-team-member.ps1) e conta de API (create-api-account.ps1), mais a conta
    criada POR FORA dos scripts, que tem de aparecer como "SEM CADASTRO" em vez de sumir.

    Para testar vencimento sem esperar 90 dias, a regra da senha mora numa funcao
    (SYS.KAWASHI_SITUACAO_DA_SENHA) que recebe a idade da senha como parametro: o teste chama a
    funcao com 74, 75, 90, 91 dias etc. e confere as fronteiras. Nada do dicionario do Oracle e
    adulterado e nenhuma conta real e envelhecida.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')

Write-Host "== [CAIXA-PRETA] Cadastro de contas: cargo, liberacoes e senha de 90 dias ==" -ForegroundColor Cyan

$createTeam   = Join-Path $PSScriptRoot '..\..\scripts\create-team-member.ps1'
$createApi    = Join-Path $PSScriptRoot '..\..\scripts\create-api-account.ps1'
$painel       = Join-Path $PSScriptRoot '..\..\scripts\cadastro-de-contas.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken   = Get-VaultToken -EnvFile $EnvFile
$results = @()
$pessoa = $null; $api = $null; $porFora = $null

function Invoke-Dba {
    param([string]$Sql)
    return (Invoke-SqlPlus -ConnectString $engineerConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSET LINESIZE 2000`nALTER SESSION SET CONTAINER = FREEPDB1;`n$Sql`nEXIT;`n") -join "`n"
}

function Invoke-Sys {
    param([string]$Sql)
    return (Invoke-SqlPlus -ConnectString '/ as sysdba' -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSET LINESIZE 2000`nALTER SESSION SET CONTAINER = FREEPDB1;`n$Sql`nEXIT;`n") -join "`n"
}

# Uma linha do painel, com os campos que os casos conferem. NLS_LANG em UTF-8 para ler acento.
function Get-Conta {
    param([string]$Username)
    $sql = "SET PAGESIZE 0`nSET FEEDBACK OFF`nSET LINESIZE 2000`nALTER SESSION SET CONTAINER = FREEPDB1;`nSELECT 'L|' || TIPO || '|' || NVL(PERFIL, '-') || '|' || NVL(NOME, '-') || '|' || NVL(CARGO, '-') || '|' || CADASTRO || '|' || NVL(AMBIENTES_LIBERADOS, '-') || '|' || NVL(ROLES, '-') || '|' || NVL(SITUACAO_DA_SENHA, '-') || '|' || NVL(TO_CHAR(DIAS_PARA_VENCER), '-') || '|' || NVL(EXPIRA_SOZINHA, '-') || '|' || NVL(PENDENCIA, '-') || '|' || NVL(AMBIENTE, '-') FROM SYS.V_KAWASHI_CONTAS WHERE USERNAME = '$Username';`nEXIT;`n"
    $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($sql))
    $saida = docker exec -i -e ORACLE_CONNSTR="$engineerConn" -e NLS_LANG=AMERICAN_AMERICA.AL32UTF8 kawashi-oracle sh -c ('echo ' + $b64 + ' | base64 -d | sqlplus -s "$ORACLE_CONNSTR"') 2>&1 | ForEach-Object { "$_" }
    $linha = $saida | Where-Object { $_ -like 'L|*' } | Select-Object -First 1
    if (-not $linha) { return $null }
    # O docker devolve bytes UTF-8 que o PowerShell 5.1 le na pagina de codigo do console.
    $linha = [System.Text.Encoding]::UTF8.GetString([Console]::OutputEncoding.GetBytes($linha))
    $c = $linha.Substring(2).TrimEnd().Split('|')
    return [pscustomobject]@{ Tipo = $c[0]; Perfil = $c[1]; Nome = $c[2]; Cargo = $c[3]; Cadastro = $c[4]; Ambientes = $c[5]; Roles = $c[6]; Senha = $c[7]; Dias = $c[8]; ExpiraSozinha = $c[9]; Pendencia = $c[10]; Ambiente = $c[11]; Bruto = $linha }
}

# Chama a funcao da regra de senha com (status, idade, limite) e devolve a situacao.
function Get-Situacao {
    param([string]$Status, [string]$Idade, [string]$Limite = '90')
    # Como SYS: a funcao e interna do painel e ninguem recebe EXECUTE nela. DEFINE OFF por causa do '&' em 'EXPIRED & LOCKED'.
    $out = Invoke-Sys "SET DEFINE OFF`nSELECT 'SIT=' || KAWASHI_SITUACAO_DA_SENHA('$Status', $Idade, $Limite) FROM dual;"
    if ($out -match 'SIT=([A-Z ]+)') { return $Matches[1].Trim() }
    return "?? $out"
}
function Invoke-Painel {
    param([string[]]$Argumentos)
    $cmd = "& '$painel' $($Argumentos -join ' ') -EnvFile '$EnvFile'"
    $saida = (powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return [pscustomobject]@{ Codigo = $LASTEXITCODE; Saida = $saida }
}

try {
    $pessoa  = New-ThrowawayUsername -Prefix 'TST_CADP'
    $api     = New-ThrowawayUsername -Prefix 'TST_CADA'
    $porFora = New-ThrowawayUsername -Prefix 'TST_CADF'
    $nomeComAcento = "Jos$([char]0xE9) D'$([char]0xC1)vila"

    # --- pessoa criada pelo script -------------------------------------------------
    & $createTeam -Username $pessoa -Profile 'EstagiarioDev' -Nome $nomeComAcento -Cargo 'Estagiario de Desenvolvimento' -EnvFile $EnvFile *> $null
    $c = Get-Conta $pessoa
    $results += New-TestResult -Name "Pessoa criada pelo create-team-member.ps1 entra no cadastro com tipo PESSOA, o perfil escolhido e o cargo informado" -Passed (($null -ne $c) -and ($c.Tipo -eq 'PESSOA') -and ($c.Perfil -eq 'EstagiarioDev') -and ($c.Cargo -eq 'Estagiario de Desenvolvimento') -and ($c.Cadastro -eq 'OK')) -Details "$($c.Bruto)"

    $results += New-TestResult -Name "Nome com acento e apostrofo e gravado intacto (nao vira '?', nao quebra o comando SQL)" -Passed (($null -ne $c) -and ($c.Nome -eq $nomeComAcento)) -Details "esperado=[$nomeComAcento] lido=[$($c.Nome)]"

    $results += New-TestResult -Name "O painel mostra a liberacao da pessoa lida do banco: o ambiente em que ela entra por proxy" -Passed (($null -ne $c) -and ($c.Ambientes -eq 'KAWASHI_ENV_TESTE_DEV')) -Details "ambientes=[$($c.Ambientes)]"

    $results += New-TestResult -Name "Conta nova, com senha temporaria ainda nao trocada, aparece como TROCA PENDENTE, a senha expira sozinha (o banco bloqueia) e isso NAO conta como pendencia do administrador" -Passed (($null -ne $c) -and ($c.Senha -eq 'TROCA PENDENTE') -and ($c.ExpiraSozinha -like 'SIM*') -and ($c.Pendencia -eq '-')) -Details "$($c.Bruto)"

    $outLib = Invoke-Dba "SELECT 'LIB=' || TIPO_LIBERACAO || ':' || LIBERACAO FROM SYS.V_KAWASHI_CONTA_LIBERACOES WHERE USERNAME = '$pessoa' ORDER BY 1;"
    $results += New-TestResult -Name "A view de liberacoes detalha uma linha por liberacao: o ambiente (proxy) e o privilegio CREATE SESSION" -Passed (($outLib -match 'LIB=AMBIENTE:KAWASHI_ENV_TESTE_DEV') -and ($outLib -match 'LIB=PRIVILEGIO:CREATE SESSION')) -Details $outLib

    # --- a liberacao e lida ao vivo, nao copiada -----------------------------------
    Invoke-Dba "GRANT KAWASHI_READONLY TO $pessoa;" | Out-Null
    $comRole = Get-Conta $pessoa
    Invoke-Dba "REVOKE KAWASHI_READONLY FROM $pessoa;" | Out-Null
    $semRole = Get-Conta $pessoa
    $results += New-TestResult -Name "Liberacao dada POR FORA dos scripts (um GRANT direto) aparece no painel na hora, e some quando e revogada: o painel le o banco, nao uma copia" -Passed (($comRole.Roles -match 'KAWASHI_READONLY') -and ($semRole.Roles -notmatch 'KAWASHI_READONLY')) -Details "com=[$($comRole.Roles)] sem=[$($semRole.Roles)]"

    # --- conta de API --------------------------------------------------------------
    & $createApi -Username $api -Ambiente 'TESTE_INFRA' -Responsavel 'Time de Infra' -EnvFile $EnvFile *> $null
    $a = Get-Conta $api
    $results += New-TestResult -Name "Conta de API criada pelo create-api-account.ps1 entra no cadastro com tipo API, papel, ambiente e responsavel" -Passed (($null -ne $a) -and ($a.Tipo -eq 'API') -and ($a.Perfil -eq 'Execucao') -and ($a.Ambiente -eq 'TESTE_INFRA') -and ($a.Nome -eq 'Time de Infra') -and ($a.Ambientes -eq 'KAWASHI_ENV_TESTE_INFRA_APP')) -Details "$($a.Bruto)"

    $results += New-TestResult -Name "Conta de API nova: senha EM DIA, faltam 90 dias, e o painel avisa que ela NAO expira sozinha (rotacao manual)" -Passed (($null -ne $a) -and ($a.Senha -eq 'EM DIA') -and ($a.Dias -eq '90') -and ($a.ExpiraSozinha -like 'NAO*') -and ($a.Pendencia -eq '-')) -Details "$($a.Bruto)"

    # --- os 90 dias ----------------------------------------------------------------
    $s = @{ d0 = (Get-Situacao 'OPEN' '0'); d74 = (Get-Situacao 'OPEN' '74'); d75 = (Get-Situacao 'OPEN' '75'); d90 = (Get-Situacao 'OPEN' '90'); d91 = (Get-Situacao 'OPEN' '91'); d100 = (Get-Situacao 'OPEN' '100') }
    $results += New-TestResult -Name "Regra dos 90 dias, nas fronteiras: 0 e 74 dias EM DIA; 75 dias (faltam 15) e 90 dias (ultimo dia) VENCE EM BREVE; 91 e 100 dias VENCIDA" -Passed (($s.d0 -eq 'EM DIA') -and ($s.d74 -eq 'EM DIA') -and ($s.d75 -eq 'VENCE EM BREVE') -and ($s.d90 -eq 'VENCE EM BREVE') -and ($s.d91 -eq 'VENCIDA') -and ($s.d100 -eq 'VENCIDA')) -Details "0=$($s.d0) 74=$($s.d74) 75=$($s.d75) 90=$($s.d90) 91=$($s.d91) 100=$($s.d100)"

    $e = @{ nova = (Get-Situacao 'EXPIRED' '0'); velha = (Get-Situacao 'EXPIRED(GRACE)' '95'); travada = (Get-Situacao 'LOCKED(TIMED)' '5'); travadaVelha = (Get-Situacao 'EXPIRED & LOCKED' '200'); semData = (Get-Situacao 'OPEN' 'NULL') }
    $results += New-TestResult -Name "Regra da senha, por status: expirada e nova = TROCA PENDENTE (primeiro login); expirada ha mais que o limite = VENCIDA (nao se esconde atras de 'conta nova'); travada = CONTA BLOQUEADA; sem data = SEM DATA" -Passed (($e.nova -eq 'TROCA PENDENTE') -and ($e.velha -eq 'VENCIDA') -and ($e.travada -eq 'CONTA BLOQUEADA') -and ($e.travadaVelha -eq 'CONTA BLOQUEADA') -and ($e.semData -eq 'SEM DATA')) -Details "nova=$($e.nova) velha=$($e.velha) travada=$($e.travada) travadaVelha=$($e.travadaVelha) semData=$($e.semData)"

    $lim = @{ a = (Get-Situacao 'OPEN' '50' '60'); b = (Get-Situacao 'OPEN' '61' '60'); c = (Get-Situacao 'OPEN' '50' '90') }
    $results += New-TestResult -Name "O limite e parametro, nao numero fixo: com limite de 60 dias, 50 dias ja VENCE EM BREVE e 61 esta VENCIDA; com 90, os mesmos 50 dias estao EM DIA" -Passed (($lim.a -eq 'VENCE EM BREVE') -and ($lim.b -eq 'VENCIDA') -and ($lim.c -eq 'EM DIA')) -Details "50/60=$($lim.a) 61/60=$($lim.b) 50/90=$($lim.c)"

    $outLimite = Invoke-Dba "SELECT 'LIM=' || c.LIMITE_DIAS || ' PERFIL=' || p.limit FROM SYS.V_KAWASHI_CONTAS c CROSS JOIN dba_profiles p WHERE c.USERNAME = '$api' AND p.profile = 'KAWASHI_SECURE_PROFILE' AND p.resource_name = 'PASSWORD_LIFE_TIME';"
    $results += New-TestResult -Name "O painel usa como limite o PASSWORD_LIFE_TIME do perfil KAWASHI_SECURE_PROFILE (90), inclusive para a conta de API" -Passed ($outLimite -match 'LIM=90 PERFIL=90') -Details $outLimite

    $outApiData = Invoke-Dba "SELECT 'ORACLE=' || NVL(TO_CHAR(u.expiry_date, 'YYYY-MM-DD'), 'NUNCA') || ' PAINEL=' || NVL(TO_CHAR(c.SENHA_VENCE_EM, 'YYYY-MM-DD'), 'SEM') || ' ST=' || u.account_status FROM SYS.V_KAWASHI_CONTAS c JOIN dba_users u ON u.username = c.USERNAME WHERE c.USERNAME = '$api';"
    $results += New-TestResult -Name "Conta de API: para o Oracle a senha NUNCA expira (a API nao para sozinha), mas o painel calcula uma data-limite mesmo assim: e por ela que a rotacao da API e cobrada" -Passed (($outApiData -match 'ORACLE=NUNCA') -and ($outApiData -match 'PAINEL=\d{4}-\d{2}-\d{2}') -and ($outApiData -match 'ST=OPEN')) -Details $outApiData
    # --- conta criada por fora -----------------------------------------------------
    $senhaFora = New-StrongPassword -Length 16 -AvoidSubstring $porFora
    Invoke-Dba "CREATE USER $porFora IDENTIFIED BY `"$senhaFora`" PROFILE KAWASHI_SECURE_PROFILE;" | Out-Null
    $f = Get-Conta $porFora
    $results += New-TestResult -Name "Conta criada POR FORA dos scripts nao some: aparece no painel como SEM CADASTRO, com pendencia" -Passed (($null -ne $f) -and ($f.Cadastro -eq 'SEM CADASTRO') -and ($f.Pendencia -match 'conta sem cadastro')) -Details "$($f.Bruto)"

    $outVence = Invoke-Dba "SELECT 'IGUAL=' || CASE WHEN c.SENHA_VENCE_EM = TRUNC(u.expiry_date) THEN 'S' ELSE 'N' END || ' painel=' || TO_CHAR(c.SENHA_VENCE_EM, 'YYYY-MM-DD') || ' oracle=' || TO_CHAR(u.expiry_date, 'YYYY-MM-DD') FROM SYS.V_KAWASHI_CONTAS c JOIN dba_users u ON u.username = c.USERNAME WHERE c.USERNAME = '$porFora';"
    $results += New-TestResult -Name "A data de vencimento que o painel calcula e a MESMA em que o Oracle vai expirar a senha da pessoa (o limite vem do perfil, nao de um numero solto)" -Passed ($outVence -match 'IGUAL=S') -Details $outVence

    $r = Invoke-Painel @('-Acao', 'Alertas')
    $results += New-TestResult -Name "cadastro-de-contas.ps1 -Acao Alertas termina com codigo 1 e lista as contas que precisam de acao (serve para agendar)" -Passed (($r.Codigo -eq 1) -and ($r.Saida -match $porFora) -and ($r.Saida -match '1 conta\(s\) precisam|\d+ conta\(s\) precisam') -and ($r.Saida -notmatch $pessoa)) -Details "codigo=$($r.Codigo)`n$($r.Saida)"

    $r = Invoke-Painel @('-Acao', 'Registrar', '-Username', $porFora, '-Tipo', 'PESSOA', '-Perfil', 'Desenvolvedor', '-Nome', "'Maria Souza'", '-Cargo', "'Desenvolvedora Pleno'")
    $f2 = Get-Conta $porFora
    $results += New-TestResult -Name "-Acao Registrar completa o cadastro de uma conta que ja existia: passa a OK, com nome e cargo, e a pendencia de cadastro some" -Passed (($r.Codigo -eq 0) -and ($f2.Cadastro -eq 'OK') -and ($f2.Cargo -eq 'Desenvolvedora Pleno') -and ($f2.Pendencia -notmatch 'cadastro|cargo|nome')) -Details "codigo=$($r.Codigo) $($f2.Bruto)`n$($r.Saida)"

    $r = Invoke-Painel @('-Acao', 'Liberacoes', '-Username', $pessoa)
    $results += New-TestResult -Name "-Acao Liberacoes detalha o que uma conta pode (ambiente por proxy e privilegios)" -Passed (($r.Codigo -eq 0) -and ($r.Saida -match 'KAWASHI_ENV_TESTE_DEV') -and ($r.Saida -match 'CREATE SESSION')) -Details "codigo=$($r.Codigo)`n$($r.Saida)"

    # --- ninguem escreve por fora --------------------------------------------------
    $outUpd = Invoke-Dba "UPDATE SYS.KAWASHI_CONTA SET CARGO = 'Diretor' WHERE USERNAME = '$pessoa';"
    $outDel = Invoke-Dba "DELETE FROM SYS.KAWASHI_CONTA WHERE USERNAME = '$pessoa';"
    $aindaLa = Get-Conta $pessoa
    $results += New-TestResult -Name "Nem o DBA altera ou apaga o cadastro direto na tabela: UPDATE e DELETE sao recusados, a unica entrada e a procedure" -Passed (($outUpd -match 'ORA-(01031|00942|41900)') -and ($outDel -match 'ORA-(01031|00942|41900)') -and ($aindaLa.Cargo -eq 'Estagiario de Desenvolvimento')) -Details "update: $outUpd`ndelete: $outDel"

    $outFantasma = Invoke-Dba "EXEC SYS.KAWASHI_REGISTRAR_CONTA('TST_NAO_EXISTE_XYZ', 'PESSOA', 'Desenvolvedor', 'Fulano', 'Cargo', NULL);"
    $outTipo     = Invoke-Dba "EXEC SYS.KAWASHI_REGISTRAR_CONTA('$pessoa', 'CHEFE', 'Desenvolvedor', NULL, NULL, NULL);"
    $results += New-TestResult -Name "A procedure recusa cadastrar conta que nao existe no banco (ORA-20080) e tipo fora da lista (ORA-20081)" -Passed (($outFantasma -match 'ORA-20080') -and ($outTipo -match 'ORA-20081')) -Details "$outFantasma`n$outTipo"

    $argCampo = '-field=db_password'
    $senhaApi = ((docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv get $argCampo "kawashi-secrets/api/$api" 2>&1) -join '').Trim()
    $connApi = "$api[KAWASHI_ENV_TESTE_INFRA_APP]/$senhaApi@//localhost:1521/FREEPDB1"
    $outLer  = (Invoke-SqlPlus -ConnectString $connApi -Sql "SELECT COUNT(*) FROM SYS.V_KAWASHI_CONTAS;`nEXIT;`n") -join "`n"
    $outExec = (Invoke-SqlPlus -ConnectString $connApi -Sql "EXEC SYS.KAWASHI_REGISTRAR_CONTA('$api', 'ADMIN', 'Engenheiro', NULL, NULL, NULL);`nEXIT;`n") -join "`n"
    $aDepois = Get-Conta $api
    $results += New-TestResult -Name "Uma conta comum (a de API) nao le o painel nem executa a procedure: nao ve o cadastro dos outros e nao se promove a ADMIN" -Passed (($outLer -match 'ORA-00942') -and ($outExec -match 'PLS-00201|ORA-06550') -and ($aDepois.Tipo -eq 'API')) -Details "ler: $outLer`nexec: $outExec"

    # --- o parametro nao vira SQL --------------------------------------------------
    $recusou = $false
    try { & $painel -Acao Registrar -Username $pessoa -Cargo "x'); DELETE FROM SYS.KAWASHI_CONTA; --" -EnvFile $EnvFile *> $null } catch { $recusou = ($_.Exception.Message -match 'Cargo') }
    $results += New-TestResult -Name "Cargo com ponto-e-virgula e comando SQL e recusado pela validacao do parametro, antes de chegar ao banco" -Passed $recusou -Details "recusou=$recusou"

    # --- conta apagada --------------------------------------------------------------
    Invoke-Dba "DROP USER $porFora CASCADE;" | Out-Null
    $fRemovida = Get-Conta $porFora
    $results += New-TestResult -Name "Conta apagada do banco continua no cadastro como REMOVIDA (historico de quem ja teve acesso), sem pendencia" -Passed (($null -ne $fRemovida) -and ($fRemovida.Cadastro -eq 'REMOVIDA') -and ($fRemovida.Pendencia -eq '-')) -Details "$($fRemovida.Bruto)"
}
finally {
    Write-Host "-> Limpando: contas descartaveis, cadastro delas e segredos no Vault..."
    foreach ($u in @($pessoa, $api, $porFora)) {
        if (-not $u) { continue }
        Invoke-Dba "DROP USER $u CASCADE;" | Out-Null
        Invoke-Sys "DELETE FROM SYS.KAWASHI_CONTA WHERE USERNAME = '$u' AND USERNAME LIKE 'TST\_%' ESCAPE '\';`nCOMMIT;" | Out-Null
    }
    if ($pessoa) {
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv metadata delete "kawashi-secrets/onboarding/$pessoa" 2>&1 | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault delete "auth/userpass/users/$pessoa" 2>&1 | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault policy delete "engineer-$($pessoa.ToLower())" 2>&1 | Out-Null
    }
    if ($api) { docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv metadata delete "kawashi-secrets/api/$api" 2>&1 | Out-Null }
    $sobrou = Invoke-Sys "SELECT 'SOBROU=' || COUNT(*) FROM SYS.KAWASHI_CONTA WHERE USERNAME IN ('$pessoa', '$api', '$porFora');"
    $results += New-TestResult -Name "Depois da limpeza nao sobra cadastro das contas do teste" -Passed ($sobrou -match 'SOBROU=0') -Details $sobrou
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
