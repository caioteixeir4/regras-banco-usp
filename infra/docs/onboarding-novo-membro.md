# Bem-vindo(a) à Kawashi Sistemas — Primeiro acesso ao banco

Este guia explica como pegar seu acesso inicial ao banco Oracle da Kawashi através do
Vault (nosso cofre de senhas) e como deixar tudo configurado com segurança.

Você **não** vai receber sua senha por chat, e-mail ou qualquer texto puro. Ela fica guardada
no Vault, e só você (com seu próprio login) consegue lê-la.

## O que você vai receber do engenheiro do projeto

Duas informações, por um canal privado (ex: mensagem direta):

- Um **usuário do Vault** (mesmo nome do seu usuário no Oracle)
- Uma **senha temporária do Vault** (só serve pra você entrar no cofre, não é a senha do banco)

## Passo 1 — Entrar no Vault

1. Acesse **http://localhost:8200** no navegador (ou o endereço informado pelo engenheiro,
   se o Vault estiver em outra máquina).
2. Na tela de login, escolha o método **Username** (userpass) — não é o método "Token".
3. Preencha com o usuário e a senha temporária que você recebeu.

## Passo 2 — Ler sua senha temporária do Oracle

1. Já logado, vá em **Secrets** → engine **kawashi-secrets** → pasta **onboarding** → `<seu-usuário>`.
2. Você vai ver campos como:
   - `db_username` — seu usuário no Oracle
   - `db_password` — sua senha **temporária** do banco (só funciona uma vez)
   - `oracle_service` — endereço de conexão (`kawashi-oracle:1521/FREEPDB1`)
3. Anote a `db_password` — você vai precisar dela só nesta próxima etapa.

## Passo 3 — Primeiro login no Oracle e troca de senha

1. Conecte no Oracle (SQL Developer, DBeaver, sqlplus — o que preferir) usando `db_username`,
   `db_password` e `oracle_service` do passo anterior.
2. O Oracle vai recusar a senha temporária e pedir uma **senha nova, escolhida por você**.
   Essa senha:
   - Só você vai saber (nem o engenheiro do projeto, nem ninguém mais tem acesso a ela).
   - Precisa ter no mínimo 12 caracteres, com maiúscula, minúscula, número e caractere especial,
     e não pode conter seu nome de usuário.
3. Pronto — esse é o seu acesso definitivo ao banco.

## Passo 4 — Guardar sua senha definitiva no seu espaço do Vault

O Vault não consegue capturar a senha nova sozinho (ela nunca passa por ele), então esse
passo é manual — mas é rápido:

1. No Vault, vá em **Secrets** → **kawashi-secrets** → pasta **engineers** → crie/edite o
   segredo em `<seu-usuário>`.
2. Salve os campos `db_username` e `db_password` com o valor que você acabou de escolher.
3. Volte no segredo de **onboarding** do Passo 2 e **delete-o** (ele já cumpriu a função —
   não faz sentido a senha temporária continuar visível).

Assim, se você esquecer sua senha, o único lugar "de backup" é o seu próprio espaço no Vault,
que mais ninguém enxerga além de você e do engenheiro do projeto.

## Passo 5 — Trocar sua senha de login do Vault (recomendado)

A senha temporária do Vault que você recebeu no início também deve ser trocada por uma sua.
Pela CLI do Vault (peça o `vault` instalado ou use `docker exec` se preferir), rode:

```
vault login -method=userpass username=<seu-usuário>
vault write auth/userpass/users/<seu-usuário> password="SuaNovaSenhaDoVault" policies="engineer-<seu-usuário-minúsculo>"
```

**Importante:** sempre inclua o `policies=...` (com o mesmo nome que o engenheiro te passou,
formato `engineer-<seuusuario>` em minúsculo) — se você omitir esse campo, o Vault reseta suas
permissões, e você perde acesso ao seu próprio espaço.

## Como conectar no ambiente que você tem acesso (Teste/Dev/Infra/Homologação)

Seu usuário pessoal não é dono de tabela nenhuma — o acesso aos ambientes de trabalho
(Teste, Desenvolvimento, Infra, Homologação) funciona por **proxy authentication**: você
loga com seu próprio usuário e senha, mas "passa por dentro" do schema do ambiente liberado
pra você. O engenheiro do projeto te informa qual(is) ambiente(s) você tem, de acordo com
seu perfil:

| Perfil | Nome do schema pra usar no proxy |
|---|---|
| EstagiarioDev | `KAWASHI_ENV_TESTE_DEV` |
| EstagiarioInfra | `KAWASHI_ENV_TESTE_INFRA` |
| Desenvolvedor | `KAWASHI_ENV_DEV` (e `KAWASHI_ENV_HOMOLOG` pra promover código) |
| Infra | `KAWASHI_ENV_INFRA` (e `KAWASHI_ENV_HOMOLOG` pra promover código) |

**Via sqlplus:**
```
sqlplus seu_usuario[KAWASHI_ENV_DEV]/sua_senha@//kawashi-oracle:1521/FREEPDB1
```
(troque `KAWASHI_ENV_DEV` pelo ambiente que você for usar naquele momento)

**Via DBeaver/SQL Developer:** no campo de usuário da conexão, digite
`seu_usuario[KAWASHI_ENV_DEV]` (com colchetes e tudo) e sua senha normal no campo de senha —
não precisa de configuração especial além disso.

Se você é perfil **HomologViewer** (só leitura em Homologação), **não use proxy** — conecte
normal, só com seu usuário e senha, sem colchetes. Você já enxerga (`SELECT`) os dados de
Homologação automaticamente, sem precisar "virar" outro usuário.

## A cada 3 meses

Sua senha do Oracle expira automaticamente a cada 90 dias. Quando isso acontecer, repita os
**Passos 3 e 4**: o Oracle vai pedir a troca no próximo login, e você atualiza o valor salvo
no seu espaço do Vault (`kawashi-secrets/engineers/<seu-usuário>`).

## Dúvidas ou problemas

Se sua conta travar (por exemplo, por ficar mais de 90 dias sem logar) ou você perder acesso,
fale com o engenheiro do projeto — só uma conta com privilégio de administrador consegue
destravar ou recriar seu usuário.
