# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste de CAIXA-PRETA: toda conexao pela rede com o banco e cifrada (AES-256) e conferida contra
    adulteracao (SHA-256), um cliente que se recusa a cifrar e barrado, e o listener nao aceita ser
    reconfigurado (infra/scripts/apply-network-hardening.ps1).

.DESCRIPTION
    As conexoes sao feitas pela rede de verdade (TCP, //localhost:1521), nao pela conexao local do
    SYSDBA. Um "cliente teimoso" e simulado com um sqlnet.ora proprio (TNS_ADMIN) dizendo que ele
    RECUSA cifrar.

    Controle: o teste desfaz a configuracao (-Desfazer), confirma que o MESMO cliente teimoso entra
    (prova que e a configuracao que o barra, e nao outra coisa) e aplica de novo. Se algo der
    errado no meio, o finally aplica de novo.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')
$ErrorActionPreference = 'Continue'

Write-Host "== [CAIXA-PRETA] Conexao com o banco cifrada ==" -ForegroundColor Cyan

$aplicar = Join-Path $PSScriptRoot '..\..\scripts\apply-network-hardening.ps1'
$engineerConn = Get-EngineerConnectString -EnvFile $EnvFile
$results = @()
$desfeito = $false

# Roda um script de shell no container (em BASE64, para as aspas chegarem inteiras).
function Invoke-Sh {
    param([string]$Script, [string]$ConnectString = '')
    $b = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($Script.Replace("`r`n", "`n")))
    return ((docker exec -i -e ORACLE_CONNSTR="$ConnectString" kawashi-oracle sh -c "echo $b | base64 -d | sh" 2>&1 | ForEach-Object { "$_" }) -join "`n")
}

# Conecta pela rede com um cliente cujo sqlnet.ora diz $Regra ("" = cliente normal).
function Connect-Cliente {
    param([string]$Regra)
    $sh = @"
rm -rf /tmp/cliente-teste && mkdir -p /tmp/cliente-teste
printf '$Regra\nDISABLE_OOB=ON\n' > /tmp/cliente-teste/sqlnet.ora
printf "SET PAGESIZE 0\nSET LINESIZE 300\nSELECT 'BANNER|' || network_service_banner FROM v\`$session_connect_info WHERE sid = SYS_CONTEXT('USERENV', 'SID');\nEXIT;\n" | TNS_ADMIN=/tmp/cliente-teste sqlplus -s -L "`$ORACLE_CONNSTR"
"@
    return Invoke-Sh $sh $engineerConn
}

function Invoke-Aplicar {
    param([string]$Argumentos = '')
    $saida = (powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$aplicar' $Argumentos -EnvFile '$EnvFile'" 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return [pscustomobject]@{ Codigo = $LASTEXITCODE; Saida = $saida }
}

try {
    # Estado de partida: aplicado (o script e idempotente; rodar de novo nao duplica).
    $r = Invoke-Aplicar
    $results += New-TestResult -Name "apply-network-hardening.ps1 aplica e confere numa conexao de verdade (codigo 0)" -Passed ($r.Codigo -eq 0) -Details $r.Saida

    $normal = Connect-Cliente '# cliente normal, sem regra'
    $results += New-TestResult -Name "Cliente normal conecta pela rede e a sessao negocia cifra AES256" -Passed ($normal -match 'AES256 Encryption service adapter') -Details $normal
    $results += New-TestResult -Name "...e integridade SHA256 (pacote alterado no caminho e detectado)" -Passed ($normal -match 'SHA256 Crypto-checksumming service adapter') -Details $normal

    $semCifra = Connect-Cliente 'SQLNET.ENCRYPTION_CLIENT = REJECTED'
    $results += New-TestResult -Name "Cliente que RECUSA cifrar e barrado pelo servidor (ORA-12660) e nao entra" -Passed (($semCifra -match 'ORA-12660') -and ($semCifra -notmatch 'BANNER\|')) -Details $semCifra

    $semChecksum = Connect-Cliente 'SQLNET.CRYPTO_CHECKSUM_CLIENT = REJECTED'
    $results += New-TestResult -Name "Cliente que recusa a conferencia de integridade tambem e barrado (ORA-12660)" -Passed (($semChecksum -match 'ORA-12660') -and ($semChecksum -notmatch 'BANNER\|')) -Details $semChecksum

    $lsnr = Invoke-Sh 'lsnrctl set trc_level 0 2>&1 | tail -3'
    $results += New-TestResult -Name "O listener recusa ser reconfigurado em tempo de execucao (ADMIN_RESTRICTIONS: TNS-12508)" -Passed ($lsnr -match 'TNS-12508') -Details $lsnr

    $marcas = Invoke-Sh 'for f in sqlnet.ora listener.ora; do printf "%s=%s " $f $(grep -c "^# >>> KAWASHI" $(readlink -f $ORACLE_HOME/network/admin/$f)); done'
    $results += New-TestResult -Name "Rodar o script de novo nao duplica: um unico bloco do Kawashi em cada arquivo" -Passed ($marcas -match 'sqlnet\.ora=1' -and $marcas -match 'listener\.ora=1') -Details $marcas

    $local = (Invoke-SqlPlus -ConnectString '/ as sysdba' -Sql "SELECT 'LOCAL_OK' FROM dual;`nEXIT;`n") -join ' '
    $results += New-TestResult -Name "A conexao local do administrador (sem rede) continua funcionando" -Passed ($local -match 'LOCAL_OK') -Details $local

    # --- controle: sem a configuracao, o mesmo cliente teimoso entra -------------------
    $r = Invoke-Aplicar '-Desfazer'
    $desfeito = $true
    $semCifraSemRegra = Connect-Cliente 'SQLNET.ENCRYPTION_CLIENT = REJECTED'
    $results += New-TestResult -Name "CONTROLE: sem a configuracao (-Desfazer), o mesmo cliente que recusa cifrar ENTRA, e sem AES256 (prova que e a configuracao que barra)" -Passed (($r.Codigo -eq 0) -and ($semCifraSemRegra -match 'BANNER\|') -and ($semCifraSemRegra -notmatch 'AES256')) -Details "$($r.Saida)`n$semCifraSemRegra"

    $r = Invoke-Aplicar
    $desfeito = $false
    $deNovo = Connect-Cliente 'SQLNET.ENCRYPTION_CLIENT = REJECTED'
    $results += New-TestResult -Name "Aplicado de novo, o cliente que recusa cifrar volta a ser barrado" -Passed (($r.Codigo -eq 0) -and ($deNovo -match 'ORA-12660')) -Details "$($r.Saida)`n$deNovo"
}
finally {
    if ($desfeito) {
        Write-Host "-> Reaplicando a criptografia da conexao (o teste parou no meio)..."
        Invoke-Aplicar | Out-Null
    }
    Invoke-Sh 'rm -rf /tmp/cliente-teste' | Out-Null
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
