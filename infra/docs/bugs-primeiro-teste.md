# Bugs encontrados no primeiro teste real do ambiente

Todo o projeto foi escrito e revisado antes de existir um Oracle/Vault rodando de verdade
para testar contra. Na primeira subida real (`docker compose up` + `vault-init.ps1` +
`create-team-member.ps1`), apareceram **7 problemas reais** que nenhuma leitura de código
teria pego — só rodando de verdade. Este documento registra cada um: o sintoma, a causa raiz,
e a correção, para servir de referência caso algo parecido apareça de novo (ou para explicar,
numa apresentação/defesa, que o projeto foi validado na prática, não só no papel).

## 1. `SEC_MAX_FAILED_LOGIN_ATTEMPTS` setado no PDB errado

**Sintoma:**
```
ALTER SYSTEM SET SEC_MAX_FAILED_LOGIN_ATTEMPTS = 3 SCOPE = SPFILE
ORA-65040: Operation is not allowed from within a pluggable database.
```

**Causa raiz:** todo arquivo de `oracle-init/` começa com `ALTER SESSION SET CONTAINER =
FREEPDB1` (para operar no PDB da aplicação, não na raiz do container). Mas
`SEC_MAX_FAILED_LOGIN_ATTEMPTS` é um parâmetro de escopo do **CDB inteiro** — o Oracle recusa
alterá-lo estando dentro de um PDB.

**Correção** (`10_advanced_hardening.sql`): trocar para `CDB$ROOT` só para este comando, e
voltar para `FREEPDB1` logo em seguida:
```sql
ALTER SESSION SET CONTAINER = CDB$ROOT;
ALTER SYSTEM SET SEC_MAX_FAILED_LOGIN_ATTEMPTS = 3 SCOPE = SPFILE;
ALTER SESSION SET CONTAINER = FREEPDB1;
```

## 2. Bloco de hardening do `SPRING_APP_USER` abortava no meio, silenciosamente

**Sintoma:**
```
ORA-01952: system privileges not granted to 'KAWASHI_SPRING_USER'
```
E o usuário ficava sem quota certa, sem `PASSWORD EXPIRE`, sem a role `KAWASHI_READWRITE` —
sem nenhum outro erro visível.

**Causa raiz:** o script assumia que a imagem `gvenzl/oracle-free` concede o privilégio de
sistema `UNLIMITED TABLESPACE` ao criar o usuário da aplicação. Na prática, ela dá uma
**quota específica na tablespace `USERS`**, não esse privilégio — então o
`REVOKE UNLIMITED TABLESPACE FROM ...` sempre falhava. Como essa linha estava dentro de um
único bloco `DECLARE...BEGIN...END` **sem tratamento de erro**, a exceção não tratada abortou
todas as linhas seguintes do mesmo bloco (quota, password expire, grant da role) — um erro
silencioso: nenhuma mensagem chamativa, só ausência de configuração.

**Correção** (`06_access_management.sql`):
- Fechar a quota que a própria imagem concede em `USERS` (`QUOTA 0 ON USERS`).
- Envolver o `REVOKE UNLIMITED TABLESPACE` em bloco próprio, ignorando especificamente
  `ORA-01952` (privilégio nunca concedido — está tudo bem).
- Revogar também `DB_DEVELOPER_ROLE` (role genérica que a imagem concede, fora do nosso RBAC).
- **Remover** o `PASSWORD EXPIRE` desta conta (ver item 4 abaixo — mesmo problema, mas para
  conta de aplicação em vez de conta pessoal).

## 3. Lockout de `SCOTT`/`HR` falhava porque essas contas não existem nesta imagem

**Sintoma:**
```
ALTER USER SCOTT ACCOUNT LOCK
ORA-01918: user 'SCOTT' does not exist
```
(mesmo erro para `HR`)

**Causa raiz:** `SCOTT` e `HR` são os schemas de demonstração clássicos do Oracle, mas a
imagem `gvenzl/oracle-free` (minimalista) não os instala. Não é um problema de segurança (se a
conta não existe, não há o que explorar) — mas o log de boot ficava com erro por algo que na
prática não é um erro.

**Correção** (`06_access_management.sql`): envolver cada `ACCOUNT LOCK` num helper que ignora
especificamente `ORA-01918` (usuário não existe), continuando para as próximas contas.

## 4. `PASSWORD EXPIRE` bloqueava toda automação não-interativa

**Sintoma:** ao tentar rodar qualquer script (`create-team-member.ps1`, `vault-init.ps1`)
usando as credenciais do `ENGINEER_USER`:
```
ORA-28001: The account has expired. The password must be changed.
...
SP2-0650: New passwords do not match
```

**Causa raiz:** `08_engineer_account.sql` força `PASSWORD EXPIRE` na conta do engenheiro,
pensado para o primeiro login humano trocar a senha (correto para pessoa). Mas os próprios
scripts de automação conectam com essa mesma senha do `.env` de forma **não-interativa**
(`sqlplus -s`) — e uma senha expirada exige resposta interativa que um script não consegue dar.

**Correção aplicada ao vivo:** resetar a senha do `ENGINEER_USER` conectando como `SYSTEM`
(`ALTER USER ... IDENTIFIED BY "nova_senha"` não pede senha antiga e já limpa o status de
expirada), e sincronizar o novo valor no `.env`.

**Correção de design** (`06_access_management.sql`): o `PASSWORD EXPIRE` foi **removido** da
conta de aplicação (`SPRING_APP_USER`) — um pool de conexão JDBC do Spring Boot jamais
conseguiria responder ao prompt de troca de senha, então essa conta ficaria permanentemente
inutilizável no primeiro uso. Para o `ENGINEER_USER` (conta de pessoa), o `PASSWORD EXPIRE`
continua fazendo sentido — só é preciso lembrar que, após a primeira troca (ou a cada 90 dias,
quando expirar de novo), **o valor no `.env` precisa ser atualizado** pra automação continuar
funcionando, já que ele funciona como "a senha atual usada pelos scripts", não só como
segredo inicial de bootstrap.

## 5. PowerShell insere um BOM invisível em qualquer conteúdo enviado por pipe

**Sintoma:**
```
SP2-0734: unknown command beginning "﻿SET PAGES..." - rest of line ignored.
```
e, no Vault:
```
failed to parse policy: At 1:1: illegal char
```

**Causa raiz:** o PowerShell 5.1, ao mandar uma string (heredoc `@"..."@`) por pipe (`|`) para
um processo externo, sempre insere um BOM UTF-8 (3 bytes invisíveis) no início — independente
de `$OutputEncoding` ou de qualquer configuração testada. O `sqlplus` e o parser HCL do Vault
leem esse BOM como parte do primeiro comando/linha e rejeitam ele inteiro.

**Correção** (`create-team-member.ps1`, `verify-environment.ps1`): abandonar o pipe. O
conteúdo (SQL ou política HCL) é convertido para **base64** e passado como um argumento comum
de linha de comando (que não sofre esse problema), decodificado **dentro do container** antes
de ser repassado pro `sqlplus`/`vault`:
```powershell
function Invoke-SqlPlus {
    param([string]$ConnectString, [string]$Sql)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Sql)
    $b64 = [Convert]::ToBase64String($bytes)
    $innerCmd = 'echo ' + $b64 + ' | base64 -d | sqlplus -s "$ORACLE_CONNSTR"'
    return docker exec -i -e ORACLE_CONNSTR="$ConnectString" kawashi-oracle sh -c "$innerCmd" 2>&1
}
```
A connect string (com a senha) vai por variável de ambiente (`-e`), não embutida na string do
shell — evita que caracteres especiais da senha (`%`, `^`, etc.) sejam interpretados por
engano pelo shell dentro do container (testamos isso separadamente: `cmd.exe` corrompe `^`
silenciosamente mesmo dentro de aspas, por isso não usamos `cmd /c "... < arquivo"` como
alternativa).

## 6. Argumento `-path=$Variavel` não interpola dentro de função com `ValueFromRemainingArguments`

**Sintoma:** o engine de segredos do Vault foi criado com o nome **literal** `$KvEnginePath`
(o texto da variável) em vez do valor `kawashi-secrets` — toda tentativa de acessar
`kawashi-secrets/...` retornava 403, porque esse caminho simplesmente não existia.

**Causa raiz:** peculiaridade do parser do PowerShell — quando um argumento passado para uma
função (não um cmdlet nativo) começa com `-` e contém uma variável (`-path=$Var`), o parser
trata o token inteiro como um possível nome de parâmetro e **não interpola a variável**. Isso
só acontece nesse cenário específico (função customizada com `ValueFromRemainingArguments`) —
confirmamos que chamar `docker` (comando nativo) diretamente com o mesmo padrão funciona bem.

**Correção** (`vault-init.ps1`): colocar o argumento entre aspas duplas força a interpolação
acontecer antes do parser tratar o `-` como flag:
```powershell
# Antes (quebrado): Invoke-VaultCommand secrets enable -path=$KvEnginePath -version=2 kv
# Depois (correto):
Invoke-VaultCommand secrets enable "-path=$KvEnginePath" "-version=2" kv
```

## 7. `-notmatch` num array do PowerShell não verifica o texto inteiro

**Sintoma:** o script tentava habilitar o método `userpass` do Vault mesmo já estando
habilitado, com o erro (inofensivo, mas indevido):
```
Error enabling userpass auth: ... path is already in use at userpass/
```
E, em tese, o mesmo padrão poderia mascarar um objeto PL/SQL realmente inválido no
`verify-environment.ps1` (não chegamos a observar isso na prática, mas o bug permitiria).

**Causa raiz:** `docker exec` retorna a saída como um **array de linhas** no PowerShell.
`-match`/`-notmatch` aplicado a um array filtra elemento por elemento, não testa "o texto
inteiro contém X" — `-notmatch 'userpass/'` num array de várias linhas quase sempre retorna
"verdadeiro" (porque quase sempre sobra alguma linha que não contém aquele texto), mesmo que
UMA das linhas contenha.

**Correção** (`create-team-member.ps1`, `verify-environment.ps1`): juntar o array numa única
string (`-join "\`n"`) antes de comparar:
```powershell
$authList = (docker exec ... ) -join "`n"
if ($authList -notmatch 'userpass/') { ... }
```

## Validação final

Depois de todas as correções, rodamos o fluxo completo do zero (`create-team-member.ps1
-Username JOAO_TESTE -Profile Desenvolvedor`) e confirmamos, através de login real via proxy
(`JOAO_TESTE[KAWASHI_ENV_DEV]`), que o usuário conseguia criar e derrubar uma tabela atuando
como o schema do ambiente, com a auditoria capturando corretamente `PROXY_USER = JOAO_TESTE`.
Todos os artefatos de teste foram removidos depois.
