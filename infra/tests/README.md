# Testes automatizados da infra Kawashi

Suíte de testes que roda contra o Oracle e o Vault **de verdade** (containers do
`docker-compose.yml`), não contra mocks — o objetivo é continuar achando bugs do tipo
documentado em [`../docs/bugs-primeiro-teste.md`](../docs/bugs-primeiro-teste.md) antes que
alguém precise descobrir na mão.

## Pré-requisitos

1. Containers no ar: `docker compose up -d` (a partir de `infra/`).
2. Vault inicializado **sempre que o container for recriado ou reiniciado** — o Vault roda em
   modo `-dev` (em memória, sem persistência — débito técnico intencional, ver
   `scripts/vault-init.ps1`), então o engine `kawashi-secrets` e o método `userpass` somem a
   cada restart:
   ```powershell
   ./scripts/vault-init.ps1
   ```
3. `infra/.env` preenchido (`ENGINEER_USER`, `ENGINEER_USER_PASSWORD`, `VAULT_DEV_ROOT_TOKEN_ID`).

## Como rodar

```powershell
# Tudo
./tests/Run-AllTests.ps1

# Só uma categoria
./tests/Run-AllTests.ps1 -Categoria caixa-preta

# Um teste especifico, direto
./tests/caixa-preta/Test-MatrizAcessoPorPerfil.ps1
```

Cada `Test-*.ps1` é independente: cria seus próprios dados descartáveis (usuários prefixados
`TST_...`, tabelas `TESTE_...`) e remove tudo no final, mesmo se o teste falhar no meio
(`try/finally`). Rodar um teste sozinho ou rodar todos dá o mesmo resultado.

## As quatro categorias

| Pasta | O que valida | Como decide sucesso/falha |
|---|---|---|
| `unitarios/` | Uma única unidade de código isolada (hoje: a função `KAWASHI_PASSWORD_VERIFY`), chamada diretamente, sem passar pelo fluxo real de criação de usuário. | Retorno/exceção da própria função. |
| `caixa-branca/` | Mecanismos internos, usando conhecimento da implementação (nomes de profile, de trigger, de role, de parâmetro de sistema). | Consulta direta a catálogos do Oracle (`DBA_PROFILES`, `DBA_SYS_PRIVS`, `DBA_TAB_PRIVS`, `DBA_TS_QUOTAS`, `V$PARAMETER`). |
| `caixa-preta/` | Comportamento observável de fora, sem olhar para nenhum catálogo interno: novos usuários, conexões (corretas/erradas/duplicadas), e permissões de CRUD/isolamento. | Só a resposta do login/proxy/DML (aceito, `ORA-01017`, `ORA-28000`, `ORA-01031`/`ORA-41900`, `ORA-00942`, `ORA-01920`...). |
| `outros/` | Integração: a automação de onboarding (`create-team-member.ps1`) e a conta de aplicação (Spring) de ponta a ponta, nos dois sistemas que tocam (Oracle + Vault). | Estado combinado em Oracle **e** Vault, mais comportamento de conexão/CRUD. |

Arquivos de teste atuais, por categoria (36 arquivos, 243 casos):

- `unitarios/`: `Test-PasswordVerifyFunction.ps1`
- `caixa-branca/`: `Test-ProfileEHardeningInternals.ps1`, `Test-HomologAutograntTrigger.ps1`,
  `Test-RolesPrivilegiosInternos.ps1`, `Test-SpringAppUserHardeningInternals.ps1`,
  `Test-TrilhaSegurancaPropria.ps1`, `Test-ObjetosInvalidosEJobsSaudaveis.ps1`,
  `Test-BlacklistFerramentasDados.ps1`, `Test-TrilhaSegurancaFailover.ps1`,
  `Test-ConsistenciaLoginRepetido.ps1`, `Test-InventarioDeSeguranca.ps1`,
  `Test-InvarianteFkPadraoNuncaReferenciaServico.ps1`
- `caixa-preta/`: `Test-BloqueioPorTentativasInvalidas.ps1`, `Test-MatrizAcessoPorPerfil.ps1`,
  `Test-ConexaoNovoUsuario.ps1`, `Test-UsuarioDuplicado.ps1`, `Test-PermissoesCrudPorAmbiente.ps1`,
  `Test-PermissoesHomologViewerSomenteLeitura.ps1`, `Test-BloqueioOsUserInseguro.ps1`,
  `Test-RevogacoesPublicPerigosas.ps1`, `Test-EscalonamentoPrivilegioBloqueado.ps1`,
  `Test-MetadadoVsConteudo.ps1`, `Test-InjecaoUsernamePerfil.ps1`, `Test-RolesExtras.ps1`,
  `Test-ReusoSenhaImediatoBloqueado.ps1`, `Test-CriacaoConcorrente.ps1`,
  `Test-CriacaoObjetosBloqueadaPorPerfil.ps1`, `Test-RolesPerigosasBloqueadas.ps1`,
  `Test-DropPluggableDatabaseBloqueado.ps1`, `Test-ControleColetivoDentroDoAmbiente.ps1`,
  `Test-SegmentacaoPorServico.ps1`
- `outros/`: `Test-OnboardingEndToEnd.ps1`, `Test-ConexaoAplicacaoSpring.ps1`,
  `Test-LimiteSessoesAplicacao.ps1`

### Rodada "sem bug novo" (confirmam que o que existe já funciona)

- `Test-ReusoSenhaImediatoBloqueado.ps1`: `PASSWORD_REUSE_TIME`/`PASSWORD_REUSE_MAX` realmente
  impedem voltar pra senha anterior (`ORA-28007`), não só estão declarados no profile.
- `Test-InventarioDeSeguranca.ps1`: golden snapshot - o conjunto inteiro de triggers, roles,
  profiles, procedures/functions, jobs e tabelas de controle é EXATAMENTE o esperado (pega tanto
  remoção acidental quanto sobra de objeto de debug esquecido).
- `Test-CriacaoConcorrente.ps1`: 3 onboardings rodando ao mesmo tempo de verdade (`Start-Job`) -
  todos terminam com sucesso e sem contaminação cruzada entre os segredos/policies do Vault.

### Rodada "garantir que quem deveria ser barrado realmente é barrado"

- `Test-CriacaoObjetosBloqueadaPorPerfil.ps1`: `CREATE TRIGGER`/`PROCEDURE`/`SEQUENCE`/`VIEW`/`TABLE`
  testados por perfil - inclusive a fronteira exata (nunca testada antes) de
  `ROLE_KAWASHI_DEVELOPER`, que dá `TABLE`/`VIEW` mas não `SEQUENCE`/`PROCEDURE`/`TRIGGER`.
- `Test-PermissoesCrudPorAmbiente.ps1` e `Test-PermissoesHomologViewerSomenteLeitura.ps1`: ganharam
  checagem de `INSERT`/`UPDATE`/`DELETE`/`ALTER TABLE`/`DROP TABLE` numa tabela de **outro dono**
  (em tabela própria, isso é sempre permitido por posse, não por privilégio - não faz sentido
  testar ali).
- `Test-DropPluggableDatabaseBloqueado.ps1`: nem um usuário comum nem o `ENGINEER_USER` (DBA
  dentro do PDB) conseguem derrubar o banco inteiro (`DROP PLUGGABLE DATABASE`, o equivalente
  Oracle de `DROP DATABASE`) - bloqueado em duas camadas independentes.
- `Test-RolesPerigosasBloqueadas.ps1`: achado crítico, **corrigido** - ver item 15 de
  `bugs-primeiro-teste.md`. O parâmetro `-Roles` de `create-team-member.ps1` aceitava
  literalmente qualquer role, incluindo `DBA`.
- `Test-ControleColetivoDentroDoAmbiente.ps1`: achado arquitetural importante, **não é bug de
  código** - ver item 16 de `bugs-primeiro-teste.md`. Dentro do mesmo ambiente (TESTE/DEV/INFRA/
  HOMOLOG), qualquer pessoa pode apagar o que outra pessoa criou, porque a posse no Oracle é do
  schema do ambiente (compartilhado via proxy), não da pessoa.

### Rodada "segmentação por serviço + divisão do TESTE por equipe"

Resposta direta ao achado do `Test-ControleColetivoDentroDoAmbiente.ps1` acima: o ambiente
`TESTE` único virou dois (`TESTE_DEV`/`TESTE_INFRA`, um por equipe, perfis `EstagiarioDev`/
`EstagiarioInfra`) e cada um dos 6 ambientes ganhou schemas de SERVIÇO (`SEFAZ`,
`SIMPLES_NACIONAL` de exemplo) com tabelas padrão compartilhadas (`CLIENTE`, `ENDERECO`, etc.) e
liberação aditiva via `-Servicos` - ver `09_environments.sql` seção 2.1,
`11_exemplo_dominio_negocio.sql`, e o plano completo em
[`bugs-primeiro-teste.md`](../docs/bugs-primeiro-teste.md).

- `Test-MatrizAcessoPorPerfil.ps1` cresceu de 4 para 5 perfis e de 5 para 6 ambientes - cobre
  `EstagiarioDev`/`EstagiarioInfra` cada um só no seu próprio `TESTE_*`, então uma
  `Test-DivisaoTesteDevInfra.ps1` separada seria pura duplicação e não foi criada.
- `Test-SegmentacaoPorServico.ps1` (novo): confirma que sem `-Servicos` o schema de serviço nem
  aceita login via proxy; que com `-Servicos SEFAZ` dá pra escrever no serviço E ler a tabela
  padrão via `JOIN` (FK de verdade funcionando); e que a liberação é estritamente por serviço -
  ter SEFAZ não dá SIMPLES_NACIONAL de brinde.
- Achado real no caminho (item 17 de `bugs-primeiro-teste.md`): `GRANT REFERENCES` só habilita
  criar a FK, não dá nenhuma permissão de leitura - o primeiro `JOIN` entre serviço e padrão
  falhava com `ORA-41900: missing READ privilege` até adicionar `GRANT SELECT` explícito.

### Rodada "mais exemplos de domínio + invariante de arquitetura"

Pergunta do usuário que motivou esta rodada: "não é interessante fazer testes? tipo para garantir
que nas tabelas padrões nunca tenha uma foreing key que está em um esquema lá na frente" - mais
três schemas de serviço de exemplo (`ORGANIZACOES`, `LOGIN`, `ADMINISTRACAO`, ver
`12_exemplo_dominio_kawashi_core.sql` e `arquitetura.md` seção 2.2), pedidos explicitamente como
mais referência/material de teste, sem aprofundar o desenho de nenhum deles.

- `Test-InvarianteFkPadraoNuncaReferenciaServico.ps1` (novo, caixa-branca): consulta genérica a
  `DBA_CONSTRAINTS` que confirma, nos 6 ambientes, que nenhuma tabela padrão tem FK apontando pra
  dentro de um schema de serviço (o contrário do padrão servico→padrão já estabelecido) -
  funciona pra qualquer serviço futuro, sem listar nomes. Inclui controles positivos (SEFAZ,
  ADMINISTRACAO e LOGIN apontando no sentido certo) pra provar que a consulta não passaria vazia
  por acidente - ver item 18 de `bugs-primeiro-teste.md` (achado preventivo, não um bug).

### Destaques desta rodada (caixa-branca "resiliência" e "consistência")

- `Test-TrilhaSegurancaFailover.ps1`: força `KAWASHI_WRITE_SECURITY_LOG` a falhar de verdade na
  gravação principal (um `DETAILS` maior que a coluna aguenta) e confirma que o fallback
  documentado em `04_security_procedures.sql` segura o evento sem travar quem chamou. Não é
  hipotético: o item 11 de `bugs-primeiro-teste.md` mostra que esse exato caminho rodou por
  engano, sem ninguém perceber, por toda a vida do projeto - essa é a trava que deveria ter sido
  testada desde o início.
- `Test-ConsistenciaLoginRepetido.ps1`: loga 8 vezes seguidas com o mesmo usuário e confirma que
  o padrão de eventos (`SUCCESSFUL_LOGIN`/`SESSION_END`) é sempre o mesmo - sem duplicar, sem
  perder, sem evento de bloqueio aparecendo por engano. Pega regressão do tipo "funcionou uma vez,
  não funciona sempre".
- `Test-LimiteSessoesAplicacao.ps1`: achado crítico de prontidão para produção, **corrigido** com
  um profile novo dedicado a contas de serviço (`KAWASHI_SERVICE_PROFILE`) - ver item 14 de
  `bugs-primeiro-teste.md`. O teste hoje é guarda de regressão da correção (confirma que 8
  conexões simultâneas são aceitas, não que a 4ª falha).

Essa divisão não é só organizacional — ela espelha de propósito os "cenários controlados de
acesso legítimo e de tentativas de acesso não autorizado" e os critérios de avaliação descritos
no Projeto de Pesquisa do TCC (ver `Material e Métodos`): `caixa-preta/Test-MatrizAcessoPorPerfil.ps1`
e `Test-BloqueioPorTentativasInvalidas.ps1` são, na prática, um ensaio automatizado antecipado
desses mesmos cenários.

## `lib/TestHelpers.ps1`

Funções compartilhadas por todos os testes: `Invoke-SqlPlus` (mesmo padrão BOM-safe via base64
já usado em `infra/scripts/*.ps1`), `Get-EngineerConnectString`/`Get-EngineerCredentials`,
`Get-VaultToken`, `New-ThrowawayUsername`, `New-StrongPassword` (compatível com
`KAWASHI_PASSWORD_VERIFY`) e `New-TestResult`/`Write-TestResult` para reportar resultados de
forma consistente. Todo `Test-*.ps1` segue o mesmo contrato: dot-source do helper, roda os
casos, e **retorna** (`return $results`) um array de objetos `{ Name; Passed; Details }` — é
assim que `Run-AllTests.ps1` agrega o resumo final sem precisar reimplementar nada.

## Bugs reais encontrados escrevendo esta suíte

Escrever e expandir estes testes já achou **seis** bugs/achados de verdade em código de produção
(não nos testes em si) — ver itens 8 a 13 em [`../docs/bugs-primeiro-teste.md`](../docs/bugs-primeiro-teste.md)
para o relato completo (sintoma, causa raiz, correção) de cada um:

1. O trigger de auto-grant de Homologação quebrava toda `CREATE TABLE` feita por um Dev/Infra de
   verdade (`09_environments.sql`).
2. A senha gerada por `New-StrongPassword` podia conter `@`, quebrando qualquer connect string
   Oracle no formato `usuario/senha@host` (`create-team-member.ps1`) — achado tanto em teste
   quanto numa senha já existente no próprio `.env` deste projeto.
3. `create-team-member.ps1` não tinha `WHENEVER SQLERROR EXIT`: uma tentativa de criar um usuário
   com nome já existente falhava no `CREATE USER`, mas as instruções seguintes do mesmo script
   (grants de proxy do perfil escolhido) continuavam rodando contra a conta já existente -
   silenciosamente concedendo acesso extra a ela mesmo com o PowerShell reportando a operação
   inteira como falha.
4. **O mais grave do projeto inteiro**: a trilha de auditoria própria (`KAWASHI_SECURITY_LOG`)
   nunca tinha gravado uma única linha desde o primeiro boot — `KAWASHI_WRITE_SECURITY_LOG` usava
   `SYS_CONTEXT('USERENV', 'CLIENT_PROGRAM')`, que não é um atributo válido (o certo é
   `CLIENT_PROGRAM_NAME`). Toda chamada falhava silenciosamente e caía na tabela de fallback, que
   já tinha 1.782 falhas acumuladas quando descobrimos.
5. O evento mais sensível dessa mesma trilha (`PRIVILEGE_GRANT_ALERT`, pensado para flagrar
   escalonamento de privilégio) nunca registrava quem recebeu o quê em concessões de role/privilégio
   de sistema — `ORA_DICT_OBJ_NAME` só funciona para DDL em objetos de schema, não para `GRANT`.
   Corrigido capturando o texto real do comando via `ORA_SQL_TXT`.
6. (limitação do Oracle, não bug de código, mas documentada como teste) A única regra do trigger
   de logon que bloqueia de verdade (usuário de SO `root`/`administrator`/`guest`) não protege
   contas com a role `DBA` — justamente a conta mais privilegiada do projeto.
