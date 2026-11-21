# Como criar um novo usuário de time (guia do administrador)

Sempre que uma nova pessoa for entrar no time e precisar de acesso ao Oracle da Kawashi,
**use o script abaixo** — não crie o usuário manualmente via `CREATE USER`. O script já aplica
todas as regras de segurança do projeto (profile, expiração de senha, roles) e entrega a senha
inicial pelo Vault, sem ninguém precisar mandar senha por chat.

Script: [`infra/scripts/create-team-member.ps1`](../scripts/create-team-member.ps1)
Guia que a pessoa nova vai seguir depois: [`infra/docs/onboarding-novo-membro.md`](onboarding-novo-membro.md)

## Pré-requisitos

- Docker Desktop com os containers no ar: `kawashi-oracle` e `kawashi-vault`
  (`docker compose up` dentro de `infra/`).
- `infra/.env` preenchido (`ENGINEER_USER`, `ENGINEER_USER_PASSWORD`, `VAULT_DEV_ROOT_TOKEN_ID`).
- **`infra/scripts/vault-init.ps1` já executado** nesta subida do ambiente. O Vault roda em
  modo dev (memória) — toda vez que o container `kawashi-vault` é recriado, o engine KV e o
  login `userpass` precisam ser habilitados de novo. Rode:

  ```powershell
  ./vault-init.ps1
  ```

  Esse script é idempotente: pode rodar de novo sem problema mesmo se já tiver sido feito.

## Comando

Rode a partir de `infra/scripts/`:

```powershell
./create-team-member.ps1 -Username NOME_SOBRENOME -Profile Desenvolvedor -Nome 'Nome Sobrenome' -Cargo 'Desenvolvedor Pleno'
```

- **`-Username`**: nome do novo usuário (letras/números/underscore, começando com letra).
  Vira o login do Oracle **e** o login pessoal do Vault.
- **`-Profile`** (obrigatório): define automaticamente em quais ambientes a pessoa pode
  trabalhar — ver tabela abaixo. É a forma recomendada de conceder acesso.
- **`-Roles`**: opcional, só para exceções pontuais além do que o `-Profile` já cobre.
- **`-Nome`** e **`-Cargo`**: vão para o cadastro de contas (`SYS.KAWASHI_CONTA`), junto com o
  perfil. São opcionais para não quebrar automação, mas a conta sem eles aparece com pendência no
  painel. Para completar depois: `./cadastro-de-contas.ps1 -Acao Registrar -Username ... -Nome '...' -Cargo '...'`.

### Quando a pessoa sai do time: desligamento

```powershell
./remove-team-member.ps1 -Username NOME_SOBRENOME -Motivo 'Fim do contrato'
```

Tira tudo de uma vez: tranca a conta (senha expirada), revoga o proxy em todos os ambientes, as
roles, os privilégios e as permissões em objetos, **derruba as sessões que ela tiver abertas**
(inclusive as abertas por proxy) e apaga do Vault o login, a policy e os segredos dela. O cadastro
passa a `DESLIGADA`, com data, quem desligou e o motivo (não escreva dado sensível no motivo).

- A conta fica trancada, não apagada, para a auditoria continuar ligada a ela. Para apagar, use
  `-Apagar`; o cadastro continua, como `DESLIGADA`.
- Se alguém destrancar a conta ou devolver um acesso a ela por fora, o painel e a rotina diária
  acusam como **ALARME**.
- Pode rodar de novo sem problema (o que já foi tirado não dá erro).
- Só vale para pessoas: conta de API, administrador e quem tem `DBA` são recusados.

### Depois de criar: o painel de contas

Toda conta criada (pessoa ou API) entra no cadastro na mesma execução. Para ver quem tem acesso a
quê e como está a senha de cada um contra o limite de 90 dias:

```powershell
./cadastro-de-contas.ps1                    # todas
./cadastro-de-contas.ps1 -Acao Alertas      # só pendências (código 1 se houver)
```

Pessoa: o Oracle bloqueia a conta quando a senha passa de 90 dias (com 7 de tolerância). Conta de
API: não expira sozinha; o painel marca `VENCIDA` e a rotação é manual.

Ninguém precisa lembrar de olhar: a **rotina diária** (`rotina-diaria.ps1`, agendada uma vez com
`./agendar-rotina.ps1`) roda os alertas todo dia às 9h, grava o relatório em `infra/logs/` e mostra
um aviso no Windows quando há pendência. Para mudar o horário: `./agendar-rotina.ps1 -Horario 08:30`;
para tirar: `./agendar-rotina.ps1 -Remover`.

### Perfis disponíveis hoje

Cada perfil dá acesso de leitura/escrita completo (`CREATE TABLE`, `SELECT`, `INSERT`,
`UPDATE`, `DELETE`) dentro do(s) ambiente(s) liberado(s) — nunca em outro, e ninguém além do
administrador (`ENGINEER_USER`) alcança Produção ou pode fazer `DROP TABLESPACE`/`DROP USER`.

| Perfil | Para quem | Ambientes liberados |
|---|---|---|
| `EstagiarioDev` | Estagiários do time de Desenvolvimento | **Teste-Dev** apenas |
| `EstagiarioInfra` | Estagiários do time de Infraestrutura | **Teste-Infra** apenas |
| `Desenvolvedor` | Desenvolvedores | **Desenvolvimento** + **Homologação** |
| `Infra` | Time de infraestrutura | **Infra** + **Homologação**, mais `ROLE_KAWASHI_INFRA` |
| `HomologViewer` | QA / negócio que só testa a tela | **Somente leitura (SELECT)** em Homologação |

**Por que Estagiário (Dev ou Infra) não tem acesso a Homologação nem Desenvolvedor/Infra tem
acesso a Teste?** A revisão do trabalho dos estagiários acontece no Git (pull request), não no
banco — quem já tem acesso a Desenvolvimento ou Infra aprova lendo o código, não os dados de
Teste, e só então promove pra Homologação. Ver o diagrama completo em
[`arquitetura.md`](arquitetura.md), seção 2.

Exemplo com role extra pontual:

```powershell
./create-team-member.ps1 -Username MARIA_SOUZA -Profile Infra -Roles ROLE_KAWASHI_DEVELOPER
```

Veja o racional completo (schemas, tablespaces, proxy authentication) em
[`infra/oracle-init/09_environments.sql`](../oracle-init/09_environments.sql).

## Criando as contas da API (não são pessoas)

A aplicação **não** usa `create-team-member.ps1`: uma conta de API precisa de perfil de serviço
(um pool JDBC abre 10 conexões, e o perfil de pessoa só aceita 3) e de senha que não expira (a
aplicação não consegue responder ao prompt de troca). Para ela existe um script próprio, e cada
ambiente tem **duas** contas:

```powershell
# conta de EXECUCAO: atende os pedidos; so le e grava linhas
./create-api-account.ps1 -Username API_TESTE_DEV_EXEC -Ambiente TESTE_DEV

# conta de MIGRACAO: entra como dona das tabelas; so e usada na subida, pelo Flyway
./create-api-account.ps1 -Username API_TESTE_DEV -Ambiente TESTE_DEV -Papel Migracao
```

- `-Ambiente`: `TESTE_DEV`, `TESTE_INFRA`, `DEV`, `INFRA` ou `HOMOLOG`. Produção fica de fora de
  propósito, igual às pessoas.
- `-Papel`: `Execucao` (padrão) ou `Migracao`.
  - **Execução** entra em `KAWASHI_ENV_<AMBIENTE>_APP`, um schema sem objetos. Só consegue ler e
    gravar linhas nas tabelas de cadastro e inserir no log. **Não cria, não altera e não apaga
    tabela**: quem invadir a API herda esta conta.
  - **Migração** entra em `KAWASHI_ENV_<AMBIENTE>`, o dono das tabelas. Cria e altera estrutura, e
    não tem acesso ao log.
- `-OutEnvFile <caminho>` (opcional): grava as credenciais num `.env` local para desenvolvimento.
  Execução grava `DB_URL`, `DB_SCHEMA`, `DB_USER` e `DB_PASSWORD`; Migração grava `DB_MIGRACAO_USER`
  e `DB_MIGRACAO_PASSWORD`. Se o arquivo já existe, as chaves são acrescentadas (as duas contas
  ficam no mesmo arquivo), mas o script nunca troca uma credencial que já está lá. O arquivo nunca
  deve ir para o git.

As duas contas têm só `CREATE SESSION` e nenhum objeto próprio. A API conecta com o usuário
`CONTA[<schema de entrada>]` e a senha **da própria conta**. A senha fica no Vault, em
`kawashi-secrets/api/<conta>` (campo `db_password`; o usuário JDBC pronto está em `jdbc_user`, e o
papel em `papel`).

### Trocar a senha de uma conta de API (a cada 90 dias)

A senha da API não expira sozinha (para a API não parar de madrugada), mas o painel de contas cobra
a troca a cada 90 dias. Para trocar **sem derrubar a API**:

```powershell
./rotate-api-password.ps1 -Username API_TESTE_DEV_EXEC -OutEnvFile ..\..\..\tabelas-api-banco-usp\.env
# reinicie a API: ela lê a senha nova do .env
./rotate-api-password.ps1 -Username API_TESTE_DEV_EXEC -EncerrarSenhaAntiga
```

- O primeiro comando troca a senha no Oracle, no Vault e só na linha certa do `.env` (`DB_PASSWORD`
  para execução, `DB_MIGRACAO_PASSWORD` para migração). A senha não aparece na tela.
- Até o segundo comando, a senha antiga **continua valendo** (troca gradual do Oracle 23ai), então a
  API que está rodando não cai. Se esquecer, a antiga para sozinha em 1 dia, e até lá o painel mostra
  "senha antiga ainda vale".
- Com a API parada, `-Imediata` troca e já encerra a antiga.
- O script recusa um `.env` que seja de outra conta, e recusa conta de pessoa (a pessoa troca a
  própria senha).

## Ancorando o log da aplicação

O log de alterações da API é encadeado por hash dentro do banco, mas quem tem DBA conseguiria
recalcular a corrente inteira. Para isso existe a âncora, guardada no Vault:

```powershell
./ancorar-log.ps1                       # confere e ancora os seis ambientes
./ancorar-log.ps1 -Acao Conferir        # so confere; sai com codigo 1 se houver divergencia
```

Rode o `Ancorar` com frequência (o ideal é agendado): tudo o que foi gravado até a última âncora
fica protegido. Ele se recusa a ancorar por cima de uma divergência. No desenvolvimento o Vault roda
em memória, então a âncora some quando o container reinicia.

## O que o script faz por trás (resumo)

1. Gera uma senha Oracle aleatória (você nunca vê o valor) que só funciona para o primeiro login.
2. Cria o usuário no Oracle com `KAWASHI_SECURE_PROFILE`, aplica os acessos do `-Profile`
   escolhido (mais eventuais `-Roles` extras) e força `PASSWORD EXPIRE`.
3. Cria uma policy e um login pessoal (`userpass`) no Vault, restrito só aos caminhos
   daquela pessoa.
4. Guarda a senha temporária do Oracle dentro do Vault — nunca em `.env`, nunca em texto puro
   em nenhum arquivo do repositório.

## Depois de rodar

O terminal vai imprimir um resumo com:

- URL do Vault
- Login do Vault (= username escolhido)
- Senha temporária do Vault

**Repasse essas duas últimas informações por um canal privado** (DM, nunca um canal público ou
commit) e mande o link do guia [`onboarding-novo-membro.md`](onboarding-novo-membro.md) — é ele
que explica pra pessoa como usar o Vault, trocar a senha do Oracle e guardar a senha definitiva.

⚠️ **Se a whitelist de IP (`KAWASHI_ALLOWED_IPS`) já estiver em modo de bloqueio ativo** (não é
o padrão hoje, ver README) — cadastre o IP da máquina dessa pessoa nessa tabela **antes** dela
tentar logar pela primeira vez, senão o próprio Oracle vai recusar a conexão dela.

## Cuidados

- **Não rode o script duas vezes para o mesmo usuário** — o Oracle vai recusar com
  `ORA-01920` (usuário já existe). Se precisar recriar do zero, tranque/remova o usuário
  antigo primeiro.
- Para **trocar roles** de alguém depois de criado, use `GRANT`/`REVOKE` diretamente — nenhum
  script cobre isso ainda.
- Não cole a saída do terminal (que contém a senha temporária do Vault) em lugares
  persistentes ou públicos — trate como qualquer credencial sensível.
