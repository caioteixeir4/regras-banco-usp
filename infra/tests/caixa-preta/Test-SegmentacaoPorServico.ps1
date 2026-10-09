# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: confirma que a segmentacao por servico (padrao +
    SEFAZ + SIMPLES_NACIONAL, ver secao 2.1 de infra/oracle-init/09_environments.sql
    e infra/oracle-init/11_exemplo_dominio_negocio.sql) funciona de ponta a
    ponta: sem -Servicos ninguem enxerga o schema de servico; com -Servicos
    SEFAZ a pessoa consegue ler/escrever no servico E fazer JOIN com a tabela
    padrao via FK; e a liberacao e ESTRITAMENTE por servico, nao "tudo ou
    nada" (ter SEFAZ nao da SIMPLES_NACIONAL de brinde).

.DESCRIPTION
    ACHADO REAL testando isto pela primeira vez (ver item correspondente de
    bugs-primeiro-teste.md): o GRANT REFERENCES (que 09_environments.sql por
    si so nao concede - so o INIT de exemplo faz) habilita CRIAR a foreign
    key, mas NAO da privilegio de LEITURA nenhum - um SELECT com JOIN contra a
    tabela padrao falhava com "ORA-41900: missing READ privilege" mesmo com a
    FK funcionando. Corrigido concedendo GRANT SELECT nas tabelas padrao para
    o schema de servico, alem do REFERENCES.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [CAIXA-PRETA] Segmentacao por servico (padrao + SEFAZ + SIMPLES_NACIONAL) ==" -ForegroundColor Cyan

$createScript = Join-Path $PSScriptRoot '..\..\scripts\create-team-member.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$VaultToken = Get-VaultToken -EnvFile $EnvFile
$results = @()
$usuariosParaLimpar = @()
$cnpjTeste = '12345678000199'

function Get-SenhaDefinitiva {
    param([string]$Username)
    $senha = New-StrongPassword -Length 16 -AvoidSubstring $Username
    $out = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nALTER USER $Username IDENTIFIED BY `"$senha`";`nEXIT;`n") -join "`n"
    if ($out -match 'ORA-\d{5}') { throw "Falha definindo senha definitiva de '$Username':`n$out" }
    return $senha
}

try {
    Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nINSERT INTO KAWASHI_ENV_DEV.CLIENTE (CNPJ, RAZAO_SOCIAL) VALUES ('$cnpjTeste', 'Empresa Teste LTDA');`nCOMMIT;`nEXIT;`n" | Out-Null

    $devSemServico = New-ThrowawayUsername -Prefix 'TST_SEGSEM'
    $usuariosParaLimpar += $devSemServico
    & $createScript -Username $devSemServico -Profile 'Desenvolvedor' -EnvFile $EnvFile *> $null
    $senhaSem = Get-SenhaDefinitiva -Username $devSemServico

    $devComSefaz = New-ThrowawayUsername -Prefix 'TST_SEGSEFAZ'
    $usuariosParaLimpar += $devComSefaz
    & $createScript -Username $devComSefaz -Profile 'Desenvolvedor' -Servicos SEFAZ -EnvFile $EnvFile *> $null
    $senhaCom = Get-SenhaDefinitiva -Username $devComSefaz

    # --- Sem -Servicos, o schema de servico nem aceita o login via proxy -----
    $outSemServico = (Invoke-SqlPlus -ConnectString "$devSemServico[KAWASHI_ENV_DEV_SEFAZ]/$senhaSem@//localhost:1521/FREEPDB1" -Sql "SELECT 1 FROM DUAL;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "Desenvolvedor SEM -Servicos NAO consegue proxy em KAWASHI_ENV_DEV_SEFAZ" -Passed ($outSemServico -match 'ORA-01017') -Details $(if ($outSemServico -notmatch 'ORA-01017') { $outSemServico })

    # --- Com -Servicos SEFAZ: INSERT no servico + JOIN com a tabela padrao ---
    $sqlServico = @"
ALTER SESSION SET CONTAINER = FREEPDB1;
INSERT INTO CONFIGURACAO_FISCAL (CLIENTE_ID, REGIME_TRIBUTARIO) SELECT ID, 'SIMPLES' FROM KAWASHI_ENV_DEV.CLIENTE WHERE CNPJ = '$cnpjTeste';
COMMIT;
SELECT c.RAZAO_SOCIAL || '|' || cf.REGIME_TRIBUTARIO AS RESULTADO FROM CONFIGURACAO_FISCAL cf JOIN KAWASHI_ENV_DEV.CLIENTE c ON c.ID = cf.CLIENTE_ID WHERE c.CNPJ = '$cnpjTeste';
EXIT;
"@
    $outComServico = (Invoke-SqlPlus -ConnectString "$devComSefaz[KAWASHI_ENV_DEV_SEFAZ]/$senhaCom@//localhost:1521/FREEPDB1" -Sql $sqlServico) -join "`n"
    $results += New-TestResult -Name "Desenvolvedor COM -Servicos SEFAZ consegue INSERT na tabela de servico com FK pra tabela padrao" -Passed ($outComServico -match '1 row created') -Details $(if ($outComServico -notmatch '1 row created') { $outComServico })
    $results += New-TestResult -Name "Mesmo Desenvolvedor consegue SELECT com JOIN entre servico (CONFIGURACAO_FISCAL) e padrao (CLIENTE)" -Passed ($outComServico -match 'Empresa Teste LTDA\|SIMPLES') -Details $(if ($outComServico -notmatch 'Empresa Teste LTDA\|SIMPLES') { $outComServico })

    # --- Liberacao e POR SERVICO, nao tudo-ou-nada -----------------------------
    $outSimples = (Invoke-SqlPlus -ConnectString "$devComSefaz[KAWASHI_ENV_DEV_SIMPLES_NACIONAL]/$senhaCom@//localhost:1521/FREEPDB1" -Sql "SELECT 1 FROM DUAL;`nEXIT;`n") -join "`n"
    $results += New-TestResult -Name "O MESMO Desenvolvedor (com SEFAZ) continua SEM acesso a KAWASHI_ENV_DEV_SIMPLES_NACIONAL (liberacao nao e tudo-ou-nada)" -Passed ($outSimples -match 'ORA-01017') -Details $(if ($outSimples -notmatch 'ORA-01017') { $outSimples })
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
