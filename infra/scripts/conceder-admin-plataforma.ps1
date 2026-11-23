# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Concede (ou revoga) o papel de ADMINISTRADOR DA PLATAFORMA a um usuario do login da aplicacao.

.DESCRIPTION
    O administrador da plataforma e a equipe da Kawashi: cria empresas novas e o primeiro
    administrador de cada uma (POST /api/plataforma/empresas). Ele NAO enxerga os dados de dentro
    das empresas; para isso precisaria de um vinculo, como qualquer usuario.

    O papel fica na tabela KAWASHI_ENV_<AMBIENTE>_LOGIN.ADMIN_PLATAFORMA (14_autorizacao.sql), em
    que a API so LE: ninguem se promove pela API. Este script grava com a conta do ENGENHEIRO
    (ENGINEER_USER do .env), entao o banco registra quem concedeu (CONCEDIDO_POR) e o gatilho
    manda a concessao e a revogacao para o LOG_SEGURANCA.

    A senha do engenheiro vai para o contêiner por variavel de ambiente ("docker exec -e NOME", sem
    o valor na linha de comando) e o SQL vai em base64 (o PowerShell 5.1 poe um BOM no que manda
    pela entrada padrao).

.PARAMETER Ambiente
    TESTE_DEV, TESTE_INFRA, DEV, INFRA, HOMOLOG ou PROD.

.PARAMETER UsuarioId
    Id do usuario (USUARIO.ID no schema _LOGIN do ambiente).

.PARAMETER Motivo
    Por que esta pessoa recebe o papel (fica gravado e no LOG_SEGURANCA).

.PARAMETER Revogar
    Tira o papel em vez de conceder.

.PARAMETER EnvFile
    O .env do repositorio de regras. Padrao: infra/.env.

.EXAMPLE
    .\conceder-admin-plataforma.ps1 -Ambiente TESTE_DEV -UsuarioId 108 -Motivo "usuario fixo dos testes da plataforma"

.EXAMPLE
    .\conceder-admin-plataforma.ps1 -Ambiente PROD -UsuarioId 7 -Revogar
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('TESTE_DEV', 'TESTE_INFRA', 'DEV', 'INFRA', 'HOMOLOG', 'PROD')]
    [string]$Ambiente,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, [long]::MaxValue)]
    [long]$UsuarioId,

    [ValidateLength(3, 200)]
    [string]$Motivo,

    [switch]$Revogar,

    [string]$EnvFile
)

$ErrorActionPreference = 'Stop'
# Padrao do -EnvFile calculado AQUI: com [CmdletBinding()] e "powershell -File", o $PSScriptRoot fica vazio no bloco param.
if (-not $EnvFile) { $EnvFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\.env' }
if (-not $Revogar -and -not $Motivo) { throw 'Informe -Motivo (fica gravado e no LOG_SEGURANCA).' }

function Get-ValorDoEnv {
    param([string]$Arquivo, [string]$Chave)
    if (-not (Test-Path -LiteralPath $Arquivo)) { throw "Arquivo .env nao encontrado em '$Arquivo'." }
    foreach ($linha in [System.IO.File]::ReadAllLines($Arquivo)) {
        $p = $linha.Trim().Split('=', 2)
        if ($p.Count -eq 2 -and $p[0].Trim() -eq $Chave) { return $p[1].Trim() }
    }
    throw "Variavel '$Chave' ausente em $Arquivo."
}

function Invoke-SqlComoEngenheiro {
    param([string]$Sql)
    $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($Sql))
    $anterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $env:ORACLE_CONNSTR = "$(Get-ValorDoEnv $EnvFile 'ENGINEER_USER')/$(Get-ValorDoEnv $EnvFile 'ENGINEER_USER_PASSWORD')@//localhost:1521/FREEPDB1"
        $saida = docker exec -e ORACLE_CONNSTR -e NLS_LANG=AMERICAN_AMERICA.AL32UTF8 kawashi-oracle sh -c ('echo ' + $b64 + ' | base64 -d | sqlplus -s "$ORACLE_CONNSTR"') 2>&1 | ForEach-Object { "$_" }
    } finally {
        Remove-Item Env:\ORACLE_CONNSTR -ErrorAction SilentlyContinue
        $ErrorActionPreference = $anterior
    }
    return ($saida -join "`n")
}

$login = "KAWASHI_ENV_${Ambiente}_LOGIN"
$motivoSql = if ($Motivo) { "'" + $Motivo.Trim().Replace("'", "''") + "'" } else { 'NULL' }
$acao = if ($Revogar) {
    "DELETE FROM $login.ADMIN_PLATAFORMA WHERE USUARIO_ID = $UsuarioId;"
} else {
    "INSERT INTO $login.ADMIN_PLATAFORMA (USUARIO_ID, CONCEDIDO_POR, MOTIVO) VALUES ($UsuarioId, '-', $motivoSql);"
}
$sql = @"
SET PAGESIZE 0
SET FEEDBACK OFF
WHENEVER SQLERROR EXIT FAILURE
$acao
COMMIT;
SELECT 'R|' || COUNT(*) FROM $login.ADMIN_PLATAFORMA WHERE USUARIO_ID = $UsuarioId;
EXIT;
"@
$saida = Invoke-SqlComoEngenheiro $sql
if ($saida -match 'ORA-00001') { Write-Host "O usuario $UsuarioId ja e administrador da plataforma em $Ambiente." -ForegroundColor Yellow; exit 0 }
if ($saida -match 'ORA-02291') { throw "Nao existe o usuario $UsuarioId em $Ambiente." }
if ($saida -match '(ORA|SP2)-\d{4,5}') { throw "O banco recusou:`n$saida" }
$tem = [regex]::Match($saida, 'R\|(\d+)').Groups[1].Value
if ($Revogar) {
    if ($tem -eq '0') { Write-Host "Papel revogado: o usuario $UsuarioId nao e mais administrador da plataforma em $Ambiente." -ForegroundColor Green }
    else { throw "A revogacao nao se confirmou." }
} else {
    if ($tem -eq '1') { Write-Host "Papel concedido: o usuario $UsuarioId e administrador da plataforma em $Ambiente (registrado no LOG_SEGURANCA)." -ForegroundColor Green }
    else { throw "A concessao nao se confirmou." }
}
