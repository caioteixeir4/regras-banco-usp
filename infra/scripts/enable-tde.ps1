<#
.SYNOPSIS
    Liga a criptografia em disco (TDE - Transparent Data Encryption) do Oracle e cifra as
    tablespaces da Kawashi.

.DESCRIPTION
    Com o TDE, o Oracle cifra os arquivos de dados (.dbf) e os backups. Quem roubar o disco, um
    backup ou uma copia do volume do container nao consegue ler nada sem a chave mestra, que fica
    num cofre proprio do banco (keystore), fora dos arquivos de dados.

    O QUE O TDE NAO FAZ: nao protege de quem esta logado no banco. Um SELECT continua devolvendo o
    dado em claro, porque o banco decifra sozinho para quem tem permissao. Contra leitura direta
    das tabelas a defesa e a cifra por campo feita pela API (ver o repositorio
    tabelas-api-banco-usp, docs/modelo-de-dados.md).

    Este script e IDEMPOTENTE: confere o estado antes de cada passo e so faz o que falta.

      1. WALLET_ROOT: diz ao Oracle onde fica o keystore. E um parametro estatico, entao na
         primeira vez o script REINICIA o container do banco (uns 30 segundos fora do ar).
      2. TDE_CONFIGURATION = keystore em arquivo.
      3. Cria o keystore, protegido por uma senha aleatoria. A senha vai para o Vault
         (kawashi-secrets/tde) e para o infra/.env (TDE_KEYSTORE_PASSWORD), que nunca e versionado.
      4. Cria a chave mestra (no CDB e nos PDBs) e um keystore de abertura automatica, para o
         banco abrir sozinho depois de um restart.
      5. ENCRYPT_NEW_TABLESPACES = ALWAYS: toda tablespace criada dali em diante ja nasce cifrada.
      6. Cifra, com o banco no ar, as tablespaces TS_KAWASHI_* e USERS (AES-256).

    ATENCAO - o que nao pode se perder: o diretorio do keystore (dentro do container, em
    /opt/oracle/admin/FREE/wallet). Sem ele os dados cifrados sao ilegiveis PARA SEMPRE. Em
    producao o keystore tem backup proprio, separado do backup dos dados, ou fica num cofre
    externo (Oracle Key Vault / HSM).

    Ficam de fora, por enquanto: SYSTEM, SYSAUX e UNDO (o dicionario do Oracle). As tabelas de
    negocio, os logs da aplicacao e a trilha de seguranca estao todas em tablespaces TS_KAWASHI_*.

.PARAMETER EnvFile
    Caminho do .env. Padrao: infra/.env. Recebe TDE_KEYSTORE_PASSWORD se ainda nao tiver.

.EXAMPLE
    ./enable-tde.ps1
#>
[CmdletBinding()]
param(
    [string]$EnvFile
)

$ErrorActionPreference = 'Stop'
# Padrao do -EnvFile calculado AQUI, e nao no bloco param: com [CmdletBinding()], quando o script
# e chamado com "powershell -File", o $PSScriptRoot ainda esta vazio nos valores padrao do param.
if (-not $EnvFile) { $EnvFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\.env' }
$EnvFile = [System.IO.Path]::GetFullPath($EnvFile)
$WalletRoot = '/opt/oracle/admin/FREE/wallet'

function Get-DotEnv {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Arquivo .env nao encontrado em '$Path'. Copie infra/.env.example para infra/.env e preencha antes de rodar este script."
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

# Roda SQL como SYSDBA, de dentro do container (o TDE se configura no CDB, nao so no PDB). O SQL
# vai em BASE64 num unico argumento, pra nada ser interpretado pelo shell.
function Invoke-Sys {
    param([string]$Sql)
    $texto = "SET PAGESIZE 0`nSET FEEDBACK OFF`nSET HEADING OFF`nSET LINESIZE 300`n$Sql`nEXIT;`n"
    $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($texto))
    # Aspas SIMPLES em volta de "/ as sysdba": o Windows PowerShell remove aspas duplas internas ao
    # chamar um programa, e sem elas a sessao nao entra como SYSDBA (ORA-01031 no primeiro ALTER SYSTEM).
    $inner = 'echo ' + $b64 + " | base64 -d | sqlplus -s '/ as sysdba'"
    $anterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $saida = docker exec -i kawashi-oracle sh -c "$inner" 2>&1 } finally { $ErrorActionPreference = $anterior }
    return (($saida | ForEach-Object { "$_" }) -join "`n")
}

function Invoke-SysOuFalha {
    param([string]$Sql, [string]$OQue)
    $saida = Invoke-Sys $Sql
    if ($saida -match '(ORA|SP2)-\d{4,5}') { throw "Falha ao $OQue`:`n$saida" }
    return $saida
}

function Wait-BancoSaudavel {
    for ($i = 0; $i -lt 60; $i++) {
        $estado = (docker inspect -f '{{.State.Health.Status}}' kawashi-oracle 2>$null)
        if ($estado -eq 'healthy') { return }
        Start-Sleep -Seconds 5
    }
    throw "O container kawashi-oracle nao voltou a ficar saudavel em 5 minutos (docker logs kawashi-oracle)."
}

Write-Host "== Kawashi - Criptografia em disco (TDE) ==" -ForegroundColor Cyan
$envMap = Get-DotEnv -Path $EnvFile

# ---------------------------------------------------------------------------
# 1. WALLET_ROOT (estatico: exige reiniciar o banco na primeira vez)
# ---------------------------------------------------------------------------
$walletAtual = (Invoke-SysOuFalha "SELECT 'W=[' || value || ']' FROM v`$parameter WHERE name = 'wallet_root';" 'ler WALLET_ROOT')
if ($walletAtual -match 'W=\[\]') {
    Write-Host "-> Definindo WALLET_ROOT e reiniciando o banco (uns 30 segundos fora do ar)..."
    docker exec kawashi-oracle sh -c "mkdir -p $WalletRoot && chmod 700 $WalletRoot" | Out-Null
    # Ja pode estar gravado no arquivo de parametros por uma execucao anterior que nao chegou a
    # reiniciar; gravar de novo nao faz mal. O valor so passa a valer depois do restart.
    Invoke-SysOuFalha "ALTER SYSTEM SET WALLET_ROOT = '$WalletRoot' SCOPE = SPFILE;" 'definir WALLET_ROOT' | Out-Null
    docker restart kawashi-oracle | Out-Null
    Start-Sleep -Seconds 10
    Wait-BancoSaudavel
    $walletAtual = (Invoke-SysOuFalha "SELECT 'W=[' || value || ']' FROM v`$parameter WHERE name = 'wallet_root';" 'reler WALLET_ROOT')
    if ($walletAtual -match 'W=\[\]') { throw "O banco reiniciou, mas WALLET_ROOT continua vazio." }
} else {
    Write-Host "-> WALLET_ROOT ja definido."
}

# ---------------------------------------------------------------------------
# 2. TDE_CONFIGURATION
# ---------------------------------------------------------------------------
$confAtual = (Invoke-SysOuFalha "SELECT 'C=[' || value || ']' FROM v`$parameter WHERE name = 'tde_configuration';" 'ler TDE_CONFIGURATION')
if ($confAtual -match 'C=\[\]') {
    Write-Host "-> Definindo TDE_CONFIGURATION (keystore em arquivo)..."
    Invoke-SysOuFalha "ALTER SYSTEM SET TDE_CONFIGURATION = 'KEYSTORE_CONFIGURATION=FILE' SCOPE = BOTH;" 'definir TDE_CONFIGURATION' | Out-Null
} else {
    Write-Host "-> TDE_CONFIGURATION ja definido."
}

# ---------------------------------------------------------------------------
# 3 e 4. Keystore, chave mestra e abertura automatica
# ---------------------------------------------------------------------------
$estadoKeystore = (Invoke-SysOuFalha "SELECT 'K=' || status || '|' || wallet_type FROM v`$encryption_wallet WHERE con_id = 1;" 'ler o estado do keystore')
if ($estadoKeystore -match 'K=NOT_AVAILABLE') {
    Write-Host "-> Criando o keystore e a chave mestra..."
    $senha = $envMap['TDE_KEYSTORE_PASSWORD']
    if ([string]::IsNullOrWhiteSpace($senha)) {
        # So letras e numeros: a senha vai dentro de um comando SQL entre aspas.
        $alfabeto = (48..57) + (65..90) + (97..122)
        $senha = -join (1..40 | ForEach-Object { [char]($alfabeto | Get-Random) })
        $acrescimo = "TDE_KEYSTORE_PASSWORD=$senha`n"
        $atual = [System.IO.File]::ReadAllText($EnvFile)
        if ($atual.Length -gt 0 -and -not $atual.EndsWith("`n")) { $acrescimo = "`n" + $acrescimo }
        [System.IO.File]::AppendAllText($EnvFile, $acrescimo, [System.Text.UTF8Encoding]::new($false))
        Write-Host "   Senha do keystore gerada e guardada em $EnvFile (TDE_KEYSTORE_PASSWORD)."
    }
    Invoke-SysOuFalha @"
ADMINISTER KEY MANAGEMENT CREATE KEYSTORE IDENTIFIED BY "$senha";
ADMINISTER KEY MANAGEMENT SET KEYSTORE OPEN IDENTIFIED BY "$senha" CONTAINER = ALL;
ADMINISTER KEY MANAGEMENT SET KEY IDENTIFIED BY "$senha" WITH BACKUP CONTAINER = ALL;
ADMINISTER KEY MANAGEMENT CREATE AUTO_LOGIN KEYSTORE FROM KEYSTORE IDENTIFIED BY "$senha";
"@ 'criar o keystore e a chave mestra' | Out-Null

    # Copia da senha no Vault. Em desenvolvimento o Vault e em memoria, entao o .env e a copia que dura.
    if ($envMap.ContainsKey('VAULT_DEV_ROOT_TOKEN_ID') -and $envMap['VAULT_DEV_ROOT_TOKEN_ID']) {
        $anterior = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        docker exec -e VAULT_TOKEN=$($envMap['VAULT_DEV_ROOT_TOKEN_ID']) kawashi-vault vault kv put 'kawashi-secrets/tde' keystore_password=$senha 2>&1 | Out-Null
        $okVault = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = $anterior
        if ($okVault) { Write-Host "   Copia da senha guardada no Vault (kawashi-secrets/tde)." }
        else { Write-Host "   AVISO: nao consegui guardar a senha no Vault (rode vault-init.ps1); ela esta no .env." -ForegroundColor Yellow }
    }
} else {
    Write-Host "-> Keystore ja existe ($(($estadoKeystore -replace '(?s).*K=', '').Trim()))."
}

# ---------------------------------------------------------------------------
# 5. Tablespace nova ja nasce cifrada
# ---------------------------------------------------------------------------
Invoke-SysOuFalha @"
ALTER SYSTEM SET ENCRYPT_NEW_TABLESPACES = ALWAYS SCOPE = BOTH;
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SYSTEM SET ENCRYPT_NEW_TABLESPACES = ALWAYS SCOPE = BOTH;
"@ 'definir ENCRYPT_NEW_TABLESPACES' | Out-Null

# ---------------------------------------------------------------------------
# 6. Cifra as tablespaces da Kawashi, com o banco no ar
# ---------------------------------------------------------------------------
$pendentes = (Invoke-SysOuFalha @"
ALTER SESSION SET CONTAINER = FREEPDB1;
SELECT 'TS=' || tablespace_name FROM dba_tablespaces
 WHERE encrypted = 'NO' AND (tablespace_name LIKE 'TS\_KAWASHI\_%' ESCAPE '\' OR tablespace_name = 'USERS')
 ORDER BY tablespace_name;
"@ 'listar as tablespaces') -split "`n" | Where-Object { $_ -match '^TS=' } | ForEach-Object { $_ -replace '^TS=', '' }

foreach ($ts in $pendentes) {
    Write-Host "-> Cifrando $ts..."
    Invoke-SysOuFalha "ALTER SESSION SET CONTAINER = FREEPDB1;`nALTER TABLESPACE $ts ENCRYPTION ONLINE USING 'AES256' ENCRYPT;" "cifrar a tablespace $ts" | Out-Null
}
if (-not $pendentes) { Write-Host "-> Todas as tablespaces da Kawashi ja estao cifradas." }

$resumo = Invoke-SysOuFalha @"
SELECT 'keystore: ' || status || ' (' || wallet_type || ')' FROM v`$encryption_wallet WHERE con_id = 1;
ALTER SESSION SET CONTAINER = FREEPDB1;
SELECT '  ' || RPAD(tablespace_name, 30) || ' cifrada=' || encrypted FROM dba_tablespaces ORDER BY tablespace_name;
"@ 'ler o resumo'
Write-Host ""
Write-Host "== TDE ligado ==" -ForegroundColor Green
Write-Host $resumo
