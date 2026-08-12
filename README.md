# Kawashi Sistemas - Infrastructure & SIEM Fortress 🏯

Este repositório contém a infraestrutura de segurança e o sistema de monitoramento (SIEM)
focado em banco de dados para a Kawashi Sistemas.

## 🚀 Arquitetura Geral
O projeto utiliza um modelo de defesa em camadas (Defense in Depth) para proteger
ativos de dados críticos. Para diagramas (containers/rede, ambientes de ciclo de vida e o
fluxo de onboarding via Vault), veja [`infra/docs/arquitetura.md`](infra/docs/arquitetura.md).

## ▶️ Como subir o ambiente (primeira vez)

1. Copie `infra/.env.example` para `infra/.env` e preencha com valores reais (senhas fortes,
   sem `$` nem `#` — ver comentários do próprio arquivo).
2. `docker compose up` dentro de `infra/` — aguarde o container `kawashi-oracle` ficar
   `healthy` (`docker ps`), pode levar alguns minutos no primeiro boot.
3. Rode `infra/scripts/verify-environment.ps1` — confirma que os 9 scripts de bootstrap
   compilaram sem erro (muito PL/SQL aqui nunca tinha rodado contra um Oracle de verdade).
4. Rode `infra/scripts/vault-init.ps1` — o Vault sobe "vazio" toda vez (modo dev), esse
   script configura o engine de segredos e o login por usuário/senha.
5. Para dar acesso a alguém (inclusive você mesmo, se quiser um perfil além do `ENGINEER_USER`),
   use `infra/scripts/create-team-member.ps1` — ver [`infra/docs/criar-novo-usuario.md`](infra/docs/criar-novo-usuario.md).

## ✅ O que já está implementado

### Banco de dados e hardening (bootstrap automático)
Tudo abaixo roda sozinho na primeira inicialização do container Oracle, via os scripts
numerados em [`infra/oracle-init/`](infra/oracle-init/) (`01` a `10` — os comentários de cada
arquivo explicam o "porquê" de cada peça, não só o "o quê"):

- Tablespaces separadas para dados de negócio, logs de auditoria e cada ambiente de ciclo
  de vida, todas com `MAXSIZE` (nunca crescimento ilimitado) — `01`, `09`.
- Política de senha (12+ caracteres, maiúscula/minúscula/número/especial, sem o username) +
  profile de segurança (bloqueio por tentativas, expiração a cada 90 dias, histórico de
  reuso, idle time, limite de sessões — com `RESOURCE_LIMIT=TRUE` habilitado, sem o qual boa
  parte desses limites de sessão seriam ignorados pelo Oracle) — `02_global_hardening.sql`.
  Hardening mínimo (bloqueio por tentativa + política de senha) também aplicado ao profile
  `DEFAULT`, como rede de segurança para contas futuras criadas sem profile explícito.
- Unified Auditing nativo do Oracle para `CREATE/ALTER/DROP USER`, `GRANT/REVOKE`,
  `LOGON/LOGOFF` — `02_global_hardening.sql` — com purga automática configurada
  (`DBMS_AUDIT_MGMT`) para não crescer indefinidamente no `SYSAUX` — `10_advanced_hardening.sql`.
- Proteção contra força bruta na camada de protocolo (`SEC_MAX_FAILED_LOGIN_ATTEMPTS`),
  complementar ao bloqueio de conta por tentativa — `10_advanced_hardening.sql`.
- Pacotes de rede/arquivo/Java historicamente usados em ataques via SQL Injection
  (`UTL_HTTP`, `UTL_TCP`, `UTL_SMTP`, `UTL_INADDR`, `UTL_FILE`, `DBMS_JAVA`) tiveram o
  `EXECUTE` revogado de `PUBLIC` — `10_advanced_hardening.sql`.
- Trilha de auditoria própria (`KAWASHI_SECURITY_LOG` + tabela de fallback), alimentada por
  triggers de logon, logoff, DDL e concessão de privilégio — `03`, `04`, `05`.
- Regras contextuais de logon: whitelist de IP, janela de horário, blacklist de ferramentas
  cliente, bloqueio de contas de SO inseguras (`ROOT`/`ADMINISTRATOR`/`GUEST`) — `05`. As
  regras de IP e horário são fail-open em dev (só registram, não bloqueiam), com `TODO` no
  próprio código para travar quando o time/infraestrutura de produção estiver definida.
- Jobs agendados: purge de logs com mais de 90 dias, rebuild semanal de índices, e trava
  automática de contas inativas há mais de 90 dias (protegendo `SPRING_APP_USER` e
  `ENGINEER_USER` de serem trancadas por engano) — `07_maintenance_jobs.sql`.
- Least privilege: usuário de aplicação (`SPRING_APP_USER`/`KAWASHI_SPRING_USER`) sem
  privilégio de tablespace ilimitada, contas nativas de risco (`SCOTT`, `HR`, `DBSNMP`, etc.)
  trancadas — `06_access_management.sql`.
- Conta pessoal do engenheiro do projeto, separada do `SYS`/`SYSTEM`, com privilégio total
  (`DBA`) documentado como decisão temporária enquanto o desenvolvimento é solo — `08`.
- 5 ambientes de ciclo de vida (**Teste, Desenvolvimento, Infra, Homologação, Produção**)
  como schemas isolados logicamente, com acesso via *proxy authentication* — `09`.

### RBAC — perfis de acesso do time
Perfis prontos que já definem automaticamente em qual ambiente cada pessoa pode
ler/escrever, sem grant manual por tabela:

| Perfil | Ambientes liberados |
|---|---|
| `Estagiario` | Teste |
| `Desenvolvedor` | Desenvolvimento + Homologação |
| `Infra` | Infra + Homologação |
| `HomologViewer` | Homologação (somente leitura) |

Detalhes e racional completo: [`infra/oracle-init/09_environments.sql`](infra/oracle-init/09_environments.sql)
e [`infra/docs/criar-novo-usuario.md`](infra/docs/criar-novo-usuario.md).

### Onboarding sem senha passando por chat
[`infra/scripts/create-team-member.ps1`](infra/scripts/create-team-member.ps1) cria o usuário
Oracle, gera uma senha aleatória que só serve pro primeiro login, e guarda essa senha no
Vault — a pessoa nova recebe só um login temporário do cofre, nunca a senha em texto puro.
Veja [`infra/docs/onboarding-novo-membro.md`](infra/docs/onboarding-novo-membro.md) (guia da
pessoa nova) e [`infra/docs/criar-novo-usuario.md`](infra/docs/criar-novo-usuario.md) (guia do
administrador).

### Secret Management (Vault) — parcial
O Vault sobe via Docker com o engine KV `kawashi-secrets` e o método de login `userpass`
configurados **por código** ([`infra/scripts/vault-init.ps1`](infra/scripts/vault-init.ps1)),
não mais manualmente pela UI. Falta: nenhuma aplicação ainda lê segredo do Vault em runtime
(não existe app Spring Boot ainda), e as credenciais de app continuam estáticas — isso é o
item **Dynamic Credentials** no roadmap abaixo, ainda pendente.

### Hardening de rede — pronto pra aplicar, manual por segurança
Criptografia em trânsito (`SQLNET.ENCRYPTION`) e bloqueio de reconfiguração remota do
listener (`ADMIN_RESTRICTIONS_LISTENER`) estão documentados e prontos em
[`infra/oracle-network-config/`](infra/oracle-network-config/), com o passo a passo em
[`infra/docs/hardening-rede.md`](infra/docs/hardening-rede.md). Não rodam automaticamente no
boot de propósito — são mudanças em arquivo de rede do Oracle (`sqlnet.ora`/`listener.ora`),
não em SQL, e um erro ali derruba o listener inteiro. Aplique manualmente, só depois do
ambiente já ter subido limpo pelo menos uma vez.

## 📋 Master Blueprint (To-Do List)

Itens já cobertos (parcial ou totalmente) pela seção "O que já está implementado" acima
aparecem marcados como `[x]`/`[~]` aqui, sem repetir a explicação.

1. Camada de Infraestrutura e Banco de Dados (O Bunker)
- [~] Setup de 5 Bases: isolamento **lógico** feito (5 schemas + tablespaces + proxy
      authentication). Isolamento **físico** (PDBs ou containers/instâncias separadas) ainda
      pendente — depende da arquitetura de hospedagem (local vs AWS) ser decidida.
- [ ] TDE (Transparent Data Encryption): Configurar criptografia em repouso no nível de Tablespace para o "balde" do Java.
- [ ] Data Redaction: Configurar máscaras em tempo real (ex: ocultar dígitos de CPF/Cartão) baseadas na Role do usuário.
- [ ] VPD (Virtual Private Database): Criar políticas para que a equipe de infra nunca veja linhas de dados de documentos de negócio.
- [ ] Confidential Computing: Pesquisar o uso de Enclaves (Intel SGX) para processar dados na RAM de forma isolada.

2. Camada de Identidade e Acesso (As Chaves)
- [x] RBAC (Role-Based Access Control): perfis `Estagiario`/`Desenvolvedor`/`Infra`/`HomologViewer` implementados (ver acima).
- [~] Secret Management (Vault): infraestrutura do cofre pronta e configurada por código; falta a aplicação em si consumir os segredos em runtime.
- [ ] Dynamic Credentials: Configurar o Vault para gerar senhas que expiram em curto prazo para o microserviço.
- [ ] Zero Trust & MFA: Exigir segundo fator de autenticação para qualquer humano que tente acessar a base de Produção.

3. Camada de Processo e Governança (O Gatekeeper)
- [ ] Main Protection: Bloquear a branch main. Apenas o Engenheiro de Software faz o merge.
- [ ] SQL Linter no CI/CD: Script que valida se o .sql dos desenvolvedores usa o Tablespace correto e não tem comandos proibidos.
- [ ] Deploy Automatizado: O robô de CI/CD é o único com permissão de escrita estrutural (DDL) em Produção.

4. Camada de Monitoramento e Inteligência (O SIEM)
- [~] Audit de DDL: toda alteração estrutural (CREATE/ALTER/DROP) já é registrada em log (`KAWASHI_DDL_AUDIT_TRG`); falta um alerta ativo — hoje é log passivo, ninguém é notificado em tempo real.
- [~] UBA (User Behavior Analytics): regras básicas de contexto (IP, horário, ferramenta cliente) já existem e geram log; ainda não é análise comportamental de verdade (sem baseline por usuário, sem score de anomalia).
- [ ] Honeytables (Armadilhas): Criar tabelas isca (ex: ADMIN_SALARIES) e monitorar qualquer SELECT neles.
- [ ] SQL Watermarking: Inserir "marcas d'água" digitais nos dados exportados para rastrear a origem de possíveis vazamentos.
- [ ] WORM Logs (Imutabilidade): Enviar logs de auditoria para um storage externo onde ninguém (nem o DBA) possa apagar.

5. Camada de Resposta e Resiliência (O Escudo Ativo)
- [ ] Database Firewall: Interceptar queries no Spring para bloquear padrões de SQL Injection em tempo real.
- [ ] Rate Limiting: Bloquear usuários que tentem baixar um volume de dados desproporcional (Anti-Scraping).
- [ ] SOAR (Auto-Ban): Programar o SIEM para revogar o acesso de usuários que tocarem nas Honeytables.
- [ ] Kill Switch: Criar um comando de emergência para isolar o banco de dados em caso de ataque massivo detectado.
- [ ] Backup Health Check: Monitorar se os backups off-site estão sendo feitos e se o PITR (Point-in-Time Recovery) está funcional.

6. Camada Avançada (The Future)
- [ ] Homomorphic Encryption: Estudar a implementação de cálculos matemáticos em campos criptografados sem abrir os dados.

## 🩹 Technical Debts

- **Whitelist de IP (`KAWASHI_ALLOWED_IPS`) está em modo fail-open** — hoje só registra aviso,
  não bloqueia ninguém (ver `RAISE_APPLICATION_ERROR` comentado em
  [`infra/oracle-init/05_context_triggers.sql`](infra/oracle-init/05_context_triggers.sql)).
  **Antes de ativar o bloqueio de verdade**: cadastre o IP de toda máquina que precisa acessar
  o banco (inclusive a sua própria e a de cada pessoa do time) em `KAWASHI_ALLOWED_IPS` — o
  `ENGINEER_USER` **não é isento** dessa regra (diferente de `SYS`/`SYSTEM`), então esquecer
  esse passo trava até você mesmo, e quebra `create-team-member.ps1`/`vault-init.ps1`.
- **Sem backup nenhum ainda.** O `docker-compose.yml` não declara volume persistente pro
  Oracle — os dados vivem dentro do container. Isso é conveniente pra recriar o ambiente do
  zero (ver conversa sobre recriar usuários), mas significa que um `docker compose down -v`
  ou a remoção do container apaga tudo, **incluindo a trilha de auditoria** (`KAWASHI_SECURITY_LOG`)
  que é justamente o coração do SIEM. Sem PITR, sem RMAN, sem backup off-site — é literalmente
  o item "Backup Health Check" do roadmap abaixo, hoje na sua forma mais básica: nem backup
  existe ainda, não é só "verificar se está funcionando".
- No ambiente de dev, o `mlock` do Vault foi desativado por limitações do Docker Desktop. Reativar em ambiente Linux de produção.
- A conta pessoal do engenheiro do projeto (`ENGINEER_USER`, ver [`infra/oracle-init/08_engineer_account.sql`](infra/oracle-init/08_engineer_account.sql))
  recebeu `GRANT DBA` (privilégio total) por decisão consciente, enquanto o desenvolvimento é solo.
  Reduzir para privilégios explícitos assim que houver mais de uma pessoa operando o banco.
- Isolamento dos 5 ambientes (Teste/Dev/Infra/Homologação/Produção) é lógico, não físico —
  todos rodam na mesma instância Oracle hoje. Ver nota no item 1 do roadmap.
- Ainda não decidido: quando a aplicação Spring Boot for a produção de verdade, ela deve
  conectar contra o schema `KAWASHI_ENV_PROD` (o "Produção" deste modelo de ambientes), ou o
  `SPRING_APP_USER` atual continua sendo uma coisa à parte? Ver TODO em
  [`infra/oracle-init/09_environments.sql`](infra/oracle-init/09_environments.sql).

## 👤 Gestão de Usuários

Sempre que uma nova pessoa entrar no time e precisar de acesso ao Oracle, siga:
[`infra/docs/criar-novo-usuario.md`](infra/docs/criar-novo-usuario.md) (guia do administrador,
usa o script `infra/scripts/create-team-member.ps1`). A pessoa nova segue depois
[`infra/docs/onboarding-novo-membro.md`](infra/docs/onboarding-novo-membro.md) para pegar o
próprio acesso pelo Vault.

## ⚠️ Observações de Infraestrutura

### Vault — configuração precisa ser reaplicada a cada subida (modo dev)
O Vault roda em modo `-dev` (dados em memória, nada persiste). Toda vez que o container
`kawashi-vault` é recriado, rode `infra/scripts/vault-init.ps1` antes de criar qualquer usuário —
ele habilita o engine KV `kawashi-secrets` e o método de login `userpass` de forma idempotente
(pode rodar quantas vezes quiser). Esse script também documenta, em comentários, o que precisa
mudar quando o Vault for hospedado na AWS (storage persistente, auto-unseal, TLS, autenticação
via IAM em vez de usuário/senha).

### Vault — versão fixada em 1.15.6
Versões mais recentes do Vault (1.16+) utilizam `CAP_SETFCAP` no entrypoint,
uma Linux capability bloqueada pelo Docker Desktop no Windows/WSL2.
Isso causa crash silencioso do container sem mensagem de erro clara.

**Não alterar para `latest`** até confirmar compatibilidade com o ambiente de desenvolvimento.
Para atualizar, testar localmente e fixar numa versão específica (ex: `1.19.2`), nunca `latest`.
