# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Publica uma versao nova dos termos de uso ou da politica de privacidade (LGPD).

.DESCRIPTION
    Os textos ficam na tabela KAWASHI_ENV_<AMBIENTE>_LOGIN.TERMO (15_aceite_de_termos.sql). Vale a
    versao mais recente de cada documento: depois de publicar, TODO usuario precisa aceitar a nova
    antes de voltar a usar o sistema (a API responde 403 "Aceite os termos" ate la).

    O banco calcula o SHA-256 do texto e grava quem publicou (a conta do ENGENHEIRO, do .env) e a
    hora; o que vier informado e ignorado. Termo publicado nao muda nem sai (ORA-20111): corrigir
    um texto e publicar outra versao.

    O texto vem de um arquivo UTF-8 e vai para o banco em base64 (em pedacos, montado como BLOB e
    convertido para CLOB em AL32UTF8), sem passar acentos pela linha de comando. A senha do
    engenheiro vai para o conteiner por variavel de ambiente ("docker exec -e NOME", sem o valor).

.PARAMETER Ambiente
    TESTE_DEV, TESTE_INFRA, DEV, INFRA, HOMOLOG ou PROD.

.PARAMETER Documento
    TERMOS_DE_USO ou POLITICA_DE_PRIVACIDADE.

.PARAMETER Versao
    Nome da versao (ex.: 2, 2026-12). Unica por documento.

.PARAMETER Arquivo
    Arquivo de texto UTF-8 com o texto inteiro do documento.

.PARAMETER EnvFile
    O .env do repositorio de regras. Padrao: infra/.env.

.EXAMPLE
    .\publicar-termo.ps1 -Ambiente PROD -Documento POLITICA_DE_PRIVACIDADE -Versao 2 -Arquivo .\politica-v2.txt
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('TESTE_DEV', 'TESTE_INFRA', 'DEV', 'INFRA', 'HOMOLOG', 'PROD')]
    [string]$Ambiente,

    [Parameter(Mandatory = $true)]
    [ValidateSet('TERMOS_DE_USO', 'POLITICA_DE_PRIVACIDADE')]
    [string]$Documento,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Za-z.\-]{1,20}$')]
    [string]$Versao,

    [Parameter(Mandatory = $true)]
    [string]$Arquivo,

    [string]$EnvFile
)

$ErrorActionPreference = 'Stop'
# Padrao do -EnvFile calculado AQUI: com [CmdletBinding()] e "powershell -File", o $PSScriptRoot fica vazio no bloco param.
if (-not $EnvFile) { $EnvFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\.env' }
if (-not (Test-Path -LiteralPath $Arquivo)) { throw "Arquivo '$Arquivo' nao encontrado." }

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
    # O SQL (com o texto, que pode ser grande) vai por arquivo: pela linha de comando passaria do
    # limite do Windows. O arquivo nao tem segredo; a senha so vai por variavel de ambiente.
    param([string]$Sql)
    $local = Join-Path ([System.IO.Path]::GetTempPath()) ("publicar-termo-" + [guid]::NewGuid().ToString('N') + '.sql')
    $remoto = '/tmp/' + (Split-Path -Leaf $local)
    $anterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        [System.IO.File]::WriteAllText($local, $Sql, [System.Text.UTF8Encoding]::new($false))
        docker cp $local "kawashi-oracle:$remoto" 2>&1 | Out-Null
        $env:ORACLE_CONNSTR = "$(Get-ValorDoEnv $EnvFile 'ENGINEER_USER')/$(Get-ValorDoEnv $EnvFile 'ENGINEER_USER_PASSWORD')@//localhost:1521/FREEPDB1"
        $saida = docker exec -e ORACLE_CONNSTR -e NLS_LANG=AMERICAN_AMERICA.AL32UTF8 kawashi-oracle sh -c ('sqlplus -s "$ORACLE_CONNSTR" @' + $remoto) 2>&1 | ForEach-Object { "$_" }
    } finally {
        Remove-Item Env:\ORACLE_CONNSTR -ErrorAction SilentlyContinue
        docker exec -u 0 kawashi-oracle rm -f $remoto 2>&1 | Out-Null
        Remove-Item -LiteralPath $local -ErrorAction SilentlyContinue
        $ErrorActionPreference = $anterior
    }
    return ($saida -join "`n")
}

# O texto: bytes UTF-8 sem BOM, sem espacos sobrando nas pontas.
$texto = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Arquivo), [System.Text.Encoding]::UTF8).Trim()
if ($texto.Length -lt 50) { throw 'Texto curto demais para um termo (menos de 50 caracteres).' }
# Campos do modelo ainda nao preenchidos ({ Nome da empresa }, { CNPJ da empresa }...): publica, mas avisa.
$abertos = @([regex]::Matches($texto, '\{ [^{}]{2,60} \}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
if ($abertos.Count -gt 0) {
    Write-Host "AVISO: o texto tem $($abertos.Count) campo(s) do modelo sem preencher: $($abertos -join ', ')." -ForegroundColor Yellow
    Write-Host "       Para valer com dados reais, preencha e publique uma versao nova." -ForegroundColor Yellow
}
$bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($texto)
$hashLocal = -join ([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
$b64Texto = [Convert]::ToBase64String($bytes)
$pedacos = for ($i = 0; $i -lt $b64Texto.Length; $i += 2000) { "  DBMS_LOB.APPEND(b, UTL_ENCODE.BASE64_DECODE(UTL_RAW.CAST_TO_RAW('" + $b64Texto.Substring($i, [Math]::Min(2000, $b64Texto.Length - $i)) + "')));" }

$login = "KAWASHI_ENV_${Ambiente}_LOGIN"
$sql = @"
SET PAGESIZE 0
SET FEEDBACK OFF
SET LINESIZE 300
WHENEVER SQLERROR EXIT FAILURE
DECLARE
  b BLOB;
  c CLOB;
  v_dest INTEGER := 1;
  v_orig INTEGER := 1;
  v_ctx INTEGER := DBMS_LOB.DEFAULT_LANG_CTX;
  v_aviso INTEGER;
BEGIN
  DBMS_LOB.CREATETEMPORARY(b, TRUE);
  DBMS_LOB.CREATETEMPORARY(c, TRUE);
$($pedacos -join "`n")
  DBMS_LOB.CONVERTTOCLOB(c, b, DBMS_LOB.LOBMAXSIZE, v_dest, v_orig, NLS_CHARSET_ID('AL32UTF8'), v_ctx, v_aviso);
  INSERT INTO $login.TERMO (DOCUMENTO, VERSAO, TEXTO, HASH_TEXTO, PUBLICADO_POR) VALUES ('$Documento', '$Versao', c, RPAD('0', 64, '0'), '-');
  COMMIT;
END;
/
SELECT 'R|' || ID || '|' || HASH_TEXTO || '|' || PUBLICADO_POR FROM $login.TERMO WHERE DOCUMENTO = '$Documento' AND VERSAO = '$Versao';
EXIT;
"@
$saida = Invoke-SqlComoEngenheiro $sql
if ($saida -match 'ORA-00001') { throw "Ja existe a versao '$Versao' de $Documento em $Ambiente (versao nova precisa de nome novo)." }
if ($saida -match '(ORA|SP2|PLS)-\d{4,5}') { throw "O banco recusou:`n$saida" }
$m = [regex]::Match($saida, 'R\|(\d+)\|([0-9a-f]{64})\|(\S+)')
if (-not $m.Success) { throw "A publicacao nao se confirmou:`n$saida" }
if ($m.Groups[2].Value -ne $hashLocal) {
    throw "O SHA-256 calculado pelo banco ($($m.Groups[2].Value)) nao bate com o do arquivo ($hashLocal): o texto chegou diferente."
}
Write-Host "Publicado: $Documento versao $Versao em $Ambiente (id $($m.Groups[1].Value), SHA-256 $hashLocal, por $($m.Groups[3].Value))." -ForegroundColor Green
Write-Host "Todo usuario tera de aceitar esta versao antes de voltar a usar o sistema." -ForegroundColor Yellow
