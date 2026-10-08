# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Funcoes compartilhadas pelos scripts de teste em infra/tests/*.

.DESCRIPTION
    Reaproveita o padrao de Invoke-SqlPlus ja validado (e debugado ao vivo) em
    infra/scripts/*.ps1: SQL enviado como BASE64 num argumento de linha de
    comando em vez de pipe, para nao esbarrar no bug do PowerShell 5.1 que
    insere um BOM UTF-8 em qualquer conteudo mandado via "|" para um processo
    externo (sqlplus rejeita isso com SP2-0734). Ver infra/docs/bugs-primeiro-teste.md.
#>

function Get-DotEnv {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Arquivo .env nao encontrado em '$Path'."
    }
    $map = @{}
    foreach ($line in Get-Content $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $parts = $trimmed.Split('=', 2)
        if ($parts.Count -eq 2) { $map[$parts[0].Trim()] = $parts[1].Trim() }
    }
    return $map
}

function Get-EngineerCredentials {
    param([string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env'))
    $envMap = Get-DotEnv -Path $EnvFile
    foreach ($key in 'ENGINEER_USER', 'ENGINEER_USER_PASSWORD') {
        if (-not $envMap.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($envMap[$key])) {
            throw "Variavel '$key' ausente ou vazia em $EnvFile."
        }
    }
    return [PSCustomObject]@{ User = $envMap['ENGINEER_USER']; Password = $envMap['ENGINEER_USER_PASSWORD'] }
}

function Get-EngineerConnectString {
    param([string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env'))
    $cred = Get-EngineerCredentials -EnvFile $EnvFile
    return "$($cred.User)/$($cred.Password)@//localhost:1521/FREEPDB1"
}

function Get-SpringAppCredentials {
    param([string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env'))
    $envMap = Get-DotEnv -Path $EnvFile
    foreach ($key in 'SPRING_APP_USER', 'SPRING_APP_USER_PASSWORD') {
        if (-not $envMap.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($envMap[$key])) {
            throw "Variavel '$key' ausente ou vazia em $EnvFile."
        }
    }
    return [PSCustomObject]@{ User = $envMap['SPRING_APP_USER']; Password = $envMap['SPRING_APP_USER_PASSWORD'] }
}

function Get-SpringAppConnectString {
    param([string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env'))
    $cred = Get-SpringAppCredentials -EnvFile $EnvFile
    return "$($cred.User)/$($cred.Password)@//localhost:1521/FREEPDB1"
}

function Get-SystemConnectString {
    # SYSTEM, diferente de "/ as sysdba", e uma conexao NORMAL (comum,
    # sujeita aos triggers de banco como AFTER LOGON) - util pra testar a
    # isencao documentada em KAWASHI_CONTEXT_SECURITY_TRG pra SYS/SYSTEM sem
    # precisar de uma conexao SYSDBA (que o Oracle autentica por um caminho
    # que nao dispara triggers de usuario).
    param([string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env'))
    $envMap = Get-DotEnv -Path $EnvFile
    if (-not $envMap.ContainsKey('ORACLE_PASSWORD') -or [string]::IsNullOrWhiteSpace($envMap['ORACLE_PASSWORD'])) {
        throw "Variavel 'ORACLE_PASSWORD' ausente ou vazia em $EnvFile."
    }
    return "SYSTEM/$($envMap['ORACLE_PASSWORD'])@//localhost:1521/FREEPDB1"
}

function Get-VaultToken {
    param([string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env'))
    $envMap = Get-DotEnv -Path $EnvFile
    if (-not $envMap.ContainsKey('VAULT_DEV_ROOT_TOKEN_ID')) {
        throw "Variavel 'VAULT_DEV_ROOT_TOKEN_ID' ausente em $EnvFile."
    }
    return $envMap['VAULT_DEV_ROOT_TOKEN_ID']
}

function Invoke-SqlPlus {
    param([Parameter(Mandatory)][string]$ConnectString, [Parameter(Mandatory)][string]$Sql)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Sql)
    $b64 = [Convert]::ToBase64String($bytes)
    $innerCmd = 'echo ' + $b64 + ' | base64 -d | sqlplus -s "$ORACLE_CONNSTR"'
    return docker exec -i -e ORACLE_CONNSTR="$ConnectString" kawashi-oracle sh -c "$innerCmd" 2>&1
}

function New-StrongPassword {
    # Mesmo algoritmo de infra/scripts/create-team-member.ps1 (mantido em sincronia
    # de proposito) - gera senha que sempre passa em KAWASHI_PASSWORD_VERIFY.
    param(
        [int]$Length = 16,
        [string]$AvoidSubstring
    )
    $upperSet   = [char[]](65..90)
    $lowerSet   = [char[]](97..122)
    $digitSet   = [char[]](48..57)
    # Sem "@": e o separador usado pelo Oracle Easy Connect ("usuario/senha@host") -
    # ver correcao espelhada em infra/scripts/create-team-member.ps1.
    $specialSet = [char[]]'!#%^*-_=+?'
    $allSets    = $upperSet + $lowerSet + $digitSet + $specialSet

    do {
        $required = @(
            ($upperSet   | Get-Random)
            ($lowerSet   | Get-Random)
            ($digitSet   | Get-Random)
            ($specialSet | Get-Random)
        )
        $fillCount = $Length - $required.Count
        $filler = 1..$fillCount | ForEach-Object { $allSets | Get-Random }
        $password = -join (($required + $filler) | Sort-Object { Get-Random })
    } while ($AvoidSubstring -and $password.ToUpper().Contains($AvoidSubstring.ToUpper()))

    return $password
}

function New-ThrowawayUsername {
    param([string]$Prefix = 'TESTE_AUTO')
    $suffix = -join ((48..57 + 65..90) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
    return "${Prefix}_$suffix"
}

function New-TestResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Passed,
        [string]$Details = ''
    )
    [PSCustomObject]@{ Name = $Name; Passed = $Passed; Details = $Details }
}

function Write-TestResult {
    param([Parameter(Mandatory)][PSCustomObject]$Result)
    if ($Result.Passed) {
        Write-Host "  [OK]    $($Result.Name)" -ForegroundColor Green
    } else {
        Write-Host "  [FALHA] $($Result.Name)" -ForegroundColor Red
        if ($Result.Details) { Write-Host "          $($Result.Details)" -ForegroundColor Yellow }
    }
}
