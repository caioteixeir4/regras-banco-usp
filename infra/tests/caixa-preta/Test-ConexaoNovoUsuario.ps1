# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: valida a CONEXAO DIRETA (sem proxy) de um usuario
    recem-criado por infra/scripts/create-team-member.ps1, para cada um dos 4
    perfis - antes de qualquer coisa de proxy/ambiente, a pessoa precisa
    conseguir logar como ela mesma.

.DESCRIPTION
    Para cada perfil, cria um usuario descartavel real, e observa apenas o
    resultado do login (aceito ou negado) - nunca consulta DBA_USERS nem
    nenhum catalogo. Confere tres coisas por usuario:
      1. Login com a senha correta funciona e a sessao se identifica como o
         usuario certo (SYS_CONTEXT('USERENV','SESSION_USER')).
      2. Login com senha errada e negado (ORA-01017).
      3. Login com usuario inexistente (variacao do nome) e negado do mesmo jeito -
         o Oracle nao deve "vazar" se o problema foi usuario ou senha.

.NOTES
    Esta troca de senha (temporaria -> definitiva) e feita aqui via ALTER USER
    pelo ENGINEER_USER, no lugar do fluxo interativo real de primeiro-login.
    Tentamos reproduzir o fluxo interativo de verdade (sqlplus perguntando
    "New password" / "Retype new password" via stdin) e confirmamos de novo o
    limite ja documentado no item 4 de infra/docs/bugs-primeiro-teste.md:
    "SP2-0650: New passwords do not match" mesmo enviando a mesma senha duas
    vezes - o prompt de troca de senha do sqlplus nao e respondivel de forma
    confiavel via stdin nao-interativo neste ambiente. Como o alvo deste teste
    e a CONEXAO em si (nao a UX de troca de senha), usar ALTER USER como fixture
    e uma escolha deliberada, nao uma lacuna de cobertura.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "== [CAIXA-PRETA] Conexao direta de usuario recem-criado, por perfil ==" -ForegroundColor Cyan

$createScript = Join-Path $PSScriptRoot '..\..\scripts\create-team-member.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$perfis = 'EstagiarioDev', 'EstagiarioInfra', 'Desenvolvedor', 'Infra', 'HomologViewer'
$results = @()
$createdUsers = @()

try {
    foreach ($profile in $perfis) {
        $username = New-ThrowawayUsername -Prefix "TST_CONN_$($profile.ToUpper().Substring(0, [Math]::Min(4, $profile.Length)))"
        Write-Host "-> Criando usuario descartavel '$username' (perfil $profile)..."
        $createdUsers += [PSCustomObject]@{ Username = $username; Profile = $profile }
        & $createScript -Username $username -Profile $profile -EnvFile $EnvFile *> $null

        $senhaDefinitiva = New-StrongPassword -Length 16 -AvoidSubstring $username
        $outTroca = (Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nALTER USER $username IDENTIFIED BY `"$senhaDefinitiva`";`nEXIT;`n") -join "`n"
        if ($outTroca -match 'ORA-\d{5}') { throw "Falha definindo senha definitiva de '$username':`n$outTroca" }

        $outOk = (Invoke-SqlPlus -ConnectString "$username/$senhaDefinitiva@//localhost:1521/FREEPDB1" -Sql "SELECT SYS_CONTEXT('USERENV','SESSION_USER') FROM DUAL;`nEXIT;`n") -join "`n"
        $loginOk = ($outOk -match [regex]::Escape($username)) -and ($outOk -notmatch 'ORA-\d{5}')
        $results += New-TestResult -Name "[$profile] Login direto com senha correta funciona e se identifica como '$username'" -Passed $loginOk -Details $(if (-not $loginOk) { $outOk })

        $outSenhaErrada = (Invoke-SqlPlus -ConnectString "$username/SenhaTotalmenteErrada1!@//localhost:1521/FREEPDB1" -Sql "EXIT;") -join "`n"
        $negouSenha = $outSenhaErrada -match 'ORA-01017'
        $results += New-TestResult -Name "[$profile] Login com senha errada e negado (ORA-01017)" -Passed $negouSenha -Details $(if (-not $negouSenha) { $outSenhaErrada })

        $outUsuarioInexistente = (Invoke-SqlPlus -ConnectString "${username}_NAO_EXISTE/$senhaDefinitiva@//localhost:1521/FREEPDB1" -Sql "EXIT;") -join "`n"
        $negouInexistente = $outUsuarioInexistente -match 'ORA-01017'
        $results += New-TestResult -Name "[$profile] Login com usuario inexistente da o MESMO erro generico (nao vaza se o problema foi usuario ou senha)" -Passed $negouInexistente -Details $(if (-not $negouInexistente) { $outUsuarioInexistente })
    }
}
finally {
    Write-Host "-> Limpando usuarios descartaveis e artefatos no Vault..."
    $VaultToken = Get-VaultToken -EnvFile $EnvFile
    foreach ($u in $createdUsers) {
        Invoke-SqlPlus -ConnectString $engineerConn -Sql "ALTER SESSION SET CONTAINER = FREEPDB1;`nDROP USER $($u.Username) CASCADE;`nEXIT;`n" | Out-Null
        $policyName = "engineer-$($u.Username.ToLower())"
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault policy delete $policyName 2>&1 | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault delete "auth/userpass/users/$($u.Username)" 2>&1 | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv delete "kawashi-secrets/onboarding/$($u.Username)" 2>&1 | Out-Null
        docker exec -e VAULT_TOKEN=$VaultToken kawashi-vault vault kv delete "kawashi-secrets/engineers/$($u.Username)" 2>&1 | Out-Null
    }
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
