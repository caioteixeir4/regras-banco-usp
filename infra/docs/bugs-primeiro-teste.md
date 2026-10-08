# Bugs encontrados no primeiro teste real do ambiente

Todo o projeto foi escrito e revisado antes de existir um Oracle/Vault rodando de verdade
para testar contra. Na primeira subida real (`docker compose up` + `vault-init.ps1` +
`create-team-member.ps1`), apareceram **7 problemas reais** que nenhuma leitura de código
teria pego — só rodando de verdade. Este documento registra cada um: o sintoma, a causa raiz,
e a correção, para servir de referência caso algo parecido apareça de novo (ou para explicar,
numa apresentação/defesa, que o projeto foi validado na prática, não só no papel).

Mais cinco problemas (itens 8 a 12 abaixo) apareceram depois, em rodadas seguintes de testes —
desta vez escrevendo e expandindo a suíte automatizada em `infra/tests/` (ver
`infra/tests/README.md`) em vez de testar na mão. Os itens 11 e 12 são os mais graves do
documento inteiro: a trilha de auditoria própria do projeto nunca tinha gravado uma única linha
de verdade, desde o primeiro boot.

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

## 8. Trigger de auto-grant em Homologação nunca funcionava de verdade (achado pela suíte de testes automatizados)

**Sintoma:** rodando `infra/tests/caixa-branca/Test-HomologAutograntTrigger.ps1` pela primeira
vez, **toda** `CREATE TABLE` feita via proxy dentro de `KAWASHI_ENV_HOMOLOG` falhava:
```
ORA-04088: error during execution of trigger 'KAWASHI_ENV_HOMOLOG.KAWASHI_HOMOLOG_AUTOGRANT_TRG'
ORA-00604: Error occurred at recursive SQL level 1. Check subsequent errors.
ORA-30511: invalid DDL operation in system triggers
```
Ou seja: o mecanismo pensado pra dar acesso automático ao QA na verdade **quebrava a própria
criação da tabela** — o único jeito de Homologação cumprir sua função.

**Causa raiz:** o corpo do trigger (`AFTER CREATE ON KAWASHI_ENV_HOMOLOG.SCHEMA`) rodava
`EXECUTE IMMEDIATE 'GRANT SELECT ON ...'` diretamente. O Oracle proíbe esse tipo de DDL (GRANT
incluso) de dentro de um trigger de schema que está reagindo a outra DDL — o objeto que disparou
o trigger ainda não terminou de ser gravado no dicionário de dados.

**Correção** (`09_environments.sql`): em vez de conceder o `GRANT` na hora, o trigger agora
agenda um job (`DBMS_SCHEDULER.CREATE_JOB`, execução imediata, `auto_drop => TRUE`) que roda o
`GRANT` milissegundos depois, numa sessão/transação separada — fora do contexto restrito do
trigger. Isso também exigiu conceder `CREATE JOB` ao schema `KAWASHI_ENV_HOMOLOG` (faltava no
conjunto de grants da seção 2), senão o agendamento falhava com `ORA-27486: insufficient
privileges`.

Também vale registrar uma pegadinha de metodologia de teste encontrada no caminho: a primeira
tentativa de reproduzir o cenário usava `ALTER SESSION SET CURRENT_SCHEMA = KAWASHI_ENV_HOMOLOG`
a partir do `ENGINEER_USER` para criar a tabela. Isso faz o objeto nascer com o dono certo, mas
**não dispara o trigger** — gatilhos `ON SCHEMA` reagem a quem é o usuário atual da sessão
(`CURRENT_USER`), não ao `CURRENT_SCHEMA`. Só autenticação por **proxy** de verdade (como um
Dev/Infra real faz) muda o `CURRENT_USER` o suficiente para o trigger disparar.

## 9. Senha gerada podia conter `@`, quebrando qualquer connect string Oracle

**Sintoma:** rodando `infra/tests/caixa-preta/Test-ConexaoNovoUsuario.ps1`, a conexão de um
usuário recém-criado falhava — mas não com erro de senha errada:
```
ORA-12262: Cannot connect to database. Could not resolve hostname <pedaço-da-senha>@ in
Easy Connect connection string <pedaço-da-senha>@//localhost:1521/FREEPDB1
```

**Causa raiz:** `New-StrongPassword` (`create-team-member.ps1`) sorteava caracteres especiais do
conjunto `!@#%^*-_=+?`, que inclui `@` — exatamente o caractere que separa `usuario/senha` do
`host` numa connect string Oracle no formato Easy Connect. Quando o `@` sorteado caía **dentro**
da senha, o parser do SQL\*Plus cortava ali, tratando o restante da própria senha como se fosse
o hostname. A senha em si era aceita pelo Oracle sem problema (não viola nenhuma regra de
`KAWASHI_PASSWORD_VERIFY`) — o problema só aparece na hora de usar essa senha dentro de um
`usuario/senha@host` digitado ou montado por script (exatamente o que uma pessoa faz ao copiar a
senha do Vault e conectar via `sqlplus`, ou o que uma JDBC URL monta por concatenação).

**Correção** (`create-team-member.ps1` e a cópia espelhada em `infra/tests/lib/TestHelpers.ps1`):
removido `@` do conjunto de caracteres especiais (`!#%^*-_=+?`, sem o `@`).

**Achado real, não só hipotético:** ao escrever `infra/tests/outros/Test-ConexaoAplicacaoSpring.ps1`,
a senha **já existente** de `SPRING_APP_USER_PASSWORD` no `.env` deste projeto continha `@` —
ela tinha sido definida manualmente antes dessa correção existir. A conexão da conta de aplicação
falhava com o mesmo `ORA-12262`. Corrigido ao vivo (mesmo padrão do item 4): gerada uma nova senha
compatível via `ENGINEER_USER`, aplicada com `ALTER USER ... IDENTIFIED BY`, e sincronizada no
`.env` — sem o valor passar pelo chat. Nesse processo, regravar o `.env` via `Set-Content
-Encoding UTF8` do PowerShell introduziu um **BOM UTF-8** no início do arquivo (o mesmo problema
do item 5, desta vez afetando um arquivo `.env` em vez de um script SQL/HCL enviado por pipe) —
percebido e corrigido na hora, regravando o arquivo com `UTF8Encoding($false)` (sem BOM).

## 10. Tentativa de onboarding "falha" podia conceder acesso de verdade a uma conta existente

**Sintoma:** rodando `infra/tests/caixa-preta/Test-UsuarioDuplicado.ps1`, criar um usuário com um
`-Username` que já existia, mas com um `-Profile` **diferente** do original, fazia o PowerShell
lançar erro (como esperado, por causa do `ORA-01920`) — mas, verificando os grants de proxy do
usuário já existente logo depois, ele tinha ganhado acesso aos ambientes do perfil novo **além**
dos do perfil original. Ou seja: uma operação que o administrador via como "falhou, não
aconteceu nada" na prática escalou o acesso de uma conta já existente.

**Causa raiz:** o bloco SQL de `create-team-member.ps1` manda várias instruções separadas por
`;` para o `sqlplus` de uma vez (`CREATE USER`, `ALTER USER ... QUOTA`, `GRANT CREATE SESSION`,
os `GRANT`/`ALTER USER ... CONNECT THROUGH` do perfil, `ALTER USER ... PASSWORD EXPIRE`). Por
padrão, o SQL\*Plus **não para no primeiro erro de um script** — ele só imprime o erro e segue
para a próxima instrução. Quando `CREATE USER` falhava (nome já existente), todas as instruções
seguintes rodavam normalmente contra a conta que **já existia**, incluindo os novos grants de
proxy do `-Profile` da tentativa (que não tinha nada a ver com o perfil original daquela conta).
O `throw` do PowerShell só detectava *que* algum `ORA-` apareceu na saída inteira — não *onde*,
nem que efeitos colaterais reais já tinham acontecido antes daquele ponto.

**Correção** (`create-team-member.ps1`): adicionado `WHENEVER SQLERROR EXIT SQL.SQLCODE` como
primeira linha do script SQL, para que o primeiro erro interrompa a execução imediatamente, sem
rodar nenhuma instrução seguinte.

## 11. A trilha de auditoria própria do projeto nunca gravou uma linha sequer

**Sintoma:** rodando `infra/tests/caixa-branca/Test-TrilhaSegurancaPropria.ps1` pela primeira
vez, **nenhum** evento esperado aparecia em `KAWASHI_SECURITY_LOG` — nem um login, nem uma DDL,
nada. Investigando a tabela de contingência (`KAWASHI_SECURITY_LOG_FALLBACK`), ela já tinha
**1.782 linhas** acumuladas, todas idênticas:
```
FALHA CRITICA NO LOG PRINCIPAL: ORA-02003: invalid USERENV attribute | EVENTO: PRIVILEGED_LOGIN
```
Ou seja: desde o primeiro boot deste projeto, **todo** evento de segurança (login, logoff, DDL,
concessão de privilégio) falhava ao tentar gravar na trilha principal e caía silenciosamente no
fallback — e como o fallback nunca é consultado por ninguém no dia a dia, essa falha passou
completamente despercebida por toda a vida do projeto até aqui.

**Causa raiz:** `KAWASHI_WRITE_SECURITY_LOG` (`04_security_procedures.sql`) chamava
`SYS_CONTEXT('USERENV', 'CLIENT_PROGRAM')` — **`CLIENT_PROGRAM` não é um atributo válido** de
`USERENV` (o nome correto é `CLIENT_PROGRAM_NAME`, que é exatamente o que o trigger de logon em
`05_context_triggers.sql` já usava corretamente). Essa única chamada levantava `ORA-02003`
toda vez, capturado pelo primeiro nível do `EXCEPTION WHEN OTHERS` da própria procedure (que
existe por design, para nunca travar um login por causa de um problema de log) — o que faz o
sintoma ser "silencioso" por construção: o mecanismo de fail-safe do log mascarou perfeitamente
o próprio bug do log.

**Correção** (`04_security_procedures.sql`): trocado para `SYS_CONTEXT('USERENV',
'CLIENT_PROGRAM_NAME')`.

## 12. `PRIVILEGE_GRANT_ALERT` nunca registrava quem recebeu o quê

**Sintoma:** depois de corrigir o item 11, o teste ainda falhava num ponto: um `GRANT
KAWASHI_READONLY TO <usuario>` gerava um registro de `PRIVILEGE_GRANT_ALERT`, mas o campo
`DETAILS` vinha **em branco** depois de "Beneficiado/Objeto: " — o evento mais sensível do
projeto (o que existe especificamente para flagrar escalonamento de privilégio) não dizia quem
recebeu o quê.

**Causa raiz:** `ORA_DICT_OBJ_NAME` (usado em `KAWASHI_PRIVESC_AUDIT_TRG`) só é populado para DDL
que modifica um **objeto de schema** (tabela, view, procedure...). Um `GRANT <role ou privilégio
de sistema> TO <usuário>` não tem "objeto" nesse sentido — é exatamente o tipo de concessão mais
perigoso (papéis e privilégios de sistema, não um `GRANT SELECT` pontual numa tabela), e é
também o único tipo onde `ORA_DICT_OBJ_NAME` sempre vem nulo.

**Correção** (`05_context_triggers.sql`): trocado `ORA_DICT_OBJ_NAME` por `ORA_SQL_TXT`, que
reconstrói o texto da própria instrução `GRANT` executada (funciona tanto para `GRANT` de
role/privilégio de sistema quanto de privilégio em objeto específico) — o log agora grava, por
exemplo, `"Comando: GRANT KAWASHI_READONLY TO TST_GRANTCHK_UKA5YW"`.

**Achado colateral (não é bug, mas vale documentar):** o mesmo teste tentou inicialmente
confirmar a isenção de `SYS`/`SYSTEM` conectando via `"/ as sysdba"` — isso nunca gera nenhum
evento em `KAWASHI_SECURITY_LOG`, porque uma conexão `AS SYSDBA` é autenticada por um caminho
(arquivo de senha/SO) que **não dispara nenhum trigger `AFTER LOGON ON DATABASE`**, por desenho
do próprio Oracle (precisa funcionar mesmo que um trigger de usuário esteja quebrado). A isenção
documentada no trigger só é observável de verdade com um login **normal** como `SYSTEM`
(`SYSTEM/$ORACLE_PASSWORD@//localhost:1521/FREEPDB1`), que o teste corrigido passou a usar.

## 13. Contas com role DBA não são protegidas pela REGRA 3 do trigger de logon (limitação do Oracle, não um bug de código)

**Achado:** rodando `infra/tests/caixa-preta/Test-BloqueioOsUserInseguro.ps1`, a única regra do
`KAWASHI_CONTEXT_SECURITY_TRG` que bloqueia de verdade (REGRA 3 — usuário de sistema operacional
`ROOT`/`ADMINISTRATOR`/`GUEST`) funciona perfeitamente para uma conta comum, mas **não bloqueia
nenhuma conta que tenha a role `DBA`** — confirmado criando um usuário descartável só com
`CREATE SESSION` (bloqueado, `ORA-20003`) e outro idêntico mas com `GRANT DBA` a mais (não
bloqueado, login aceito normalmente), ambos com o mesmo `OS_USER=root`.

**Causa:** não é nenhuma linha do código Kawashi — o trigger trata todas as contas da mesma
forma, exceto o `RETURN` explícito para `SYS`/`SYSTEM`. É uma característica do próprio
mecanismo de logon trigger do Oracle para sessões com privilégio suficiente (não aprofundamos a
peça exata do kernel responsável, mas o efeito é reproduzível e consistente).

**Por que isso importa:** `ENGINEER_USER` (a conta usada no dia a dia pelo engenheiro do projeto)
tem `GRANT DBA` — ou seja, exatamente a conta mais privilegiada do sistema é a única que este
controle não protege. Isso não tem correção possível dentro do trigger (a exceção não vem de lá);
fica registrado como teste e como nota de limitação conhecida, para ninguém presumir por engano
que esta regra cobre contas administrativas.

## 14. A conta de aplicação (Spring) não aguenta um pool de conexões de verdade

**Achado:** rodando `infra/tests/outros/Test-LimiteSessoesAplicacao.ps1`, abrir 4 conexões
simultâneas como `SPRING_APP_USER` (`KAWASHI_SPRING_USER`) faz a 4ª ser rejeitada com:
```
ORA-02391: exceeded simultaneous SESSIONS_PER_USER limit
```

**Causa:** a conta de aplicação usa `KAWASHI_SECURE_PROFILE` — o mesmo profile pensado para
contas de **pessoa** (`SESSIONS_PER_USER = 5` reduzido pra `3` no profile atual) — e isso nunca
tinha sido testado contra o uso real que essa conta vai ter: um **pool de conexões**. O
HikariCP (pool padrão do Spring Boot) abre **10 conexões** por padrão
(`spring.datasource.hikari.maximum-pool-size`). No dia em que o microsserviço de verdade subir
com a configuração padrão, ele vai falhar já na inicialização do pool, não em algum pico raro de
carga.

**Correção** (`02_global_hardening.sql`, `06_access_management.sql`): criado um profile separado
para contas de **serviço/aplicação**, `KAWASHI_SERVICE_PROFILE`, aplicado ao `SPRING_APP_USER` no
lugar de `KAWASHI_SECURE_PROFILE`. Mantém a mesma política de senha (`KAWASHI_PASSWORD_VERIFY`,
`FAILED_LOGIN_ATTEMPTS`, `PASSWORD_LOCK_TIME`, `PASSWORD_REUSE_*`), mas ajusta os limites que são
especificamente sobre *padrão de uso* (pessoa vs. pool):
- `SESSIONS_PER_USER = 50` (em vez de `3`) — acomoda um pool de conexões real (HikariCP = 10) com
  folga para múltiplas instâncias/réplicas da aplicação, mas ainda **finito** — continua servindo
  de rede de segurança contra um bug de vazamento de conexão crescendo sem limite nenhum.
- `IDLE_TIME = UNLIMITED` e `CONNECT_TIME = UNLIMITED` (em vez de `30` e `720`) — uma conexão
  *pooled* fica ociosa por natureza entre requisições, e pode legitimamente viver por dias;
  reciclagem de conexão é responsabilidade do próprio pool (`maxLifetime` do HikariCP), não do
  Oracle derrubando a sessão no meio do uso.
- `PASSWORD_LIFE_TIME = UNLIMITED` (em vez de `90`) — mesmo racional do item 4: não existe humano
  para responder a um prompt interativo de troca de senha quando ela expira sozinha. A rotação
  desta credencial é responsabilidade de quem administra o Vault, via `ALTER USER` explícito.

Confirmado com `infra/tests/outros/Test-LimiteSessoesAplicacao.ps1`: 8 conexões simultâneas de
verdade (mais que o padrão do HikariCP) agora são todas aceitas, nenhuma rejeitada por
`ORA-02391`.

## Validação final

Depois de todas as correções, rodamos o fluxo completo do zero (`create-team-member.ps1
-Username JOAO_TESTE -Profile Desenvolvedor`) e confirmamos, através de login real via proxy
(`JOAO_TESTE[KAWASHI_ENV_DEV]`), que o usuário conseguia criar e derrubar uma tabela atuando
como o schema do ambiente, com a auditoria capturando corretamente `PROXY_USER = JOAO_TESTE`.
Todos os artefatos de teste foram removidos depois.
