# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA (seguranca): confirma, na pratica, que um usuario SEM
    o privilegio de sistema correspondente REALMENTE NAO CONSEGUE rodar
    CREATE TRIGGER / CREATE PROCEDURE / CREATE SEQUENCE / CREATE VIEW / CREATE
    TABLE - para cada perfil/role do projeto, nao so verifica que o catalogo
    diz que falta o privilegio (isso ja e feito, de caixa-branca, em
    Test-RolesPrivilegiosInternos.ps1).

.DESCRIPTION
    Faltava justamente isto: todos os testes anteriores de "fulano nao
    consegue criar X" tinham testado CREATE TABLE (varias vezes) e, no maximo,
    DML (INSERT/UPDATE/DELETE) - nunca CREATE TRIGGER, CREATE PROCEDURE ou
    CREATE SEQUENCE isoladamente. Tambem nunca tinha sido testada a fronteira
    exata de ROLE_KAWASHI_DEVELOPER (ver 01_setup_kawashi.sql): essa role da
    CREATE TABLE e CREATE VIEW, mas NAO da CREATE SEQUENCE/PROCEDURE/TRIGGER -
    um desenvolvedor com so essa role pode ficar surpreso ao descobrir que
    nao consegue criar uma trigger de auditoria na propria tabela que acabou
    de criar.

    CREATE TRIGGER precisa de uma tabela EXISTENTE pra apontar (senao o Oracle
    reclama "table does not exist" antes mesmo de checar o privilegio de
    trigger, mascarando o que estamos testando) - por isso o ENGINEER_USER
    pre-cria uma tabelinha "fixture" no PROPRIO schema de cada usuario de
    teste (um DBA pode criar objetos no schema de outro usuario), garantindo
    que exista algo pra apontar independente do usuario ter ou nao CREATE
    TABLE.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [CAIXA-PRETA/SEGURANCA] CREATE TRIGGER/PROCEDURE/SEQUENCE/VIEW/TABLE por perfil ==" -ForegroundColor Cyan

$createScript = Join-Path $PSScriptRoot '..\..\scripts\create-team-member.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken = Get-VaultToken -EnvFile $EnvFile
$results = @()
$usuariosParaLimpar = @()
$proxyGrantsParaLimpar = @()

function New-UsuarioComFixture {
    param([string]$Username, [string[]]$RolesExtras = @())
    $senha = New-StrongPassword -Length 16 -AvoidSubstring $Username
    $grantsExtras = ($RolesExtras | ForEach-Object { "GRANT $_ TO $Username;" }) -join "`n"
    Invoke-SqlPlus -ConnectString $engineerConn -Sql @"
ALTER SESSION SET CONTAINER = FREEPDB1;
CREATE USER $Username IDENTIFIED BY "$senha" PROFILE KAWASHI_SECURE_PROFILE DEFAULT TABLESPACE TS_KAWASHI_DATA;
ALTER USER $Username QUOTA 10M ON TS_KAWASHI_DATA;
GRANT CREATE SESSION TO $Username;
$grantsExtras
CREATE TABLE $Username.FIXTURE_TBL (id NUMBER);
EXIT;
"@ | Out-Null
    return $senha
}

function Test-CriacaoObjetos {
    param([string]$Rotulo, [string]$ConnectString, [hashtable]$Esperado, [string[]]$Sufixo = @())
    # $Esperado: @{ TABLE=$true/$false; VIEW=...; SEQUENCE=...; PROCEDURE=...; TRIGGER=... }
    $marcador = (New-ThrowawayUsername -Prefix '').TrimStart('_')

    $outTable = (Invoke-SqlPlus -ConnectString $ConnectString -Sql "CREATE TABLE TBL_$marcador (id NUMBER);`nEXIT;`n") -join "`n"
    $passouTable = if ($Esperado.TABLE) { $outTable -match 'Table created' } else { $outTable -match 'ORA-01031' }
    $script:results += New-TestResult -Name "[$Rotulo] CREATE TABLE $(if ($Esperado.TABLE) {'e permitido'} else {'e BLOQUEADO (ORA-01031)'})" -Passed $passouTable -Details $(if (-not $passouTable) { $outTable })

    $outView = (Invoke-SqlPlus -ConnectString $ConnectString -Sql "CREATE VIEW VW_$marcador AS SELECT 1 AS x FROM DUAL;`nEXIT;`n") -join "`n"
    $passouView = if ($Esperado.VIEW) { $outView -match 'View created' } else { $outView -match 'ORA-01031' }
    $script:results += New-TestResult -Name "[$Rotulo] CREATE VIEW $(if ($Esperado.VIEW) {'e permitido'} else {'e BLOQUEADO (ORA-01031)'})" -Passed $passouView -Details $(if (-not $passouView) { $outView })

    $outSeq = (Invoke-SqlPlus -ConnectString $ConnectString -Sql "CREATE SEQUENCE SEQ_$marcador;`nEXIT;`n") -join "`n"
    $passouSeq = if ($Esperado.SEQUENCE) { $outSeq -match 'Sequence created' } else { $outSeq -match 'ORA-01031' }
    $script:results += New-TestResult -Name "[$Rotulo] CREATE SEQUENCE $(if ($Esperado.SEQUENCE) {'e permitido'} else {'e BLOQUEADO (ORA-01031)'})" -Passed $passouSeq -Details $(if (-not $passouSeq) { $outSeq })

    $outProc = (Invoke-SqlPlus -ConnectString $ConnectString -Sql "CREATE OR REPLACE PROCEDURE PROC_$marcador AS BEGIN NULL; END;`n/`nEXIT;`n") -join "`n"
    $passouProc = if ($Esperado.PROCEDURE) { $outProc -match 'Procedure created' } else { $outProc -match 'ORA-01031' }
    $script:results += New-TestResult -Name "[$Rotulo] CREATE PROCEDURE $(if ($Esperado.PROCEDURE) {'e permitido'} else {'e BLOQUEADO (ORA-01031)'})" -Passed $passouProc -Details $(if (-not $passouProc) { $outProc })

    # CREATE TRIGGER aponta pra FIXTURE_TBL (pre-criada pelo ENGINEER_USER no
    # proprio schema do usuario de teste) ou, no controle positivo proxyado,
    # pra tabela que o proprio usuario acabou de criar no passo acima.
    $tabelaAlvo = if ($Esperado.TABLE) { "TBL_$marcador" } else { 'FIXTURE_TBL' }
    $outTrg = (Invoke-SqlPlus -ConnectString $ConnectString -Sql "CREATE OR REPLACE TRIGGER TRG_$marcador BEFORE INSERT ON $tabelaAlvo BEGIN NULL; END;`n/`nEXIT;`n") -join "`n"
    $passouTrg = if ($Esperado.TRIGGER) { $outTrg -match 'Trigger created' } else { $outTrg -match 'ORA-01031' }
    $script:results += New-TestResult -Name "[$Rotulo] CREATE TRIGGER $(if ($Esperado.TRIGGER) {'e permitido'} else {'e BLOQUEADO (ORA-01031)'})" -Passed $passouTrg -Details $(if (-not $passouTrg) { $outTrg })
}

try {
    # --- 1. Estagiario direto (sem proxy, sem role extra) - tudo bloqueado ---
    $estagiario = New-ThrowawayUsername -Prefix 'TST_BLK_ESTA'
    $usuariosParaLimpar += $estagiario
    $senhaEstagiario = New-UsuarioComFixture -Username $estagiario
    Test-CriacaoObjetos -Rotulo 'Estagiario direto' -ConnectString "$estagiario/$senhaEstagiario@//localhost:1521/FREEPDB1" -Esperado @{ TABLE=$false; VIEW=$false; SEQUENCE=$false; PROCEDURE=$false; TRIGGER=$false }

    # --- 2. Infra direto (SELECT ANY DICTIONARY nao e DDL - tudo bloqueado) --
    $infra = New-ThrowawayUsername -Prefix 'TST_BLK_INFR'
    $usuariosParaLimpar += $infra
    $senhaInfra = New-UsuarioComFixture -Username $infra -RolesExtras @('ROLE_KAWASHI_INFRA')
    Test-CriacaoObjetos -Rotulo 'Infra direto' -ConnectString "$infra/$senhaInfra@//localhost:1521/FREEPDB1" -Esperado @{ TABLE=$false; VIEW=$false; SEQUENCE=$false; PROCEDURE=$false; TRIGGER=$false }

    # --- 3. HomologViewer direto (so leitura via role - tudo bloqueado) ------
    $homolog = New-ThrowawayUsername -Prefix 'TST_BLK_HOMO'
    $usuariosParaLimpar += $homolog
    $senhaHomolog = New-UsuarioComFixture -Username $homolog -RolesExtras @('ROLE_KAWASHI_HOMOLOG_VIEWER')
    Test-CriacaoObjetos -Rotulo 'HomologViewer direto' -ConnectString "$homolog/$senhaHomolog@//localhost:1521/FREEPDB1" -Esperado @{ TABLE=$false; VIEW=$false; SEQUENCE=$false; PROCEDURE=$false; TRIGGER=$false }

    # --- 4. SO ROLE_KAWASHI_DEVELOPER - fronteira exata nunca testada antes --
    # TABLE/VIEW permitidos, SEQUENCE/PROCEDURE/TRIGGER bloqueados (ver
    # 01_setup_kawashi.sql - a role nao inclui esses tres).
    $developer = New-ThrowawayUsername -Prefix 'TST_BLK_DEV'
    $usuariosParaLimpar += $developer
    $senhaDeveloper = New-UsuarioComFixture -Username $developer -RolesExtras @('ROLE_KAWASHI_DEVELOPER')
    Test-CriacaoObjetos -Rotulo 'Apenas ROLE_KAWASHI_DEVELOPER' -ConnectString "$developer/$senhaDeveloper@//localhost:1521/FREEPDB1" -Esperado @{ TABLE=$true; VIEW=$true; SEQUENCE=$false; PROCEDURE=$false; TRIGGER=$false }

    # --- 5. Controle positivo: Desenvolvedor proxyado em DEV - tudo permitido -
    $devProxy = New-ThrowawayUsername -Prefix 'TST_BLK_PROXY'
    $usuariosParaLimpar += $devProxy
    & $createScript -Username $devProxy -Profile 'Desenvolvedor' -EnvFile $EnvFile *> $null
    $senhaDevProxy = New-StrongPassword -Length 16 -AvoidSubstring $devProxy
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nALTER USER $devProxy IDENTIFIED BY `"$senhaDevProxy`";`nEXIT;`n" | Out-Null
    Test-CriacaoObjetos -Rotulo '(controle positivo) Desenvolvedor proxyado em DEV' -ConnectString "$devProxy[KAWASHI_ENV_DEV]/$senhaDevProxy@//localhost:1521/FREEPDB1" -Esperado @{ TABLE=$true; VIEW=$true; SEQUENCE=$true; PROCEDURE=$true; TRIGGER=$true }
}
finally {
    Write-Host "-> Limpando usuarios descartaveis, fixtures e artefatos no Vault..."
    foreach ($u in $usuariosParaLimpar) {
        Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $u CASCADE;`nEXIT;`n" | Out-Null
        $policyName = "engineer-$($u.ToLower())"
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault policy delete $policyName 2>&1 | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault delete "auth/userpass/users/$u" 2>&1 | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv delete "kawashi-secrets/onboarding/$u" 2>&1 | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv delete "kawashi-secrets/engineers/$u" 2>&1 | Out-Null
    }
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
