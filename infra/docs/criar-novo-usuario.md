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
./create-team-member.ps1 -Username NOME_SOBRENOME -Profile Desenvolvedor
```

- **`-Username`**: nome do novo usuário (letras/números/underscore, começando com letra).
  Vira o login do Oracle **e** o login pessoal do Vault.
- **`-Profile`** (obrigatório): define automaticamente em quais ambientes a pessoa pode
  trabalhar — ver tabela abaixo. É a forma recomendada de conceder acesso.
- **`-Servicos`**: opcional, liberação ADITIVA a schemas de serviço (`SEFAZ`,
  `SIMPLES_NACIONAL`) em todo ambiente que o `-Profile` já alcança. **Por padrão (sem
  `-Servicos`), a pessoa só enxerga as tabelas PADRÃO do ambiente dela** — nenhum serviço é
  concedido sozinho. Dar serviço a todo mundo não tem problema nenhum nesse desenho, mas
  precisa ser sempre explícito (um `-Servicos` por pessoa, nunca algo que o `-Profile` jogue
  sozinho). Não se aplica a `HomologViewer` (não usa proxy em nenhum ambiente).
- **`-Roles`**: opcional, só para exceções pontuais além do que o `-Profile` já cobre.

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

## Dando acesso a um serviço depois (pessoa que já tem conta)

`-Servicos` em `create-team-member.ps1` só funciona no momento da **criação** — rodar o script
de novo pra um `-Username` que já existe falha com `ORA-01920` antes de chegar em `-Servicos`.
Pro caso comum de alguém que já tem conta (ex: um `Desenvolvedor` sem nenhum serviço) entrar
depois no time da SEFAZ, use:

```powershell
./grant-service-access.ps1 -Username NOME_SOBRENOME -Servicos SEFAZ
```

Script: [`infra/scripts/grant-service-access.ps1`](../scripts/grant-service-access.ps1). Ele
descobre sozinho (consultando `DBA_PROXIES`, não perguntando de volta) em quais ambientes a
pessoa já tem proxy, e concede o serviço pedido em todos eles — não muda senha, não mexe no
Vault, é idempotente (rodar de novo com o mesmo serviço não dá erro).

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
- Para **dar acesso a um serviço depois de criado**, use
  [`grant-service-access.ps1`](../scripts/grant-service-access.ps1) (seção acima) — não `GRANT`
  manual. Para **trocar roles** de alguém depois de criado, aí sim use `GRANT`/`REVOKE`
  diretamente — nenhum script cobre isso ainda.
- Não cole a saída do terminal (que contém a senha temporária do Vault) em lugares
  persistentes ou públicos — trate como qualquer credencial sensível.
