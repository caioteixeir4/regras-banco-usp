# Bugs encontrados no primeiro teste real do ambiente

Todo o projeto foi escrito e revisado antes de existir um Oracle/Vault rodando de verdade
para testar contra. Na primeira subida real (`docker compose up` + `vault-init.ps1` +
`create-team-member.ps1`), apareceram **7 problemas reais** que nenhuma leitura de código
teria pego — só rodando de verdade. Este documento registra cada um: o sintoma, a causa raiz,
e a correção, para servir de referência caso algo parecido apareça de novo (ou para explicar,
numa apresentação/defesa, que o projeto foi validado na prática, não só no papel).

Mais problemas (itens 8 a 21 abaixo) apareceram depois, em rodadas seguintes de testes —
desta vez escrevendo e expandindo a suíte automatizada em `infra/tests/` (ver
`infra/tests/README.md`) em vez de testar na mão. Os itens 11 e 12 são os mais graves em termos de
auditoria (a trilha de segurança própria nunca tinha gravado uma única linha de verdade, desde o
primeiro boot); o item 15 é o mais grave em termos de controle de acesso (o próprio script de
onboarding permitia conceder `DBA` completo a qualquer conta, sem nenhuma resistência); o item 17
apareceu implementando a segmentação por serviço descrita em `infra/tests/README.md` e no item 16;
o item 18 é um teste preventivo (não um bug encontrado), escrito a pedido do usuário para garantir
que o problema do item 17 nunca aconteça no sentido inverso (padrão referenciando serviço); o
item 20 é uma decisão de arquitetura (separar este repositório de regras do repositório de
tabelas), registrada junto porque mexeu em arquivos, testes e contagens documentados acima; o
item 21 é a decisão de como a API entra no banco (conta de serviço por proxy).

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

## 15. `-Roles` do script de onboarding aceitava QUALQUER role, incluindo `DBA`

**Sintoma:** rodando `infra/tests/caixa-preta/Test-RolesPerigosasBloqueadas.ps1` (antes da
correção existir), o comando abaixo funcionava sem nenhuma resistência:
```powershell
./create-team-member.ps1 -Username ATACANTE -Profile Estagiario -Roles @('DBA')
```
Um usuário **Estagiário** — o perfil mais restrito do projeto — saía da criação com a role `DBA`
completa, confirmado consultando `DBA_ROLE_PRIVS` logo em seguida. Testado ao vivo, não é
hipotético.

**Causa raiz:** o parâmetro `-Roles` (pensado para "exceções pontuais", segundo seu próprio texto
de ajuda) era um `[string[]]` **sem nenhuma validação** — aceitava literalmente qualquer string,
incluindo roles nativas do Oracle com poder administrativo total (`DBA`, `SYSDBA`,
`IMP_FULL_DATABASE`, `EXP_FULL_DATABASE`, etc.). Isso tornava o script de onboarding do dia a dia
— pensado para criar contas de **baixo privilégio** — num caminho trivial de escalonamento para
privilégio **total**: qualquer pessoa capaz de rodar o script (ou seja, com acesso ao `.env`)
podia conceder DBA completo a si mesma ou a qualquer outra conta, contornando inteiramente o
modelo de RBAC (perfis Estagiário/Desenvolvedor/Infra/HomologViewer) que é a espinha dorsal deste
projeto.

**Correção** (`create-team-member.ps1`): adicionado `[ValidateSet(...)]` ao parâmetro `-Roles`,
restringindo-o às cinco roles **próprias** da Kawashi (`ROLE_KAWASHI_DEVELOPER`,
`ROLE_KAWASHI_INFRA`, `ROLE_KAWASHI_HOMOLOG_VIEWER`, `KAWASHI_READONLY`, `KAWASHI_READWRITE`) —
nenhuma delas chega perto de poder administrativo (a mais ampla, `ROLE_KAWASHI_INFRA`, só dá
`CREATE SESSION` + `SELECT ANY DICTIONARY`). Qualquer tentativa de passar uma role fora dessa
lista agora é rejeitada pelo **parâmetro do PowerShell**, antes de qualquer conexão com o
Oracle/Vault — o mesmo padrão de defesa já usado para `-Username`/`-Profile` (ver item de
`Test-InjecaoUsernamePerfil.ps1`).

## 16. (achado arquitetural, não um bug de código) Dentro do mesmo ambiente, qualquer pessoa pode apagar o que outra criou

**Pergunta que motivou a investigação:** "não é por que o usuário criou a tabela que ele vai
poder deletar ou fazer qualquer coisa nela - vai que pedimos para o estagiário criar uma tabela
simples que será usada em algum ponto do projeto, ele não pode ter toda essa liberdade nunca."

**Confirmado ao vivo** (`infra/tests/caixa-preta/Test-ControleColetivoDentroDoAmbiente.ps1`): dois
Estagiários **diferentes**, ambos proxyados em `KAWASHI_ENV_TESTE`, criaram e depois um apagou a
tabela do outro — sem nenhum erro, sem nenhuma restrição. O Estagiário B conseguiu `INSERT` e
`DROP TABLE` numa tabela que o Estagiário A tinha criado.

**Por que isso acontece:** autenticação por proxy faz a pessoa "virar" a identidade do **schema
do ambiente** (`KAWASHI_ENV_TESTE`) durante a sessão — e posse de objeto no Oracle (como em
qualquer banco relacional tradicional) é sempre do **schema que criou o objeto**, nunca da pessoa
que estava conectada na hora. Como todo mundo com perfil Estagiário proxya para o **mesmo**
`KAWASHI_ENV_TESTE`, todo objeto criado em TESTE pertence igualmente a qualquer um deles. O mesmo
vale para DEV, INFRA e HOMOLOG (cada um com seu próprio grupo compartilhado).

**Isto não é um bug do código Kawashi** — é uma característica de como o modelo de posse do
Oracle funciona, e não tem correção possível só revogando um privilégio pontual. Corrigir de
verdade exigiria uma mudança de arquitetura (por exemplo, cada pessoa com schema próprio e grants
objeto-a-objeto, em vez de identidade compartilhada por ambiente via proxy) — uma decisão de
design que cabe a quem mantém o projeto tomar, não a este teste.

**O que já contém esse risco hoje:** ele fica **limitado ao próprio ambiente** — reconfirmado no
mesmo teste que o Estagiário B continua sem nenhum acesso a DEV/INFRA/HOMOLOG/PROD. Ou seja,
"promover" algo de TESTE para DEV/HOMOLOG (saindo do alcance de quem criou em TESTE) é, hoje, a
única proteção real contra esse tipo de perda — **dentro** do mesmo ambiente, não existe proteção
nenhuma entre pessoas diferentes com o mesmo perfil.

## 17. `GRANT REFERENCES` habilita a FK mas não dá nenhuma permissão de leitura

**Sintoma:** implementando a segmentação por serviço (schemas padrão + SEFAZ/SIMPLES_NACIONAL,
ver `09_environments.sql` seção 2.1 e `11_exemplo_dominio_negocio.sql` — hoje
`11_fixture_contrato_segmentacao.sql`, ver item 20), um `Desenvolvedor` com
`-Servicos SEFAZ` conseguia criar a tabela de serviço com a foreign key apontando pra tabela
padrão (`CLIENTE`) sem problema — mas o primeiro `SELECT` com `JOIN` entre as duas, exatamente o
motivo de a FK existir, falhava:
```
ORA-41900: missing READ privilege on "KAWASHI_ENV_DEV"."CLIENTE"
```

**Causa raiz:** `REFERENCES` e `SELECT` são privilégios **completamente separados** no Oracle —
`REFERENCES` só habilita criar a *constraint* de chave estrangeira (o Oracle precisa confirmar
que a coluna referenciada é única/existe), não concede nenhum direito de **ler** os dados da
tabela referenciada. É perfeitamente possível (e foi exatamente o que aconteceu aqui) ter uma FK
válida e funcional sem conseguir fazer `SELECT` do outro lado dela.

**Correção** (`11_exemplo_dominio_negocio.sql`, hoje `11_fixture_contrato_segmentacao.sql`): além do `GRANT REFERENCES` já previsto, cada
schema de serviço recebe `GRANT SELECT` em **todas** as tabelas padrão do mesmo ambiente (não só
na que tem FK direta) — a ideia sendo que quem tem acesso a um serviço enxerga o padrão inteiro
daquele ambiente, não só o pedaço que uma FK específica toca.

## 18. (achado preventivo, não um bug) Faltava um teste de regressão pra invariante "padrão nunca referencia serviço"

**Pergunta que motivou a criação deste teste:** "não é interessante fazer testes? tipo para
garantir que nas tabelas padrões nunca tenha uma foreing key que está em um esquema lá na
frente" — ou seja, nada até agora impediria (nem avisaria) que alguém, por engano, criasse uma FK
no sentido contrário ao combinado na arquitetura (ver seção 2.1 de `arquitetura.md`): um schema
PADRÃO (`KAWASHI_ENV_DEV`, por exemplo) referenciando uma tabela dentro de um schema de SERVIÇO
(`KAWASHI_ENV_DEV_SEFAZ`). Isso quebraria a promessa central do desenho — o padrão ser reutilizável
por qualquer serviço novo sem precisar saber que aquele serviço existe.

**O que foi criado** (`infra/tests/caixa-branca/Test-InvarianteFkPadraoNuncaReferenciaServico.ps1`):
uma consulta a `DBA_CONSTRAINTS` que procura, nos 6 schemas de ambiente "puros"
(`KAWASHI_ENV_TESTE_DEV`, `_TESTE_INFRA`, `_DEV`, `_INFRA`, `_HOMOLOG`, `_PROD`), qualquer foreign
key cujo lado referenciado seja um schema `KAWASHI_ENV_%` que **não** seja um desses 6 — ou seja,
qualquer schema de serviço, presente ou futuro, sem precisar listar nomes um por um. Hoje essa
consulta não encontra nada (correto); se algum dia alguém adicionar uma FK no sentido errado, a
suíte automatizada passa a falhar nela.

**Controles positivos incluídos** (pra provar que a consulta não "passa" só por estar vazia por
acidente): confirma que as FKs serviço→padrão conhecidas realmente existem no sentido certo —
`KAWASHI_ENV_DEV_SEFAZ` → `KAWASHI_ENV_DEV`, `KAWASHI_ENV_DEV_ADMINISTRACAO` → `KAWASHI_ENV_DEV`, e
`KAWASHI_ENV_DEV_LOGIN` → `KAWASHI_ENV_DEV_ORGANIZACOES`.

**Contexto:** escrito na mesma rodada em que três novos schemas de exemplo foram adicionados
(`ORGANIZACOES`, `LOGIN`, `ADMINISTRACAO` — `12_exemplo_dominio_kawashi_core.sql`), pedidos
explicitamente como mais material de referência/teste do padrão padrão+serviço, sem aprofundar o
desenho de nenhum deles.

**Atualização (separação de repositórios, item 20):** esses 3 schemas e o `12` saíram deste
repositório. O teste continua aqui, como **contrato**, mas com 2 casos em vez de 5: a invariante
genérica e o controle positivo do SEFAZ. Os controles de `ADMINISTRACAO`/`LOGIN` e a conferência
dos 6 schemas dependiam de schemas que agora vivem no repositório de tabelas e devem voltar lá. A
versão original, com 5 casos, está na tag `dominio-completo-pre-separacao`.

## 19. (achado de metodologia, não um bug) `DBA_PROXIES` grava CLIENT/PROXY ao contrário do que o nome sugere

**Contexto:** implementando `infra/scripts/grant-service-access.ps1` (concede serviço a um
usuário que já existe, sem recriar a conta - pedido do usuário: "por padrão os perfis devem ter
acesso só a tabelas padrão, o serviço adicional deve ser posto separadamente ou incluído depois
em cada usuário"), o script precisa descobrir em quais ambientes um usuário já tem proxy,
consultando `DBA_PROXIES` em vez de perguntar o `-Profile` de volta (isso não fica gravado em
lugar nenhum do Oracle).

**Achado testando ao vivo:** `ALTER USER KAWASHI_ENV_DEV GRANT CONNECT THROUGH JOAO;` grava, em
`DBA_PROXIES`, `CLIENT = 'KAWASHI_ENV_DEV'` e `PROXY = 'JOAO'` — o **inverso** do que os nomes
das colunas sugerem à primeira vista (seria natural supor `CLIENT` = a pessoa que conecta,
`PROXY` = o schema). Uma consulta escrita com a intuição errada (`SELECT client FROM dba_proxies
WHERE client = 'JOAO'`) sempre retorna "no rows selected", mesmo com o proxy funcionando
perfeitamente na prática — silenciosamente parecendo que o usuário não tem acesso a nada.

**A consulta certa**, confirmada ao vivo criando um usuário de teste e inspecionando
`DBA_PROXIES` linha a linha: `SELECT client FROM dba_proxies WHERE proxy = 'JOAO'` — devolve os
ambientes (`KAWASHI_ENV_DEV`, `KAWASHI_ENV_HOMOLOG`, etc.) que `JOAO` já alcança.

**Não é bug de código** (nenhum script deste projeto usava `DBA_PROXIES` antes) — fica
registrado como nota de metodologia, pro caso de alguém escrever uma consulta nova contra essa
view no futuro e cair na mesma armadilha.

## 20. (decisão de arquitetura, não um bug) Separar as regras do banco das tabelas de negócio

**Contexto:** até o item 19 este repositório misturava dois assuntos com ciclos de vida
diferentes: as **regras** do banco (hardening, ambientes, RBAC por proxy, auditoria, onboarding,
Vault, testes) e **tabelas de negócio** de exemplo (`11` e `12`). Quando ficou claro que as
tabelas e uma API do banco vão ganhar vida própria, decidiu-se separá-las: regra muda pouco e com
revisão pesada (Infra/SecOps é dono), tabela muda toda semana (Dev é dono). Também dá casa
natural ao item adiado de sincronização de estrutura entre ambientes, que é um problema de
migração de schema do lado das tabelas.

**O que ficou neste repositório:** as 4 tabelas de controle de segurança (`03`:
`KAWASHI_ALLOWED_IPS`, `KAWASHI_FORBIDDEN_TOOLS`, `KAWASHI_SECURITY_LOG` e o fallback) e uma
**fixture mínima** de 2 tabelas (`11_fixture_contrato_segmentacao.sql`: `CLIENTE` e
`SEFAZ.CONFIGURACAO_FISCAL`, só em `TESTE_DEV`/`DEV`), suficiente pra os testes de segmentação,
de concessão de serviço e de invariante de FK terem o que exercitar.

**O que saiu:** `ENDERECO`, `CONTATO`, `EMPRESA`, `FILIAL`, `SOCIO` (resto do antigo `11`) e todo
o `12` (schemas `ORGANIZACOES`, `LOGIN`, `ADMINISTRACAO`), que irão pro repositório de tabelas.
Os controles do invariante de FK ligados a esses schemas saíram junto (5 casos → 2; suíte 250 →
247 casos, mesmos 35 arquivos).

**Nada foi descartado:** a tag git `dominio-completo-pre-separacao` (commit `cadb773`) guarda o estado completo de
antes (suíte de 250 casos verde, os dois SQL de domínio originais, o invariante de 5 casos e as
seções 2.1/2.2 originais de `arquitetura.md`). Conferido byte a byte na hora da separação.

**Criar conta de banco não depende de tabela de negócio:** a identidade de desenvolvedor vive no
dicionário do Oracle (`DBA_USERS`/`DBA_PROXIES`) e a senha no Vault; nenhum script de onboarding
grava em tabela de negócio. As únicas tabelas tocadas no caminho são as 4 de controle de
segurança: os triggers de auditoria gravam em `KAWASHI_SECURITY_LOG` (e no fallback) e o de logon
lê `KAWASHI_ALLOWED_IPS`/`KAWASHI_FORBIDDEN_TOOLS`. `LOGIN.USUARIO` (repositório de tabelas) será
o usuário do **site**, outro conceito.

**Pontos que a separação deixou em aberto** (também em Technical Debts no README):
1. *Como o repositório de tabelas é aplicado sobre este.* O `oracle-init` roda uma vez, no 1º
   boot, numa pasta só; as regras precisam subir antes das tabelas. Opções: script de aplicação
   pós-bootstrap (parecido com `vault-init.ps1`) ou submódulo. Não decidido; testar ao vivo
   antes.
2. *Onde mora a regra "serviço lê todas as tabelas padrão".* Hoje é um `GRANT SELECT` em loop no
   `11`, que roda uma vez e não alcança tabelas padrão criadas depois (consequência direta do
   achado do item 17). Pode virar uma procedure de regra exposta aqui e chamada pelo repositório
   de tabelas.
3. *Conta de API por ambiente.* Só existia uma conta de API (`KAWASHI_SPRING_USER`), sem relação
   com os 6 ambientes. **Resolvido no item 21.**

## 21. (decisão de arquitetura, não um bug) A API entra no banco por proxy, com uma conta de serviço por ambiente

**Contexto:** o item 20 deixou em aberto como a API (agora no repositório `tabelas-api-banco-usp`)
se conecta ao Oracle. A única conta de aplicação era a `KAWASHI_SPRING_USER`, criada antes do modelo
de ambientes, com schema e tablespace próprios, fora dos 6 ambientes.

**Decisão:** a API usa o mesmo caminho das pessoas, com o perfil de serviço. O script
`infra/scripts/create-api-account.ps1` cria uma conta (`KAWASHI_SERVICE_PROFILE`, só
`CREATE SESSION`, sem tablespace nem quota) e concede `CONNECT THROUGH` no schema do ambiente. A
API conecta como `CONTA[KAWASHI_ENV_<AMBIENTE>]` com a senha da própria conta, que fica no Vault em
`kawashi-secrets/api/<conta>`. Produção fica de fora, igual às pessoas. Uma conta de API não é uma
pessoa em nada que importa ao Oracle: o pool JDBC precisa de mais de 3 sessões (item 14) e não
responde ao prompt de senha expirada (item 4), então reaproveitar o `create-team-member.ps1` não
servia.

**Verificado ao vivo (não era certo de antemão):**
1. O driver JDBC thin da Oracle aceita a sintaxe de proxy direto no nome do usuário
   (`CONTA[SCHEMA]`), sem código especial, e o pool HikariCP abre sessões proxyadas normalmente.
2. O schema corrente da sessão é o do ambiente (`SYS_CONTEXT('USERENV','CURRENT_SCHEMA')`) e o
   Oracle registra a conta como `PROXY_USER`, então a auditoria continua sabendo quem entrou.
3. O Flyway da API consegue criar tabelas pela sessão proxyada, e o Hibernate com
   `ddl-auto=validate` enxerga as tabelas do schema do ambiente.

**Pegadinha repetida:** o primeiro rascunho do teste leu a mensagem de erro do Vault como se fosse a
senha, porque `-field=$Campo` escrito direto numa chamada nativa do PowerShell não interpola (a
mesma armadilha do item 6). A correção é montar o argumento antes numa string.

**Teste:** `infra/tests/caixa-preta/Test-ContaApiViaProxy.ps1`, 15 casos (a suíte vai de 247 para
262).

**Limitação conhecida:** a conta que roda o Flyway tem DDL no schema do ambiente, como qualquer
proxy desse ambiente (item 16). Separar a conta de migração da conta de execução da API fica para
depois.

## 22. (decisão de arquitetura, não um bug) Sai a segmentação por serviço de exemplo; entra o schema de log da aplicação

**O que mudou.** Duas coisas, na mesma rodada:

1. **Removidos** os schemas de serviço de exemplo (`KAWASHI_ENV_<AMBIENTE>_SEFAZ` e
   `_SIMPLES_NACIONAL`, 12 ao todo), a fixture `CLIENTE` + `SEFAZ.CONFIGURACAO_FISCAL`
   (`11_fixture_contrato_segmentacao.sql`), o parâmetro `-Servicos` de `create-team-member.ps1` e de
   `create-api-account.ps1`, o script `grant-service-access.ps1` e os três testes que dependiam
   deles. Motivo: eram só material de teste do padrão "padrão + serviço" (itens 17, 18 e 20), e o
   modelo de dados real, definido depois, não usa esses serviços. Os itens anteriores que falam
   deles ficam como histórico do caminho.
2. **Criado** um schema `KAWASHI_ENV_<AMBIENTE>_LOG` por ambiente (`11_schema_log.sql`) com os logs
   da API: `LOG_ALTERACAO` (quem mudou qual registro), `LOG_ACESSO` (cada chamada) e a tabela de
   controle `LOG_CADEIA`.

**Por que as tabelas de log são criadas aqui e não pelo repositório da API.** É a única exceção à
regra do item 20 ("tabelas de negócio no outro repositório"), e é de propósito: quem é DONO de uma
tabela sempre consegue alterar e apagar as linhas dela. A API entra no banco como o schema do
ambiente; se o Flyway dela criasse as tabelas de log, ela seria dona, e "a API só insere no log"
seria uma promessa do código. Com o dono sendo um schema em que ninguém loga (`NO AUTHENTICATION`,
sem `CREATE SESSION`, sem proxy) e o schema do ambiente recebendo só `INSERT` e `SELECT`, a regra
passa a ser uma permissão do banco.

**Encadeamento.** Um trigger `BEFORE INSERT`, que roda como o dono, numera cada linha de
`LOG_ALTERACAO` sem buraco (`ORDEM`), carimba a hora do servidor e grava
`HASH = SHA-256(hash da linha anterior + conteúdo)`. O que quem insere mandar nesses campos é
ignorado. A view `V_LOG_ALTERACAO_QUEBRAS` devolve uma linha por problema (conteúdo alterado, linha
do meio apagada, linhas do fim apagadas) e fica vazia quando a corrente está inteira.

**Achado ao testar ao vivo.** A recusa de `UPDATE`/`DELETE` aparece com dois códigos, conforme o
cliente: `ORA-01031` pelo `sqlplus` e `ORA-41900` ("falta o privilégio UPDATE em ...") pelo JDBC do
Oracle 23. Os testes dos dois repositórios aceitam os dois.

**Limites conhecidos.**
- Quem tem `DBA` consegue recalcular a corrente inteira. O encadeamento protege contra adulteração
  parcial e contra a própria aplicação; contra um DBA mal-intencionado a defesa é a trilha de
  auditoria do banco (`KAWASHI_SECURITY_LOG`), que registra o que ele fez.
- O trigger trava a linha de controle até o fim da transação de quem insere: as gravações de log de
  um mesmo ambiente acontecem uma de cada vez.
- Os scripts de `oracle-init` só rodam no primeiro boot do container. No banco que já existia, a
  remoção dos 12 schemas e a criação dos schemas de log foram aplicadas à mão, rodando o mesmo
  `11_schema_log.sql` (ele é idempotente).

**Verificação.** `Test-SchemaLogSomenteInsercao.ps1` (16 casos) entra como uma conta de API de
verdade e tenta alterar, apagar, esvaziar, desligar o trigger, ler a tabela de controle e logar no
schema de log; depois, como DBA, faz as três adulterações e confere que a view acusa cada uma. A
suíte completa ficou com 262 casos em 34 arquivos, todos passando.

## 23. (endurecimento, não um bug) A API deixa de rodar como dona das tabelas, e o log ganha uma âncora fora do banco

**Problema 1: a conta que atendia os pedidos podia apagar as tabelas.** O item 21 colocou a API no
banco por proxy no schema do ambiente. Quem entra assim age como o DONO, e o dono de uma tabela
sempre pode apagá-la: `DROP` não exige privilégio nenhum sobre objeto próprio, e restringir roles no
proxy não muda isso. Era a "limitação conhecida" registrada no próprio item 21.

**Correção.** Um schema novo por ambiente, `KAWASHI_ENV_<AMBIENTE>_APP` (`09_environments.sql`, seção
2.1): `NO AUTHENTICATION`, só `CREATE SESSION`, sem quota, sem objetos. E duas contas de API por
ambiente, escolhidas por `create-api-account.ps1 -Papel`:

- **Execução** (padrão): proxy no schema `_APP`. É a que atende os pedidos. Só tem o que o dono das
  tabelas concede a `_APP`: `SELECT`/`INSERT`/`UPDATE`/`DELETE` nas tabelas de cadastro (concedidos
  pela migração da API, depois de criá-las) e `INSERT`/`SELECT` no schema de log.
- **Migração**: proxy no schema do ambiente, o dono. Só é usada na subida da aplicação.

O schema de log passou a conceder acesso só a `_APP`; o schema do ambiente (a conta de migração e as
pessoas) não lê nem grava log.

**Problema 2: quem tem DBA recalculava a corrente do log sem deixar rastro.** Era o "limite honesto"
do item 22: a view de conferência compara o banco com ele mesmo.

**Correção.** `scripts/ancorar-log.ps1` guarda no Vault (`kawashi-secrets/log-ancora/<AMBIENTE>`) o
número e o hash da última linha de `LOG_ALTERACAO`. Com `-Acao Conferir` ele compara o banco com a
âncora e sai com código 1 se a linha ancorada mudou, sumiu, ou se o log encolheu. Com `-Acao Ancorar`
ele confere primeiro e **se recusa a ancorar por cima de uma divergência**.

**Limites conhecidos.**
- No desenvolvimento o Vault roda em memória (a âncora some no restart) e o script usa o token root,
  que é do mesmo engenheiro que tem DBA. Em produção a âncora precisa ser gravada com uma credencial
  que o DBA não tem; do contrário as duas chaves estão na mesma mão.
- A âncora protege o que foi gravado **até** ela. O que veio depois ainda depende só do banco, então
  o script precisa rodar com frequência (agendado). Isso ainda não está automatizado.
- A conta de execução continua lendo e alterando todas as linhas de cadastro. Limitar por usuário e
  por empresa é papel do login e da autorização da API.

**Verificação.** `Test-ContaApiViaProxy.ps1` confirma que a conta de execução não cria tabela nem
entra como dona, e que a de migração cria e apaga. `Test-AncoraDoLog.ps1` faz o ataque de verdade:
como DBA, altera uma linha ancorada e recalcula a corrente inteira; confirma que a view interna volta
a ficar **vazia** (o ataque engana o encadeamento) e que a conferência contra o Vault o denuncia.

## 24. (bug real) O primeiro `ALTER SYSTEM` do `enable-tde.ps1` dava `ORA-01031` mesmo como SYSDBA

**Sintoma.** `ALTER SYSTEM SET WALLET_ROOT ... SCOPE = SPFILE` falhava com `ORA-01031: insufficient
privileges` quando enviado pelo script; o mesmo comando, de um arquivo dentro do container, dava
"System altered".

**Causa.** O script montava `sqlplus -s "/ as sysdba"` com aspas **duplas** dentro de um argumento
passado ao `docker exec ... sh -c`. O Windows PowerShell 5.1 remove aspas duplas internas ao chamar
um programa externo, então o `sqlplus` recebia `/`, `as` e `sysdba` como argumentos soltos e entrava
sem o papel de SYSDBA.

**Correção.** Aspas **simples** em volta de `/ as sysdba` (não são mexidas pelo PowerShell). O passo
do `WALLET_ROOT` também passou a reconferir o valor depois do reinício e falhar com mensagem clara se
continuar vazio.

## 25. (achado de projeto) Ninguém sabia quem era cada conta do banco nem quando a senha vencia

**Problema.** O Oracle guarda a conta, o perfil de senha e as datas, mas não o nome da pessoa nem o
cargo, e o único registro de "quem pediu o quê" era a memória de quem rodou o script. Conta de API
tem a senha sem validade (de propósito), então ninguém seria avisado de que ela passou dos 90 dias.

**Correção.** `12_cadastro_de_contas.sql` (tabela `KAWASHI_CONTA`, procedure de escrita, função da
regra de senha, duas visões) e `scripts/cadastro-de-contas.ps1`. Os dois scripts de criação passaram
a cadastrar a conta na mesma execução (`-Nome`, `-Cargo`, `-Responsavel`).

**Dois cuidados que viraram teste.** (1) Para testar os 90 dias sem esperar, a primeira ideia foi
envelhecer a data no dicionário (`SYS.USER$`), e o Oracle 23ai recusa até para SYS (`ORA-41900`).
A regra foi para uma função que recebe a idade como parâmetro, testada nas fronteiras (74, 75, 90, 91
dias). (2) Nome com acento virava `?` porque o `sqlplus` do container lia o texto como ASCII; os
scripts passaram a mandar `NLS_LANG=AMERICAN_AMERICA.AL32UTF8`.

**Verificação.** `Test-CadastroDeContas.ps1` (24 casos) e `Test-CriptografiaEmDisco.ps1` (12 casos).
O TDE também foi conferido depois de um reinício real do Docker: o keystore abriu sozinho.

## 26. (exposição real) Banco e Vault abertos para a rede, e um banco sem volume de dados

**Problema.** O `docker-compose.yml` publicava `"1521:1521"` e `"8200:8200"`. Sem o IP na frente, o
Docker publica em **todas** as interfaces da máquina: qualquer um no mesmo Wi-Fi (escritório,
faculdade) alcançava o Oracle e o Vault, que no modo dev responde em HTTP puro e aceita o token root.

**Correção.** `"127.0.0.1:1521:1521"` e `"127.0.0.1:8200:8200"`. Teste: `Test-PortasSoNaMaquinaLocal.ps1`
(lê o compose). Conferência ao vivo: a `rotina-diaria.ps1` acusa todo dia a porta exposta no
container que está rodando.

**O achado maior, encontrado ao tentar aplicar.** Mudar a porta publicada exige recriar o container,
e o container do Oracle **não tem volume de dados**: o banco inteiro mora na camada gravável do
container. Recriar apagaria ambientes, contas, cadastro e a chave do TDE. Por isso a correção está no
arquivo, mas o container atual continua publicando para a rede até uma recriação planejada (com o
banco preservado ou reconstruído de propósito). Até lá, a rotina diária mantém o alerta.

## 27. (bug real) A busca das sessões abertas por proxy no desligamento não achava nada

**Sintoma.** No primeiro teste do `remove-team-member.ps1`, a sessão aberta por proxy continuava
viva depois do desligamento, e o próprio teste dizia que não sobrava sessão nenhuma.

**Causa.** Duas. (1) A procedure procurava a sessão por proxy cruzando `UNIFIED_AUDIT_TRAIL.SESSIONID`
com `v$session.AUDSID`, supondo que fossem o mesmo número; não são. (2) O teste contava as sessões
com a **mesma** busca da procedure, então o erro de uma escondia o da outra.

**Correção.** A ligação certa é o processo do servidor: a auditoria de logon grava `OS_PROCESS`, e o
`v$process.SPID` diz qual processo atende cada sessão. A sessão é da pessoa quando o último logon
auditado naquele processo foi feito por proxy por ela (o "último" evita confundir com um processo
antigo de mesmo número e não depende de fuso horário). O teste passou a marcar as próprias sessões
com um módulo (`DBMS_APPLICATION_INFO`) e contar por essa marca, independente da procedure.

**Achado extra.** `ALTER SYSTEM KILL SESSION ... IMMEDIATE` devolve `ORA-00031` ("session marked for
kill") mesmo quando a sessão cai; a procedure conta esse caso como sessão derrubada.

## 28. (bug real) A rotina diária funcionava no terminal e morria no Agendador de Tarefas

**Sintoma.** Disparada pelo Agendador, a tarefa terminava com código 1 em segundos e sem relatório.

**Causa.** O Agendador chama o script com `powershell -File`. Nesse modo, no Windows PowerShell 5.1,
`$PSScriptRoot` ainda está vazio no bloco `param`, então o valor padrão `Join-Path $PSScriptRoot ...`
falhava antes da primeira linha útil. Pelo terminal (`& script.ps1`) o problema não aparece.

**Correção.** A pasta do script passou a ser calculada no corpo, com `$MyInvocation.MyCommand.Path`.
O teste passou a chamar a rotina com `-File`, do jeito que o Agendador chama. Disparo real pelo
Agendador depois da correção: código 0 e relatório gravado.

## 29. (lacuna de processo) O painel cobrava a troca da senha da API, mas não havia como trocar

**Problema.** O cadastro de contas (item 25) marca `VENCIDA` a senha de API com mais de 90 dias,
mas trocar era manual: alterar no Oracle, no Vault e no `.env`, e a API caía entre a troca no banco
e o reinício com a senha nova.

**Correção.** `scripts/rotate-api-password.ps1` e `PASSWORD_ROLLOVER_TIME 1` no
`KAWASHI_SERVICE_PROFILE` (troca gradual do Oracle 23ai): logo depois da troca, a antiga e a nova
valem juntas, e `-EncerrarSenhaAntiga` corta a antiga depois do reinício. O painel mostra a troca em
andamento como pendência.

**Verificação.** `Test-RotacaoSenhaApi.ps1` (13 casos). Conferido quebrando de propósito: com a
troca gradual desligada no perfil, 4 casos falham (a senha antiga deixa de entrar logo depois da
troca, ou seja, a API rodando cairia).

## 30. (bug real, pego pelo próprio teste) Reler o listener deixava o banco inalcançável pela rede

**Sintoma.** Depois de `lsnrctl reload`, toda conexão pela rede falhava com `ORA-12514: Service
FREEPDB1 is not registered with the listener`, por alguns segundos ou mais. A primeira aplicação do
`apply-network-hardening.ps1` passou por sorte de tempo; o teste, que desfaz e aplica de novo, pegou.

**Causa.** O reload faz o listener esquecer os serviços que o banco tinha registrado dinamicamente.
O banco só se registra de novo no ciclo dele.

**Correção.** Depois de todo reload, o script manda `ALTER SYSTEM REGISTER` pela conexão local (que
não depende do listener), e o teste de conexão espera até 30 s se o erro for só `ORA-12514`. Se
mesmo assim a conexão falhar, o script volta os arquivos originais. Durante o incidente, o banco
ficou fora da rede até o `ALTER SYSTEM REGISTER` manual, que o devolveu na hora.

## 31. (bug real e grave, pego pelo teste) Token vencido continuava valendo por mais 5 horas

**Sintoma.** No primeiro teste do login, um token com `EXPIRA_EM` 5 minutos no passado ainda abria a
API. O mesmo acontecia com o bloqueio da conta: ele durava 5 horas e meia, e não 30 minutos.

**Causa.** As colunas de hora são `TIMESTAMP` (sem fuso), gravadas com `SYSTIMESTAMP` (que no
servidor está em UTC). A comparação `EXPIRA_EM > SYSTIMESTAMP` mistura os dois tipos, e o Oracle
converte a coluna para `TIMESTAMP WITH TIME ZONE` usando o fuso da **sessão** de quem consulta. A
sessão da API (driver JDBC) usa o fuso do Windows, −05:00: a coluna era lida como 5 horas mais tarde
do que de fato era. Num servidor e numa API no mesmo fuso o defeito nem apareceria, e por isso seria
fácil passar para produção.

**Correção.** Tudo em UTC explícito: as colunas nascem com `SYS_EXTRACT_UTC(SYSTIMESTAMP)`, os
gatilhos gravam assim, e toda comparação da API e do job de limpeza usa o mesmo. As respostas da API
trazem a hora com `Z`.

**Verificação.** O `LoginApiTest` força a sessão do banco em −05:00 antes de cada teste (com a sessão
em UTC o defeito ficaria escondido). Conferido quebrando de propósito: com **uma** comparação de volta
para `SYSTIMESTAMP`, o teste do token vencido falha (o token entra com `200`).

Quando o login passou a ser por passkey (20/11/2026), o `LoginApiTest` saiu e, com ele, essa trava. O
`PasskeyApiTest` a recuperou: sessão em −05:00 antes de cada teste, token vencido e desafio vencido.
Conferido de novo quebrando de propósito as comparações do token e do desafio (cada uma derrubou o seu
teste). Lição: ao reescrever um módulo, os testes que nasceram de um bug real precisam ir junto.

## 32. (bug real) Oito scripts e o executor dos testes não rodavam com `powershell -File`

**Sintoma.** Depois de um reinício do Docker, o `vault-init.ps1` chamado com
`powershell -File .\infra\scripts\vault-init.ps1` morreu antes de começar: `Join-Path` com caminho vazio.

**Causa.** Com `[CmdletBinding()]`, no Windows PowerShell 5.1 chamado com `-File`, o `$PSScriptRoot`
(e o `$MyInvocation.MyCommand.Path`) ainda estão vazios quando os valores padrão do bloco `param` são
calculados. Sem `[CmdletBinding()]` o problema não aparece, e chamando de dentro de outro script
(`& .\script.ps1`) também não: por isso ninguém viu. É o mesmo defeito do item 28 (a rotina diária no
Agendador), que tinha sido corrigido só naquele script.

**Correção.** Nos oito scripts (`ancorar-log`, `cadastro-de-contas`, `create-api-account`,
`create-team-member`, `enable-tde`, `remove-team-member`, `vault-init`, `verify-environment`) e no
`Run-AllTests.ps1`, o padrão do `-EnvFile` saiu do `param` e é calculado logo depois, no corpo do
script. Os 43 arquivos de teste têm o mesmo padrão, mas são chamados pelo executor dentro do mesmo
processo e sempre com `-EnvFile`, então não foram mexidos.

**Verificação.** Reproduzido com um script mínimo (com e sem `[CmdletBinding()]`); depois da correção,
`vault-init.ps1` e `Run-AllTests.ps1` rodaram com `-File` (suíte: 375 de 375).

## 33. (armadilha) O Vault de desenvolvimento esquece tudo quando o Docker reinicia

Num reinício do Docker Desktop, os contêineres voltaram sozinhos. O Oracle manteve os dados (o
contêiner é o mesmo, só reiniciou). O Vault, em modo `-dev`, voltou **vazio**: sem o engine
`kawashi-secrets`, toda gravação dava `403` ("preflight capability check"), uma mensagem que parece
falta de permissão e não é. Depois de qualquer reinício: `vault-init.ps1` (repõe o engine e a cópia
da chave do TDE), `gerar-chaves-de-cifra.ps1 -SoCopiarParaOVault` e
`gerar-segredo-do-bff.ps1 -SoCopiarParaOVault` (no repositório da API). A rotina diária já avisa quando
o Vault foi reiniciado.

## Validação final

Depois de todas as correções, rodamos o fluxo completo do zero (`create-team-member.ps1
-Username JOAO_TESTE -Profile Desenvolvedor`) e confirmamos, através de login real via proxy
(`JOAO_TESTE[KAWASHI_ENV_DEV]`), que o usuário conseguia criar e derrubar uma tabela atuando
como o schema do ambiente, com a auditoria capturando corretamente `PROXY_USER = JOAO_TESTE`.
Todos os artefatos de teste foram removidos depois.
