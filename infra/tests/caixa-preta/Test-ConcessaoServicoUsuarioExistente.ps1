# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: confirma que infra/scripts/grant-service-access.ps1
    concede acesso a um schema de servico (SEFAZ/SIMPLES_NACIONAL) a um usuario
    QUE JA EXISTE, sem precisar recriar a conta - caso que create-team-member.ps1
    sozinho nao cobre (rodar de novo com o mesmo -Username la falha com
    ORA-01920 antes de chegar em -Servicos).

.DESCRIPTION
    Pedido explicito do usuario: por padrao um perfil deve enxergar so as
    tabelas PADRAO; servico adicional pode ser concedido separadamente ou
    depois, pra qualquer perfil, sem problema - mas sempre de forma EXPLICITA
    (nunca automatica). Este teste confirma as duas pontas: (1) sem rodar o
    script novo, o usuario continua sem nenhum servico extra; (2) depois de
    rodar, ele enxerga SO o servico pedido, nos ambientes que ja alcancava -
    descobertos via DBA_PROXIES (fonte da verdade), nao perguntados de volta.
    Cobre tambem os dois casos de erro (usuario inexistente, perfil sem
    nenhum ambiente via proxy) e a idempotencia de rodar o script duas vezes
    com o mesmo servico.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')

Write-Host "== [CAIXA-PRETA] Concessao de servico a usuario existente (grant-service-access.ps1) ==" -ForegroundColor Cyan

$createScript = Join-Path $PSScriptRoot '..\..\scripts\create-team-member.ps1'
$grantScript  = Join-Path $PSScriptRoot '..\..\scripts\grant-service-access.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken = Get-VaultToken -EnvFile $EnvFile
$results = @()
$usuariosParaLimpar = @()
$cnpjTeste = '98765432000188'

function Get-SenhaDefinitiva {
    param([string]$Username)
    $senha = New-StrongPassword -Length 16 -AvoidSubstring $Username
    $out = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nALTER USER $Username IDENTIFIED BY `"$senha`";`nEXIT;`n") -join "`n"
    if ($out -match 'ORA-\d{5}') { throw "Falha definindo senha definitiva de '$Username':`n$out" }
    return $senha
}

try {
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nINSERT INTO KAWASHI_ENV_DEV.CLIENTE (CNPJ, RAZAO_SOCIAL) VALUES ('$cnpjTeste', 'Empresa Grant Depois LTDA');`nCOMMIT;`nEXIT;`n" | Out-Null

    # --- usuario criado SEM nenhum servico --------------------------------------
    $dev = New-ThrowawayUsername -Prefix 'TST_GRANTDEPOIS'
    $usuariosParaLimpar += $dev
    & $createScript -Username $dev -Profile 'Desenvolvedor' -EnvFile $EnvFile *> $null
    $senha = Get-SenhaDefinitiva -Username $dev

    $outAntes = (Invoke-SqlPlus -ConnectString "$dev[KAWASHI_ENV_DEV_SEFAZ]/$senha@//localhost:1521/FREEPDB1" -Sql "SELECT 1 FROM DUAL;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Antes de rodar grant-service-access.ps1, usuario criado sem -Servicos NAO alcanca KAWASHI_ENV_DEV_SEFAZ" -Passed ($outAntes -match 'ORA-01017') -Details $(if ($outAntes -notmatch 'ORA-01017') { $outAntes })

    # --- concede SEFAZ depois, pro usuario ja existente -------------------------
    & $grantScript -Username $dev -Servicos SEFAZ -EnvFile $EnvFile *> $null

    $sqlServico = @"
ALTER SESSION SET CONTAINER = FREEPDB1;
INSERT INTO CONFIGURACAO_FISCAL (CLIENTE_ID, REGIME_TRIBUTARIO) SELECT ID, 'LUCRO_PRESUMIDO' FROM KAWASHI_ENV_DEV.CLIENTE WHERE CNPJ = '$cnpjTeste';
COMMIT;
SELECT c.RAZAO_SOCIAL || '|' || cf.REGIME_TRIBUTARIO AS RESULTADO FROM CONFIGURACAO_FISCAL cf JOIN KAWASHI_ENV_DEV.CLIENTE c ON c.ID = cf.CLIENTE_ID WHERE c.CNPJ = '$cnpjTeste';
EXIT;
"@
    $outDepois = (Invoke-SqlPlus -ConnectString "$dev[KAWASHI_ENV_DEV_SEFAZ]/$senha@//localhost:1521/FREEPDB1" -Sql $sqlServico) -join "`n"
    $results += New-TestResult -Name "Depois de rodar grant-service-access.ps1 -Servicos SEFAZ, o MESMO usuario (mesma senha) consegue INSERT + JOIN entre servico e padrao" -Passed ($outDepois -match 'Empresa Grant Depois LTDA\|LUCRO_PRESUMIDO') -Details $(if ($outDepois -notmatch 'Empresa Grant Depois LTDA\|LUCRO_PRESUMIDO') { $outDepois })

    # --- continua sem SIMPLES_NACIONAL (liberacao e por servico, nao em bloco) --
    $outSimples = (Invoke-SqlPlus -ConnectString "$dev[KAWASHI_ENV_DEV_SIMPLES_NACIONAL]/$senha@//localhost:1521/FREEPDB1" -Sql "SELECT 1 FROM DUAL;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Mesmo usuario continua SEM acesso a KAWASHI_ENV_DEV_SIMPLES_NACIONAL (so SEFAZ foi concedido)" -Passed ($outSimples -match 'ORA-01017') -Details $(if ($outSimples -notmatch 'ORA-01017') { $outSimples })

    # --- idempotente: rodar de novo com o mesmo servico nao quebra --------------
    $idempotenteOk = $true
    $idempotenteDetalhe = ''
    try { & $grantScript -Username $dev -Servicos SEFAZ -EnvFile $EnvFile *> $null } catch { $idempotenteOk = $false; $idempotenteDetalhe = $_.Exception.Message }
    $results += New-TestResult -Name "Rodar grant-service-access.ps1 de novo com um servico ja concedido NAO da erro (idempotente)" -Passed $idempotenteOk -Details $idempotenteDetalhe

    # --- perfil Infra: confirma que concede em TODOS os ambientes que alcanca ---
    $infra = New-ThrowawayUsername -Prefix 'TST_GRANTINFRA'
    $usuariosParaLimpar += $infra
    & $createScript -Username $infra -Profile 'Infra' -EnvFile $EnvFile *> $null
    & $grantScript -Username $infra -Servicos SEFAZ -EnvFile $EnvFile *> $null
    $outProxiesInfra = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "SET PAGESIZE 0`nSET FEEDBACK OFF`nSELECT client FROM dba_proxies WHERE proxy = '$infra' AND client LIKE '%\_SEFAZ' ESCAPE '\';`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Perfil Infra: grant-service-access.ps1 concede SEFAZ em TODOS os ambientes que o usuario ja alcanca (INFRA e HOMOLOG), nao so um" -Passed ($outProxiesInfra -match 'KAWASHI_ENV_INFRA_SEFAZ' -and $outProxiesInfra -match 'KAWASHI_ENV_HOMOLOG_SEFAZ') -Details $(if (-not ($outProxiesInfra -match 'KAWASHI_ENV_INFRA_SEFAZ' -and $outProxiesInfra -match 'KAWASHI_ENV_HOMOLOG_SEFAZ')) { $outProxiesInfra })

    # --- usuario inexistente: erro claro, nunca tenta adivinhar/conceder -------
    $erroInexistente = $false
    try { & $grantScript -Username 'TST_NAO_EXISTE_XYZ' -Servicos SEFAZ -EnvFile $EnvFile *> $null }
    catch { $erroInexistente = ($_.Exception.Message -match 'nao existe') }
    $results += New-TestResult -Name "Usuario inexistente: grant-service-access.ps1 lanca erro claro, nao tenta conceder nada" -Passed $erroInexistente

    # --- HomologViewer: sem proxy em nenhum ambiente, -Servicos nao se aplica ---
    $qa = New-ThrowawayUsername -Prefix 'TST_GRANTQA'
    $usuariosParaLimpar += $qa
    & $createScript -Username $qa -Profile 'HomologViewer' -EnvFile $EnvFile *> $null
    $erroHomologViewer = $false
    try { & $grantScript -Username $qa -Servicos SEFAZ -EnvFile $EnvFile *> $null }
    catch { $erroHomologViewer = ($_.Exception.Message -match 'nao tem proxy em nenhum ambiente') }
    $results += New-TestResult -Name "HomologViewer (sem proxy em nenhum ambiente): -Servicos lanca erro claro, nao concede nada" -Passed $erroHomologViewer
}
finally {
    Write-Host "-> Limpando dados de exemplo, usuarios descartaveis e artefatos no Vault..."
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDELETE FROM KAWASHI_ENV_DEV_SEFAZ.CONFIGURACAO_FISCAL WHERE CLIENTE_ID IN (SELECT ID FROM KAWASHI_ENV_DEV.CLIENTE WHERE CNPJ = '$cnpjTeste');`nDELETE FROM KAWASHI_ENV_DEV.CLIENTE WHERE CNPJ = '$cnpjTeste';`nCOMMIT;`nEXIT;`n" | Out-Null
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
