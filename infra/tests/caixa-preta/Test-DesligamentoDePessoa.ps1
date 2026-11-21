# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: quem e desligado pelo remove-team-member.ps1 perde todo acesso NA HORA,
    inclusive as sessoes que ja estavam abertas, e o desligamento fica registrado e vigiado.

.DESCRIPTION
    Cria uma pessoa (perfil Desenvolvedor, com uma role extra e uma permissao direta num objeto),
    da a ela uma senha definitiva e abre DUAS sessoes de verdade que ficam paradas: uma direta e uma
    por proxy no ambiente DEV. Depois desliga e confere, por fora:
      - login direto e por proxy recusados;
      - nenhum proxy, role, privilegio ou permissao sobrando;
      - as duas sessoes abertas derrubadas (a por proxy so e achavel pela auditoria de logon);
      - login, policy e segredos da pessoa apagados do Vault;
      - o cadastro mostra DESLIGADA com motivo, e vira ALARME se alguem destrancar a conta ou
        devolver um acesso por fora.
    Tambem confere as recusas (conta de API, administrador, conta com DBA, conta inexistente), que
    rodar de novo nao da erro, e o -Apagar com recriacao do mesmo nome.

    Nenhuma conta real e tocada: a recusa "quem tem DBA" e testada numa conta descartavel com DBA,
    nunca na do engenheiro.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')

# O Run-AllTests roda em modo 'Stop', e nele o PowerShell 5.1 transforma em excecao qualquer texto que
# um programa externo escreve no stderr. Aqui o Vault responde 'No value found' exatamente quando o
# teste PASSA (o segredo foi apagado), entao este arquivo trata o stderr como texto, nao como erro.
$ErrorActionPreference = 'Continue'

Write-Host "== [CAIXA-PRETA] Desligamento: quem sai perde tudo na hora, e fica registrado ==" -ForegroundColor Cyan

$scripts      = Join-Path $PSScriptRoot '..\..\scripts'
$createTeam   = Join-Path $scripts 'create-team-member.ps1'
$createApi    = Join-Path $scripts 'create-api-account.ps1'
$remove       = Join-Path $scripts 'remove-team-member.ps1'
$painel       = Join-Path $scripts 'cadastro-de-contas.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken   = Get-VaultToken -EnvFile $EnvFile
$results = @()
$pessoa = $null; $marca = $null; $outra = $null; $api = $null; $comDba = $null; $admin = $null

function Invoke-Dba {
    param([string]$Sql)
    return (Invoke-SqlPlus -ConnectString $engineerConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSET LINESIZE 2000`nSET SERVEROUTPUT ON`nALTER SESSION SET CONTAINER = FREEPDB1;`n$Sql`nEXIT;`n") -join "`n"
}

function Get-Valor {
    param([string]$Select)
    $out = Invoke-Dba $Select
    if ($out -match 'V=(\S*)') { return $Matches[1] }
    return "?? $out"
}

# Roda um script em outro processo (para o "exit" dele nao encerrar o teste) e devolve codigo + saida.
function Invoke-Script {
    param([string]$Caminho, [string]$Argumentos)
    $cmd = "& '$Caminho' $Argumentos -EnvFile '$EnvFile'"
    $saida = (powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return [pscustomobject]@{ Codigo = $LASTEXITCODE; Saida = $saida }
}

# Abre uma sessao que fica parada ~2 minutos, em segundo plano dentro do container.
# A sessao se marca com um MODULO proprio: o teste conta as sessoes por essa marca, e nao pela
# mesma busca (auditoria) que a procedure usa, senao um erro nela passaria despercebido aqui.
function Start-SessaoParada {
    param([string]$ConnectString, [string]$Marca)
    $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes("EXEC DBMS_APPLICATION_INFO.SET_MODULE('$Marca', NULL);`nEXEC DBMS_SESSION.SLEEP(120);`nEXIT;`n"))
    $inner = 'echo ' + $b64 + ' | base64 -d | sqlplus -s "$ORACLE_CONNSTR"'
    docker exec -d -e ORACLE_CONNSTR="$ConnectString" kawashi-oracle sh -c "$inner" | Out-Null
}

# Sessoes abertas com a marca do teste, vistas pelo v$session.
function Get-SessoesMarcadas {
    param([string]$Marca)
    $out = (Invoke-SqlPlus -ConnectString '/ as sysdba' -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nALTER SESSION SET CONTAINER = FREEPDB1;`nSELECT 'V=' || COUNT(*) || ':' || LISTAGG(username, ',') WITHIN GROUP (ORDER BY username) FROM v`$session WHERE module = '$Marca';`nEXIT;`n") -join "`n"
    if ($out -match 'V=(\S*)') { return $Matches[1] }
    return "?? $out"
}
function Test-Login {
    param([string]$ConnectString)
    return (Invoke-SqlPlus -ConnectString $ConnectString -Sql "SELECT 'ENTROU=' || USER FROM dual;`nEXIT;`n") -join "`n"
}

function Get-Painel {
    param([string]$Conta)
    $out = Invoke-Dba "SELECT 'L|' || CADASTRO || '|' || NVL(STATUS_DA_CONTA, '-') || '|' || NVL(SITUACAO_DA_SENHA, '-') || '|' || NVL(PENDENCIA, '-') || '|' || NVL(MOTIVO_DESLIGAMENTO, '-') || '|' || NVL(DESLIGADA_POR, '-') || '|' || NVL(TO_CHAR(DESLIGADA_EM, 'YYYY'), '-') FROM SYS.V_KAWASHI_CONTAS WHERE USERNAME = '$Conta';"
    $linha = ($out -split "`n" | Where-Object { $_ -like 'L|*' } | Select-Object -First 1)
    if (-not $linha) { return $null }
    $c = $linha.Substring(2).TrimEnd().Split('|')
    return [pscustomobject]@{ Cadastro = $c[0]; Status = $c[1]; Senha = $c[2]; Pendencia = $c[3]; Motivo = $c[4]; Por = $c[5]; Ano = $c[6]; Bruto = $linha }
}

function Remove-ContaDeTeste {
    param([string]$Conta)
    if (-not $Conta) { return }
    Invoke-Dba "DROP USER $Conta CASCADE;" | Out-Null
    Invoke-SqlPlus -ConnectString '/ as sysdba' -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDELETE FROM SYS.KAWASHI_CONTA WHERE USERNAME = '$Conta' AND USERNAME LIKE 'TST\_%' ESCAPE '\';`nCOMMIT;`nEXIT;`n" | Out-Null
    foreach ($a in @(@('delete', "auth/userpass/users/$Conta"), @('policy', 'delete', "engineer-$($Conta.ToLower())"),
                     @('kv', 'metadata', 'delete', "kawashi-secrets/onboarding/$Conta"), @('kv', 'metadata', 'delete', "kawashi-secrets/engineers/$Conta"),
                     @('kv', 'metadata', 'delete', "kawashi-secrets/api/$Conta"))) {
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault @a 2>&1 | Out-Null
    }
}

try {
    $pessoa = New-ThrowawayUsername -Prefix 'TST_DSLP'
    $outra  = New-ThrowawayUsername -Prefix 'TST_DSLO'
    $api    = New-ThrowawayUsername -Prefix 'TST_DSLA'
    $comDba = New-ThrowawayUsername -Prefix 'TST_DSLD'
    $admin  = New-ThrowawayUsername -Prefix 'TST_DSLM'

    # --- preparo: uma pessoa com varios tipos de acesso e duas sessoes abertas ------
    & $createTeam -Username $pessoa -Profile 'Desenvolvedor' -Roles @('KAWASHI_READONLY') -Nome 'Pessoa de Teste' -Cargo 'Desenvolvedora' -EnvFile $EnvFile *> $null
    $senha = New-StrongPassword -Length 16 -AvoidSubstring $pessoa
    # Senha definitiva (a temporaria nasce expirada) e uma permissao direta num objeto.
    Invoke-Dba "ALTER USER $pessoa IDENTIFIED BY `"$senha`";`nGRANT SELECT ON KAWASHI_ENV_TESTE_DEV.EMPRESA TO $pessoa;" | Out-Null
    $connDireta = "$pessoa/$senha@//localhost:1521/FREEPDB1"
    $connProxy  = "$pessoa[KAWASHI_ENV_DEV]/$senha@//localhost:1521/FREEPDB1"

    $antesDireta = Test-Login $connDireta
    $antesProxy  = Test-Login $connProxy
    $results += New-TestResult -Name "Precondicao: antes do desligamento a pessoa entra direto e por proxy no ambiente DEV" -Passed (($antesDireta -match "ENTROU=$pessoa") -and ($antesProxy -match 'ENTROU=KAWASHI_ENV_DEV')) -Details "$antesDireta`n$antesProxy"

    $marca = "TSTDSL$(Get-Random -Maximum 99999)"
    Start-SessaoParada $connDireta $marca
    Start-SessaoParada $connProxy $marca
    $sessoesAntes = '0'
    for ($i = 0; $i -lt 15 -and $sessoesAntes -notlike '2:*'; $i++) { Start-Sleep -Seconds 1; $sessoesAntes = Get-SessoesMarcadas $marca }
    $results += New-TestResult -Name "Precondicao: duas sessoes da pessoa estao abertas e paradas, uma direta e uma por proxy (que o Oracle mostra com o nome do ambiente)" -Passed ($sessoesAntes -eq "2:KAWASHI_ENV_DEV,$pessoa") -Details "sessoes=$sessoesAntes"

    # --- o desligamento ------------------------------------------------------------
    $r = Invoke-Script $remove "-Username $pessoa -Motivo 'Fim do contrato de teste'"
    $results += New-TestResult -Name "remove-team-member.ps1 termina com sucesso e diz o que tirou (2 proxies, roles, privilegios, 1 permissao em objeto, 2 sessoes)" -Passed (($r.Codigo -eq 0) -and ($r.Saida -match 'proxies tirados: 2') -and ($r.Saida -match 'permissoes em objetos: 1') -and ($r.Saida -match 'sessoes derrubadas: 2')) -Details "codigo=$($r.Codigo)`n$($r.Saida)"

    $depoisDireta = Test-Login $connDireta
    $depoisProxy  = Test-Login $connProxy
    $results += New-TestResult -Name "Depois: login direto recusado com conta trancada (ORA-28000), mesmo com a senha certa" -Passed (($depoisDireta -match 'ORA-28000') -and ($depoisDireta -notmatch 'ENTROU=')) -Details $depoisDireta
    $results += New-TestResult -Name "Depois: login por proxy no ambiente tambem recusado" -Passed (($depoisProxy -match 'ORA-\d{5}') -and ($depoisProxy -notmatch 'ENTROU=')) -Details $depoisProxy

    $sobra = Invoke-Dba @"
SELECT 'PROXY=' || (SELECT COUNT(*) FROM dba_proxies WHERE proxy = '$pessoa') ||
       ' ROLE=' || (SELECT COUNT(*) FROM dba_role_privs WHERE grantee = '$pessoa') ||
       ' PRIV=' || (SELECT COUNT(*) FROM dba_sys_privs WHERE grantee = '$pessoa') ||
       ' OBJ=' || (SELECT COUNT(*) FROM dba_tab_privs WHERE grantee = '$pessoa') FROM dual;
"@
    $results += New-TestResult -Name "Nenhum acesso sobrou: zero proxies, roles, privilegios de sistema e permissoes em objetos" -Passed ($sobra -match 'PROXY=0 ROLE=0 PRIV=0 OBJ=0') -Details $sobra

    $sessoesDepois = '?'
    for ($i = 0; $i -lt 10 -and $sessoesDepois -notlike '0:*'; $i++) { Start-Sleep -Seconds 1; $sessoesDepois = Get-SessoesMarcadas $marca }
    $results += New-TestResult -Name "As duas sessoes que ja estavam abertas foram derrubadas, inclusive a por proxy (contadas pela marca propria do teste, nao pela busca da procedure)" -Passed ($sessoesDepois -like '0:*') -Details "sessoes=$sessoesDepois"

    $vaultSobra = @()
    foreach ($a in @(@('read', "auth/userpass/users/$pessoa"), @('policy', 'read', "engineer-$($pessoa.ToLower())"), @('kv', 'get', "kawashi-secrets/onboarding/$pessoa"))) {
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault @a 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $vaultSobra += ($a -join ' ') }
    }
    $results += New-TestResult -Name "Vault: login pessoal, policy e senha temporaria da pessoa foram apagados" -Passed ($vaultSobra.Count -eq 0) -Details "sobrou: $($vaultSobra -join '; ')"

    $p = Get-Painel $pessoa
    $results += New-TestResult -Name "Painel: DESLIGADA, com o motivo, quem desligou e quando; sem cobranca de senha e sem pendencia" -Passed (($p.Cadastro -eq 'DESLIGADA') -and ($p.Motivo -eq 'Fim do contrato de teste') -and ($p.Por -ne '-') -and ($p.Ano -match '^\d{4}$') -and ($p.Senha -eq '-') -and ($p.Pendencia -eq '-')) -Details "$($p.Bruto)"

    $lista = Invoke-Script $painel '-Acao Listar'
    $listaTudo = Invoke-Script $painel '-Acao Listar -ComRemovidas'
    $results += New-TestResult -Name "A lista do dia a dia esconde a desligada; com -ComRemovidas ela aparece, com motivo" -Passed (($lista.Saida -notmatch $pessoa) -and ($listaTudo.Saida -match $pessoa) -and ($listaTudo.Saida -match 'Fim do contrato de teste')) -Details "$($lista.Saida)`n----`n$($listaTudo.Saida)"

    # --- alguem tenta devolver o acesso por fora -------------------------------------
    Invoke-Dba "ALTER USER $pessoa ACCOUNT UNLOCK;" | Out-Null
    $aberta = Get-Painel $pessoa
    $alerta = Invoke-Script $painel '-Acao Alertas'
    $results += New-TestResult -Name "Desligada e DESTRANCADA por fora vira alarme no painel e nos alertas (codigo 1)" -Passed (($aberta.Pendencia -match 'DESLIGADA MAS A CONTA ESTA ABERTA') -and ($alerta.Codigo -eq 1) -and ($alerta.Saida -match $pessoa) -and ($alerta.Saida -match 'ALARME')) -Details "$($aberta.Bruto)`n$($alerta.Saida)"
    Invoke-Dba "ALTER USER $pessoa ACCOUNT LOCK;" | Out-Null

    Invoke-Dba "ALTER USER KAWASHI_ENV_DEV GRANT CONNECT THROUGH $pessoa;" | Out-Null
    $comAcesso = Get-Painel $pessoa
    Invoke-Dba "ALTER USER KAWASHI_ENV_DEV REVOKE CONNECT THROUGH $pessoa;" | Out-Null
    $results += New-TestResult -Name "Desligada que recebe um proxy de volta por fora vira alarme (mesmo com a conta trancada)" -Passed ($comAcesso.Pendencia -match 'DESLIGADA MAS AINDA TEM ACESSO') -Details "$($comAcesso.Bruto)"

    $r2 = Invoke-Script $remove "-Username $pessoa -Motivo 'Rodando de novo'"
    $results += New-TestResult -Name "Rodar o desligamento de novo nao da erro (o que ja foi tirado nao falha) e nada sobra" -Passed (($r2.Codigo -eq 0) -and ($r2.Saida -match 'proxies tirados: 0')) -Details "codigo=$($r2.Codigo)`n$($r2.Saida)"

    # --- o que NAO pode ser desligado por aqui ---------------------------------------
    & $createApi -Username $api -Ambiente 'TESTE_INFRA' -EnvFile $EnvFile *> $null
    $rApi = Invoke-Script $remove "-Username $api -Motivo 'Teste de recusa'"
    $apiIntacta = Get-Valor "SELECT 'V=' || account_status || '/' || (SELECT COUNT(*) FROM dba_proxies WHERE proxy = '$api') FROM dba_users WHERE username = '$api';"
    $results += New-TestResult -Name "Conta de API e recusada (ORA-20083) e continua intacta: aberta e com o proxy dela" -Passed (($rApi.Codigo -ne 0) -and ($rApi.Saida -match 'ORA-20083') -and ($apiIntacta -eq 'OPEN/1')) -Details "codigo=$($rApi.Codigo) estado=$apiIntacta`n$($rApi.Saida)"

    $senhaDba = New-StrongPassword -Length 16 -AvoidSubstring $comDba
    Invoke-Dba "CREATE USER $comDba IDENTIFIED BY `"$senhaDba`" PROFILE KAWASHI_SECURE_PROFILE;`nGRANT DBA TO $comDba;" | Out-Null
    $rDba = Invoke-Script $remove "-Username $comDba -Motivo 'Teste de recusa'"
    $dbaIntacta = Get-Valor "SELECT 'V=' || account_status FROM dba_users WHERE username = '$comDba';"
    $results += New-TestResult -Name "Conta com DBA e recusada e continua aberta (administrador nao se desliga por um script do dia a dia)" -Passed (($rDba.Codigo -ne 0) -and ($rDba.Saida -match 'ORA-20083') -and ($dbaIntacta -eq 'OPEN')) -Details "codigo=$($rDba.Codigo) estado=$dbaIntacta`n$($rDba.Saida)"

    $senhaAdm = New-StrongPassword -Length 16 -AvoidSubstring $admin
    Invoke-Dba "CREATE USER $admin IDENTIFIED BY `"$senhaAdm`" PROFILE KAWASHI_SECURE_PROFILE;`nEXEC SYS.KAWASHI_REGISTRAR_CONTA('$admin', 'ADMIN', 'Engenheiro', 'Admin de teste', 'Teste', NULL);" | Out-Null
    $rAdm = Invoke-Script $remove "-Username $admin -Motivo 'Teste de recusa'"
    $results += New-TestResult -Name "Conta cadastrada como ADMIN e recusada, mesmo sem DBA" -Passed (($rAdm.Codigo -ne 0) -and ($rAdm.Saida -match 'ORA-20083')) -Details "codigo=$($rAdm.Codigo)`n$($rAdm.Saida)"

    $rNada = Invoke-Script $remove "-Username TST_NAO_EXISTE_XYZ -Motivo 'Teste de recusa'"
    $results += New-TestResult -Name "Conta que nao existe e recusada (ORA-20080)" -Passed (($rNada.Codigo -ne 0) -and ($rNada.Saida -match 'ORA-20080')) -Details $rNada.Saida

    $recusouMotivo = $false
    try { & $remove -Username $outra -Motivo "x'); DROP USER SYS; --" -EnvFile $EnvFile *> $null } catch { $recusouMotivo = ($_.Exception.Message -match 'Motivo') }
    $results += New-TestResult -Name "Motivo com comando SQL e recusado pela validacao do parametro, antes de chegar ao banco" -Passed $recusouMotivo -Details "recusou=$recusouMotivo"

    # --- -Apagar e recriacao do mesmo nome -------------------------------------------
    & $createTeam -Username $outra -Profile 'EstagiarioDev' -Nome 'Outra Pessoa' -Cargo 'Estagiaria' -EnvFile $EnvFile *> $null
    $rApagar = Invoke-Script $remove "-Username $outra -Motivo 'Fim do estagio' -Apagar"
    $existe = Get-Valor "SELECT 'V=' || COUNT(*) FROM dba_users WHERE username = '$outra';"
    $pa = Get-Painel $outra
    $results += New-TestResult -Name "-Apagar: a conta some do banco, mas o cadastro fica como DESLIGADA (historico de quem teve acesso), sem pendencia" -Passed (($rApagar.Codigo -eq 0) -and ($existe -eq '0') -and ($pa.Cadastro -eq 'DESLIGADA') -and ($pa.Pendencia -eq '-')) -Details "codigo=$($rApagar.Codigo) existe=$existe $($pa.Bruto)`n$($rApagar.Saida)"

    Start-Sleep -Seconds 1
    & $createTeam -Username $outra -Profile 'EstagiarioDev' -Nome 'Outra Pessoa' -Cargo 'Estagiaria' -EnvFile $EnvFile *> $null
    $pr = Get-Painel $outra
    $results += New-TestResult -Name "O mesmo nome recriado depois do desligamento e outra conta: volta como OK, sem o desligamento antigo" -Passed (($pr.Cadastro -eq 'OK') -and ($pr.Motivo -eq '-')) -Details "$($pr.Bruto)"
}
finally {
    Write-Host "-> Limpando: sessoes do teste, contas descartaveis, cadastro e Vault..."
    if ($marca) {
        Invoke-SqlPlus -ConnectString '/ as sysdba' -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nBEGIN FOR s IN (SELECT sid, serial# sr FROM v`$session WHERE module = '$marca') LOOP EXECUTE IMMEDIATE 'ALTER SYSTEM KILL SESSION ''' || s.sid || ',' || s.sr || ''' IMMEDIATE'; END LOOP; END;`n/`nEXIT;`n" | Out-Null
    }
    foreach ($u in @($pessoa, $outra, $api, $comDba, $admin)) { Remove-ContaDeTeste $u }
    $sobrou = Get-Valor "SELECT 'V=' || ((SELECT COUNT(*) FROM dba_users WHERE username IN ('$pessoa', '$outra', '$api', '$comDba', '$admin')) + (SELECT COUNT(*) FROM SYS.V_KAWASHI_CONTAS WHERE USERNAME IN ('$pessoa', '$outra', '$api', '$comDba', '$admin'))) FROM dual;"
    $results += New-TestResult -Name "Depois da limpeza nao sobra conta nem cadastro do teste" -Passed ($sobrou -eq '0') -Details "sobrou=$sobrou"
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
