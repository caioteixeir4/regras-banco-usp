<#
.SYNOPSIS
    Liga a criptografia da conexao com o banco (toda conexao por rede passa a ser cifrada com
    AES-256 e conferida com SHA-256) e trava a reconfiguracao remota do listener. Desfaz sozinho se
    a conexao parar de funcionar.

.DESCRIPTION
    Sem isto, o que trafega entre o computador de quem usa o banco (ou a API) e o Oracle vai em
    texto puro: o resultado de cada consulta pode ser lido por quem estiver no caminho. A senha do
    login ja e protegida pelo proprio protocolo do Oracle; os dados, nao.

    O que muda, nos arquivos de rede do Oracle dentro do container:
      sqlnet.ora    SQLNET.ENCRYPTION_SERVER = REQUIRED, so AES256
                    SQLNET.CRYPTO_CHECKSUM_SERVER = REQUIRED, so SHA256
                    (REQUIRED: conexao que nao cifra e recusada, nao so "aceita se o cliente pedir")
      listener.ora  ADMIN_RESTRICTIONS_LISTENER = ON
                    (ninguem reconfigura o listener pela rede; so de dentro do container)

    O cliente nao precisa de configuracao: o driver JDBC da API e o sqlplus negociam a cifra
    sozinhos quando o servidor exige. Conexoes locais como SYSDBA (sem rede) nao mudam.

    Como funciona, com seguranca:
      1. guarda uma copia dos arquivos originais (.kawashi-original), so na primeira vez;
      2. escreve o bloco entre marcadores "# >>> KAWASHI" e "# <<< KAWASHI" (rodar de novo
         substitui o bloco, nao duplica);
      3. rele o listener (lsnrctl reload), sem derrubar o banco, e manda o banco se registrar de
         novo nele (o reload esquece o registro e as conexoes falham por alguns segundos);
      4. abre uma conexao de verdade pela rede e confere que ela negociou AES256 e SHA256;
      5. se a conexao falhar, volta os arquivos originais na hora e avisa.

    Os arquivos moram dentro do container: se ele for recriado, rode este script de novo.

.PARAMETER Desfazer
    Volta os arquivos originais e rele o listener.

.PARAMETER EnvFile
    Caminho do .env (credenciais do ENGINEER_USER, usadas no teste de conexao). Padrao: infra/.env.

.EXAMPLE
    ./apply-network-hardening.ps1

.EXAMPLE
    ./apply-network-hardening.ps1 -Desfazer
#>
[CmdletBinding()]
param(
    [switch]$Desfazer,
    [string]$EnvFile
)

$ErrorActionPreference = 'Stop'
$aqui = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $EnvFile) { $EnvFile = Join-Path $aqui '..\.env' }
$admin = '$ORACLE_HOME/network/admin'

# Roda um comando de shell dentro do container. O texto vai em BASE64 (sem aspas para o
# PowerShell 5.1 estragar).
function Invoke-NoContainer {
    param([string]$Comando)
    $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($Comando))
    $anterior = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $saida = docker exec kawashi-oracle bash -c "echo $b64 | base64 -d | bash" 2>&1 | ForEach-Object { "$_" }
    $codigo = $LASTEXITCODE
    $ErrorActionPreference = $anterior
    return [pscustomobject]@{ Codigo = $codigo; Saida = ($saida -join "`n") }
}

function Get-DotEnv {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Arquivo .env nao encontrado em '$Path'." }
    $map = @{}
    foreach ($line in Get-Content $Path) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $p = $t.Split('=', 2); if ($p.Count -eq 2) { $map[$p[0].Trim()] = $p[1].Trim() }
    }
    return $map
}

# Rele o listener. CUIDADO aprendido testando: o reload faz o listener ESQUECER os servicos que
# o banco tinha registrado (FREEPDB1), e por alguns segundos toda conexao pela rede falha com
# ORA-12514. Por isso, logo depois, o banco e mandado se registrar de novo (ALTER SYSTEM REGISTER,
# pela conexao local, que nao depende do listener).
function Invoke-Recarregar {
    Invoke-NoContainer @"
lsnrctl reload >/dev/null
printf 'ALTER SYSTEM REGISTER;\nEXIT;\n' | sqlplus -s '/ as sysdba' >/dev/null
echo RECARREGADO
"@
}

# Uma conexao de verdade pela rede (TCP, nao a local do SYSDBA), e o que ela negociou. Se o
# listener ainda nao recebeu o registro do banco (ORA-12514), espera e tenta de novo (ate 30 s).
function Test-ConexaoCifrada {
    for ($tentativa = 0; $tentativa -lt 30; $tentativa++) {
        $r = Test-ConexaoUmaVez
        if ($r.Conectou -or $r.Saida -notmatch 'ORA-12514') { return $r }
        Start-Sleep -Seconds 1
    }
    return $r
}

function Test-ConexaoUmaVez {
    $envMap = Get-DotEnv -Path $EnvFile
    $conn = "$($envMap['ENGINEER_USER'])/$($envMap['ENGINEER_USER_PASSWORD'])@//localhost:1521/FREEPDB1"
    $sql = "SET PAGESIZE 0`nSET LINESIZE 300`nSELECT 'BANNER|' || network_service_banner FROM v`$session_connect_info WHERE sid = SYS_CONTEXT('USERENV', 'SID');`nEXIT;`n"
    $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($sql))
    $anterior = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $saida = (docker exec -i -e ORACLE_CONNSTR="$conn" kawashi-oracle sh -c ('echo ' + $b64 + ' | base64 -d | sqlplus -s "$ORACLE_CONNSTR"') 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $ErrorActionPreference = $anterior
    return [pscustomobject]@{
        Conectou = ($saida -match 'BANNER\|')
        Aes256   = ($saida -match 'AES256 Encryption service adapter')
        Sha256   = ($saida -match 'SHA256 Crypto-checksumming service adapter')
        Saida    = $saida
    }
}

$bloco = @'
# >>> KAWASHI (infra/scripts/apply-network-hardening.ps1) - nao edite a mao entre estes marcadores
__CONTEUDO__
# <<< KAWASHI
'@

# O conteudo vem de infra/oracle-network-config/ (uma fonte so: mude la e rode este script).
$pastaConfig = Join-Path $aqui '..\oracle-network-config'
$sqlnet   = [System.IO.File]::ReadAllText((Join-Path $pastaConfig 'sqlnet.ora.append'))
$listener = [System.IO.File]::ReadAllText((Join-Path $pastaConfig 'listener.ora.append'))

# Os dois arquivos sao links para /opt/oracle/oradata/dbconfig/FREE/; escreve-se no destino.
$prepara = @"
set -e
cd $admin
for f in sqlnet.ora listener.ora; do
  alvo=`$(readlink -f `$f)
  [ -f "`$alvo.kawashi-original" ] || cp -p "`$alvo" "`$alvo.kawashi-original"
done
echo PRONTO
"@

if ($Desfazer) {
    Write-Host "== Kawashi - Desfazendo a criptografia da conexao ==" -ForegroundColor Cyan
    $r = Invoke-NoContainer @"
cd $admin
for f in sqlnet.ora listener.ora; do
  alvo=`$(readlink -f `$f)
  if [ -f "`$alvo.kawashi-original" ]; then cp -p "`$alvo.kawashi-original" "`$alvo"; echo "voltou: `$f"; else echo "sem copia original: `$f"; fi
done
echo VOLTOU
"@
    Write-Host $r.Saida
    Invoke-Recarregar | Out-Null
    $t = Test-ConexaoCifrada
    if ($t.Conectou -and -not $t.Aes256) { Write-Host "Conexao voltou a funcionar sem cifra exigida (estado original)." -ForegroundColor Yellow }
    else { Write-Host "ATENCAO: confira a conexao:`n$($t.Saida)" -ForegroundColor Red; exit 1 }
    exit 0
}

Write-Host "== Kawashi - Criptografia da conexao com o banco ==" -ForegroundColor Cyan

$r = Invoke-NoContainer $prepara
if ($r.Saida -notmatch 'PRONTO') { throw "Nao consegui preparar os arquivos de rede:`n$($r.Saida)" }
Write-Host "-> Copia dos arquivos originais guardada (.kawashi-original)."

# Escreve o bloco: tira um bloco antigo entre os marcadores (se houver) e acrescenta o novo.
foreach ($par in @(@('sqlnet.ora', $sqlnet), @('listener.ora', $listener))) {
    $texto = $bloco.Replace('__CONTEUDO__', $par[1].Trim()).Replace("`r`n", "`n")
    $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($texto + "`n"))
    $r = Invoke-NoContainer @"
set -e
alvo=`$(readlink -f $admin/$($par[0]))
sed -i '/^# >>> KAWASHI/,/^# <<< KAWASHI/d' "`$alvo"
echo $b64 | base64 -d >> "`$alvo"
echo GRAVADO
"@
    if ($r.Saida -notmatch 'GRAVADO') { throw "Nao consegui gravar $($par[0]):`n$($r.Saida)" }
    Write-Host "-> $($par[0]): bloco do Kawashi gravado."
}

$r = Invoke-Recarregar
if ($r.Saida -notmatch 'RECARREGADO') { throw "Nao consegui reler o listener:`n$($r.Saida)" }
Write-Host "-> Listener relido e banco registrado de novo nele."

$t = Test-ConexaoCifrada
if (-not $t.Conectou -or -not $t.Aes256 -or -not $t.Sha256) {
    Write-Host "A conexao de teste NAO saiu como esperado. Voltando os arquivos originais..." -ForegroundColor Red
    Invoke-NoContainer @"
cd $admin
for f in sqlnet.ora listener.ora; do alvo=`$(readlink -f `$f); cp -p "`$alvo.kawashi-original" "`$alvo"; done
"@ | Out-Null
    Invoke-Recarregar | Out-Null
    throw "Criptografia da conexao NAO aplicada (arquivos originais de volta). Saida do teste:`n$($t.Saida)"
}

Write-Host ""
Write-Host "== Conexao com o banco cifrada ==" -ForegroundColor Green
Write-Host "Conferido numa conexao de verdade: AES256 (cifra) e SHA256 (integridade) negociados."
Write-Host "Listener so aceita ser reconfigurado de dentro do container."
Write-Host "Para desfazer: ./apply-network-hardening.ps1 -Desfazer"
