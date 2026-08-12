# Arquitetura da Infraestrutura Kawashi

Este documento existe pra dar uma visão de "olho de pássaro" do projeto — como as peças se
conectam — sem precisar ler todos os scripts. Cada diagrama vem acompanhado de uma explicação
do que ele mostra e por quê está desenhado assim.

## 1. Containers e rede

O ambiente local roda dois containers Docker, isolados numa rede privada, cada um exposto
numa porta do seu computador:

```mermaid
flowchart TB
    subgraph Maquina["Sua máquina (local hoje — AWS no futuro)"]
        InitScripts["📜 infra/oracle-init/*.sql
        (01 a 09 — rodam só no 1º boot)"]

        subgraph Rede["kawashi-net (rede Docker privada)"]
            Oracle["🗄️ kawashi-oracle
            Oracle Database Free 23ai
            porta 1521"]
            Vault["🔐 kawashi-vault
            HashiCorp Vault (modo dev)
            porta 8200"]
        end

        InitScripts -. montado como volume, roda 1x .-> Oracle
    end

    Voce["👤 Você / time
    (SQL Developer, DBeaver, navegador)"] -- "1521 (SQL)" --> Oracle
    Voce -- "8200 (HTTP)" --> Vault
```

**O que prestar atenção aqui:**
- Os dois containers só se enxergam um ao outro pelo nome (`kawashi-oracle`, `kawashi-vault`)
  porque estão na mesma rede Docker (`kawashi-net`) — é assim que uma futura aplicação Spring
  Boot rodando num terceiro container conseguiria alcançar o banco sem saber IP nenhum.
- Os scripts de `oracle-init` só rodam **uma única vez**, no primeiro boot do container
  (quando o volume de dados do Oracle ainda não existe). Depois disso, mudar um arquivo `.sql`
  ali não faz efeito sozinho — precisa recriar o container do zero.
- O Vault roda em **modo dev** (memória, sem persistência) — por isso o `vault-init.ps1`
  precisa rodar de novo toda vez que o container é recriado (ver
  [`infra/oracle-init/09_environments.sql`](../oracle-init/09_environments.sql) e o README
  para o que muda quando isso for para produção/AWS).

## 2. Ambientes de ciclo de vida (schemas) e quem acessa o quê

Cada perfil de pessoa só alcança os ambientes liberados pra ele, via *proxy authentication*
(a pessoa loga com o próprio usuário, mas "atua como" o schema do ambiente). Produção só é
alcançada manualmente, pelo engenheiro do projeto:

```mermaid
flowchart LR
    subgraph Pessoas["Perfis de pessoas"]
        Estagiario["🧑‍🎓 Estagiário"]
        Desenvolvedor["👩‍💻 Desenvolvedor"]
        Infra["🛠️ Infra"]
        QA["🔍 QA / HomologViewer"]
        Engenheiro["👑 Engenheiro do projeto
        (ENGINEER_USER, privilégio DBA)"]
    end

    subgraph Ambientes["Schemas de ambiente (KAWASHI_ENV_*)"]
        Teste[("TESTE")]
        Dev[("DESENVOLVIMENTO")]
        InfraEnv[("INFRA")]
        Homolog[("HOMOLOGAÇÃO")]
        Prod[("PRODUÇÃO")]
    end

    Estagiario -- "CONNECT THROUGH" --> Teste
    Desenvolvedor -- "CONNECT THROUGH" --> Dev
    Desenvolvedor -- "CONNECT THROUGH" --> Homolog
    Infra -- "CONNECT THROUGH" --> InfraEnv
    Infra -- "CONNECT THROUGH" --> Homolog
    QA -- "SELECT (somente leitura)" --> Homolog
    Engenheiro -- "escreve manualmente, 1x/mês,
    só o que foi validado" --> Prod

    Dev -.-> Homolog
    InfraEnv -.-> Homolog
    Homolog -. "promoção mensal
    curada pelo engenheiro" .-> Prod
```

**O que prestar atenção aqui:**
- **Ninguém** chega em Produção por acesso direto — nem Desenvolvedor, nem Infra. Só o
  `ENGINEER_USER` (privilégio `DBA`) escreve lá, manualmente, uma vez por mês.
- Estagiário **não** tem nenhuma seta chegando em Homologação — a revisão do trabalho dele
  acontece no Git (pull request), não no banco. Só quem já tem acesso a Desenvolvimento ou
  Infra consegue promover algo pra Homologação.
- QA/HomologViewer é o único perfil que **não usa proxy** — ele lê Homologação através de uma
  role de `SELECT`, porque não deveria ter poder de escrita/DDL ali (proxy daria isso de
  brinde, então evitamos).
- Isso é isolamento **lógico** (schemas diferentes), não físico — todos os 5 ambientes ainda
  rodam dentro do mesmo container/instância Oracle. Ver Technical Debts no README.

## 3. Como uma pessoa nova recebe acesso (onboarding via Vault)

Nenhuma senha passa por chat, e-mail ou arquivo de texto em nenhum momento deste fluxo:

```mermaid
sequenceDiagram
    actor Admin as Engenheiro do projeto
    participant Script as create-team-member.ps1
    participant Oracle as kawashi-oracle
    participant Vault as kawashi-vault
    actor Pessoa as Novo integrante

    Admin->>Script: roda com -Username e -Profile
    Script->>Oracle: cria usuário + senha aleatória temporária
    Script->>Oracle: concede acesso do perfil (CONNECT THROUGH / roles)
    Script->>Vault: cria login pessoal (userpass) + policy restrita à própria pessoa
    Script->>Vault: guarda a senha temporária em onboarding/<usuário>
    Script-->>Admin: mostra só login + senha TEMPORÁRIA do Vault

    Admin->>Pessoa: repassa login + senha do Vault (canal privado)

    Pessoa->>Vault: login com usuário/senha temporária
    Pessoa->>Vault: lê onboarding/<usuário> (senha temporária do Oracle)
    Pessoa->>Oracle: conecta com essa senha temporária
    Oracle-->>Pessoa: recusa e força escolher senha nova (PASSWORD EXPIRE)
    Pessoa->>Oracle: define senha definitiva (só ela sabe o valor)
    Pessoa->>Vault: guarda a senha definitiva em engineers/<usuário>
    Pessoa->>Vault: deleta o segredo onboarding/<usuário> (já cumpriu a função)
```

**O que prestar atenção aqui:**
- O admin nunca vê a senha definitiva do Oracle — só a temporária, que expira no primeiro uso.
- A senha definitiva nunca "passa" pelo Vault de forma automática — o próprio Oracle não avisa
  ninguém quando alguém troca a própria senha, então guardar ela de volta no cofre é uma ação
  manual e voluntária da pessoa (Passo 4 do
  [guia de onboarding](onboarding-novo-membro.md)).
- Cada pessoa só enxerga seu próprio espaço no Vault (`onboarding/<usuário>` e
  `engineers/<usuário>`) — a policy criada pelo script restringe isso.

## Documentos relacionados

- [`criar-novo-usuario.md`](criar-novo-usuario.md) — guia do administrador para criar acesso.
- [`onboarding-novo-membro.md`](onboarding-novo-membro.md) — guia de quem está recebendo acesso.
- [`../oracle-init/09_environments.sql`](../oracle-init/09_environments.sql) — implementação
  dos ambientes/schemas e o racional completo de cada decisão.
- [`../../README.md`](../../README.md) — visão geral do projeto e roadmap.
