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
   cada restart. O `Run-AllTests.ps1` já roda o `vault-init.ps1` (idempotente) antes da suíte;
   para rodar **um teste direto**, ou usar os scripts de criação de usuário, rode você mesmo:
   ```powershell
   ./scripts/vault-init.ps1
   ```
   Atenção: o restart também apaga os **segredos guardados** (por exemplo as credenciais das
   contas de API em `kawashi-secrets/api/...`). As contas continuam existindo no Oracle; só a
   cópia da senha no Vault some.
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

Arquivos de teste atuais, por categoria (43 arquivos, 375 casos na última execução completa, 20/11/2026). O
histórico da contagem está nas rodadas abaixo: a remoção dos schemas de serviço tirou 3 arquivos, e
o schema de log trouxe 1 arquivo com 16 casos.

- `unitarios/`: `Test-PasswordVerifyFunction.ps1`
- `caixa-branca/`: `Test-ProfileEHardeningInternals.ps1`, `Test-HomologAutograntTrigger.ps1`,
  `Test-RolesPrivilegiosInternos.ps1`, `Test-SpringAppUserHardeningInternals.ps1`,
  `Test-TrilhaSegurancaPropria.ps1`, `Test-ObjetosInvalidosEJobsSaudaveis.ps1`,
  `Test-BlacklistFerramentasDados.ps1`, `Test-TrilhaSegurancaFailover.ps1`,
  `Test-ConsistenciaLoginRepetido.ps1`, `Test-InventarioDeSeguranca.ps1`, `Test-PortasSoNaMaquinaLocal.ps1`
- `caixa-preta/`: `Test-BloqueioPorTentativasInvalidas.ps1`, `Test-MatrizAcessoPorPerfil.ps1`,
  `Test-ConexaoNovoUsuario.ps1`, `Test-UsuarioDuplicado.ps1`, `Test-PermissoesCrudPorAmbiente.ps1`,
  `Test-PermissoesHomologViewerSomenteLeitura.ps1`, `Test-BloqueioOsUserInseguro.ps1`,
  `Test-RevogacoesPublicPerigosas.ps1`, `Test-EscalonamentoPrivilegioBloqueado.ps1`,
  `Test-MetadadoVsConteudo.ps1`, `Test-InjecaoUsernamePerfil.ps1`, `Test-RolesExtras.ps1`,
  `Test-ReusoSenhaImediatoBloqueado.ps1`, `Test-CriacaoConcorrente.ps1`,
  `Test-CriacaoObjetosBloqueadaPorPerfil.ps1`, `Test-RolesPerigosasBloqueadas.ps1`,
  `Test-DropPluggableDatabaseBloqueado.ps1`, `Test-ControleColetivoDentroDoAmbiente.ps1`,
  `Test-ContaApiViaProxy.ps1`, `Test-SchemaLogSomenteInsercao.ps1`, `Test-AncoraDoLog.ps1`,
  `Test-CriptografiaEmDisco.ps1`, `Test-CadastroDeContas.ps1`, `Test-DesligamentoDePessoa.ps1`,
  `Test-RotacaoSenhaApi.ps1`, `Test-ConexaoCifrada.ps1`, `Test-SchemaLogin.ps1`
- `outros/`: `Test-OnboardingEndToEnd.ps1`, `Test-ConexaoAplicacaoSpring.ps1`,
  `Test-LimiteSessoesAplicacao.ps1`, `Test-RotinaDiaria.ps1`

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
`SIMPLES_NACIONAL` de exemplo) com tabela padrão compartilhada (`CLIENTE`) e
liberação aditiva via `-Servicos` - ver `09_environments.sql` seção 2.1,
`11_fixture_contrato_segmentacao.sql` (na época `11_exemplo_dominio_negocio.sql`, com mais
tabelas padrão; a versão completa está na tag `dominio-completo-pre-separacao`), e o plano
completo em [`bugs-primeiro-teste.md`](../docs/bugs-primeiro-teste.md).

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
  funciona pra qualquer serviço futuro, sem listar nomes. Inclui controle positivo (SEFAZ
  apontando no sentido certo) pra provar que a consulta não passaria vazia por acidente - ver
  item 18 de `bugs-primeiro-teste.md` (achado preventivo, não um bug). Nesta rodada ele tinha 5
  casos, com controles extras de `ORGANIZACOES`/`LOGIN`/`ADMINISTRACAO`; esses 3 saíram na
  rodada seguinte (abaixo), junto com os schemas.

### Rodada "separar regras do banco das tabelas de negócio"

Decisão de arquitetura (item 20 de `bugs-primeiro-teste.md`): este repositório fica só com as
**regras** do banco; as tabelas de negócio e a API do banco vão pra um repositório separado.
O que mudou na suíte:

- `12_exemplo_dominio_kawashi_core.sql` (schemas `ORGANIZACOES`/`LOGIN`/`ADMINISTRACAO`) saiu do
  repositório; `11` virou `11_fixture_contrato_segmentacao.sql`, só `CLIENTE` e
  `SEFAZ.CONFIGURACAO_FISCAL`, que é tudo que `Test-SegmentacaoPorServico.ps1`,
  `Test-ConcessaoServicoUsuarioExistente.ps1` e o invariante de FK precisam.
- `Test-InvarianteFkPadraoNuncaReferenciaServico.ps1` passou de 5 para 2 casos (a invariante
  genérica + o controle positivo do SEFAZ); por isso a suíte esperada passa de 250 para **247**
  casos, nos mesmos 35 arquivos. Ele agora é lido como **contrato**: o repositório de tabelas
  precisa passar nele.
- Nada foi perdido: a tag git `dominio-completo-pre-separacao` guarda o estado completo de antes
  (250 casos verdes, os dois SQL de domínio, o invariante de 5 casos).

### Rodada "conceder serviço depois, pra quem já tem conta"

Pedido do usuário: por padrão um perfil só deve enxergar as tabelas padrão; serviço adicional
pode ser dado a qualquer perfil sem problema, mas sempre separado e explícito - inclusive
**depois** que a conta já existe, não só na criação. `create-team-member.ps1 -Servicos` só
funciona no momento da criação (rodar de novo com o mesmo `-Username` falha com `ORA-01920`) -
criado `infra/scripts/grant-service-access.ps1` pra cobrir o caso de alguém que já tem conta.

- `Test-ConcessaoServicoUsuarioExistente.ps1` (novo): confirma que um usuário criado sem
  `-Servicos` não alcança o schema de serviço; que `grant-service-access.ps1` concede acesso
  de verdade (INSERT + JOIN) sem mudar senha nem mexer no Vault; que a liberação continua por
  serviço (SIMPLES_NACIONAL continua bloqueado); que rodar o script de novo com o mesmo serviço
  é idempotente; que um perfil com mais de um ambiente (Infra) recebe o serviço em TODOS eles;
  e os dois erros esperados (usuário inexistente, perfil sem nenhum ambiente via proxy).
- Achado ao vivo (não um bug, mas uma pegadinha real de metodologia): as colunas de
  `DBA_PROXIES` são o inverso do que o nome sugere - `ALTER USER KAWASHI_ENV_DEV GRANT CONNECT
  THROUGH JOAO` grava `CLIENT = KAWASHI_ENV_DEV` e `PROXY = JOAO`, não o contrário. A consulta
  certa pra "em quais ambientes JOAO já entra" é `SELECT client FROM dba_proxies WHERE proxy =
  'JOAO'` - ver item 19 de `bugs-primeiro-teste.md`.

### Rodada "conta de API por ambiente"

Fecha o ponto em aberto da separação de repositórios: a API Java (repositório
`tabelas-api-banco-usp`) precisa de uma conta própria pra conectar, e até aqui só existia a
`KAWASHI_SPRING_USER`, sem relação com os 6 ambientes. O modelo agora é o das pessoas (proxy no
schema do ambiente), com o perfil de serviço. Criado `infra/scripts/create-api-account.ps1`.

- `Test-ContaApiViaProxy.ps1` (novo, caixa-preta, 15 casos): as credenciais ficam no Vault; o
  login via proxy entra como o schema do ambiente e o Oracle registra a conta como `PROXY_USER`;
  a sessão proxyada consegue criar e apagar tabela (o Flyway da API precisa disso); a conta
  liberada em `TESTE_DEV` não alcança `DEV` nem `PROD`; usa `KAWASHI_SERVICE_PROFILE` e está
  `OPEN`; tem só `CREATE SESSION` e nenhuma role; 8 sessões proxyadas simultâneas não são
  rejeitadas; `-Servicos` é aditivo e por serviço; e as falhas não deixam nada pela metade
  (conta duplicada, `-Ambiente PROD`, nome reservado, `.env` já existente). Ver item 21 de
  `bugs-primeiro-teste.md` (decisão de arquitetura).
- A suíte esperada passa de 247 para **262** casos, de 35 para **36** arquivos.

### Rodada "sai o SEFAZ, entra o schema de log"

Os schemas de serviço de exemplo (`SEFAZ`, `SIMPLES_NACIONAL`), a fixture `CLIENTE` +
`CONFIGURACAO_FISCAL`, o parâmetro `-Servicos` e o `grant-service-access.ps1` foram removidos: eram
só material de teste (item 22 de `bugs-primeiro-teste.md`). As rodadas acima que falam deles ficam
como histórico.

- Saíram `Test-SegmentacaoPorServico.ps1`, `Test-ConcessaoServicoUsuarioExistente.ps1` e
  `Test-InvarianteFkPadraoNuncaReferenciaServico.ps1`, e os 3 casos de `-Servicos` de
  `Test-ContaApiViaProxy.ps1` (que ficou com 12).
- `Test-SchemaLogSomenteInsercao.ps1` (novo, caixa-preta, 16 casos): entra como uma conta de API de
  verdade no schema de log (`oracle-init/11_schema_log.sql`) e confirma que ela insere, mas não
  altera, não apaga, não esvazia, não desliga o gatilho, não enxerga a tabela de controle e não loga
  no schema; que numeração, hora e hash forjados por quem insere são ignorados; e que a view de
  conferência acusa as três adulterações feitas como DBA (conteúdo alterado, linha do meio apagada,
  última linha apagada). No fim devolve a corrente do ambiente de teste ao estado inicial.
- `Run-AllTests.ps1` agora roda o `vault-init.ps1` antes (o Vault em modo dev perde tudo a cada
  restart) e conta um arquivo de teste que aborta como uma falha, em vez de derrubar a suíte sem
  resumo.
- Total da suíte: **262** casos em **34** arquivos.

### Rodada "a API deixa de ser dona das tabelas, e o log ganha âncora"

Item 23 de `bugs-primeiro-teste.md`.

- `Test-ContaApiViaProxy.ps1` (de 12 para 16 casos): a conta padrão agora é a de **execução**, que
  entra no schema `_APP`; o teste confirma que ela não cria tabela (nem no `_APP` nem no schema do
  ambiente) e não entra como dona, que a conta de **migração** (`-Papel Migracao`) cria e apaga
  tabela e não entra no `_APP`, e que o `-OutEnvFile` acrescenta a segunda conta ao mesmo arquivo
  sem trocar a primeira.
- `Test-SchemaLogSomenteInsercao.ps1` (de 16 para 17): passa a usar a conta de execução e confirma
  que a de migração não lê nem grava no log.
- `Test-AncoraDoLog.ps1` (novo, caixa-preta, 8 casos): ancora o log no Vault e faz o ataque de
  verdade. Como DBA, altera uma linha ancorada e recalcula a corrente inteira; confirma primeiro que
  a view interna volta a ficar vazia (o encadeamento sozinho não vê) e depois que a conferência
  contra o Vault denuncia. Cobre também o DBA que apaga o fim do log, e que o script se recusa a
  ancorar por cima de uma divergência.
- Total da suíte: **275** casos em **35** arquivos.

### Rodada "disco cifrado e cadastro de contas"

Itens 24 e 25 de `bugs-primeiro-teste.md`.

- `Test-CriptografiaEmDisco.ps1` (novo, caixa-preta, 12 casos): o keystore está aberto e abre
  sozinho no boot, todas as `TS_KAWASHI_*` e a `USERS` estão cifradas em AES-256, tablespace nova
  nasce cifrada. E a prova por fora: grava uma marca num ambiente e procura byte a byte em todos os
  arquivos do banco (dados, undo, redo); não acha. Controle positivo: a mesma marca gravada na
  `SYSAUX` (sem cifra) **é** achada, senão "não achei" não provaria nada.
- `Test-CadastroDeContas.ps1` (novo, caixa-preta, 24 casos): pessoa e conta de API criadas pelos
  scripts entram no cadastro (com nome acentuado e apóstrofo intactos); `GRANT` dado por fora aparece
  e some do painel na hora; conta criada por fora aparece como `SEM CADASTRO`; a regra dos 90 dias nas
  fronteiras (74, 75, 90, 91 dias) e por status; a conta de API não expira para o Oracle mas o painel
  cobra; nem o DBA altera a tabela direto; conta comum não lê o painel; cargo com SQL é recusado.
- `Test-InventarioDeSeguranca.ps1`: o inventário passou a esperar `KAWASHI_CONTA`,
  `KAWASHI_REGISTRAR_CONTA` e `KAWASHI_SITUACAO_DA_SENHA`.
- `Run-AllTests.ps1` apaga, no fim, o cadastro das contas descartáveis (`TST_*`) que já não existem.
- Total da suíte: **311** casos em **37** arquivos, todos passando.

### Rodada "portas, desligamento e rotina diária"

Itens 26, 27 e 28 de `bugs-primeiro-teste.md`.

- `Test-PortasSoNaMaquinaLocal.ps1` (novo, caixa-branca, 3 casos): o `docker-compose.yml` publica o
  banco e o Vault só em `127.0.0.1`. O container que está rodando é conferido ao vivo pela rotina
  diária, que acusa porta exposta até ele ser recriado.
- `Test-DesligamentoDePessoa.ps1` (novo, caixa-preta, 21 casos): abre duas sessões **reais** (uma
  direta, uma por proxy) e desliga a pessoa. Confere que os logins são recusados, que não sobra proxy,
  role, privilégio nem permissão, que as duas sessões caem (contadas por uma marca própria do teste,
  e não pela mesma busca da procedure), que o Vault foi limpo, que o painel mostra `DESLIGADA` e vira
  alarme se a conta for reaberta ou receber acesso; as recusas (API, ADMIN, DBA, inexistente), rodar
  de novo e o `-Apagar` com recriação do mesmo nome. Define `$ErrorActionPreference = 'Continue'`:
  no modo `Stop` do runner, o "No value found" do Vault (que é o resultado esperado) virava exceção.
- `Test-RotinaDiaria.ps1` (novo, outros, 7 casos): roda a rotina com `-File` (como o Agendador),
  confere relatório, âncoras nos 6 ambientes e o código de saída; planta uma conta criada por fora e
  confere que é acusada; agenda e tira uma tarefa de teste no Agendador do Windows.
- `Test-InventarioDeSeguranca.ps1`: passou a esperar `KAWASHI_DESLIGAR_CONTA`.
- Total da suíte: **342** casos em **40** arquivos.

### Rodada "troca da senha da API e conexão cifrada"

Itens 29 e 30 de `bugs-primeiro-teste.md`.

- `Test-RotacaoSenhaApi.ps1` (novo, caixa-preta, 13 casos): troca a senha de uma conta de API com um
  `.env` de teste. Vault e `.env` ficam iguais e diferentes da antiga, só a linha da senha muda no
  `.env`, nenhuma senha aparece na saída. Durante a troca gradual a antiga **e** a nova entram (a API
  rodando não cai) e o painel mostra a pendência; uma segunda troca no meio é recusada;
  `-EncerrarSenhaAntiga` corta a antiga; `-Imediata`; o segredo é regravado completo se o Vault
  tiver sido reiniciado; recusa `.env` de outra conta (nada muda) e conta de pessoa. Conferido
  quebrando de propósito: sem a troca gradual no perfil, 4 casos falham.
- `Test-ConexaoCifrada.ps1` (novo, caixa-preta, 10 casos): conexões pela rede de verdade negociam
  AES256 e SHA256; um cliente que recusa cifra, ou a conferência de integridade, é barrado
  (`ORA-12660`); o listener recusa `SET` (`TNS-12508`); rodar de novo não duplica o bloco; a conexão
  local do SYSDBA segue funcionando. **Controle:** desfaz a configuração, confirma que o mesmo
  cliente teimoso entra, e aplica de novo.
- Total da suíte: **365** casos em **42** arquivos, todos passando.

### Rodada "login da aplicação"

Item 31 de `bugs-primeiro-teste.md`.

- `Test-SchemaLogin.ps1` (novo, caixa-preta, 10 casos): os 12 schemas `_LOGIN`/`_SESSAO` sem login
  possível; as permissões EXATAS da conta de execução (nenhum DELETE); a conta de migração sem nada
  (nem lê os hashes de senha); a API lê os parâmetros mas não altera, e não apaga token nem log;
  mudança de parâmetro pelo DBA vira linha no `LOG_SEGURANCA` com valor antigo, novo e quem mudou;
  número e hash forjados ignorados; adulteração aparece na view de quebras; hora em UTC; o job de
  limpeza apaga só o vencido; a procedure da chave `USUARIO → PESSOA` só é chamável pelo schema do
  ambiente.
- `Test-InventarioDeSeguranca.ps1`: passou a esperar `KAWASHI_LIGAR_LOGIN_PESSOA` e o job
  `KAWASHI_LIMPEZA_SESSAO_JOB`.
- Total da suíte: **375** casos em **43** arquivos, todos passando.

### Rodada "login por passkey" (20/11/2026)

Itens 31 (complemento), 32 e 33 de `bugs-primeiro-teste.md`.

- `Test-SchemaLogin.ps1` reescrito para o modelo sem senha: as permissões EXATAS agora são usuário,
  passkey, convite, código de recuperação, token, desafio e bloqueio de IP (ler, criar, alterar) e
  parâmetros (só ler), ainda sem nenhum DELETE; 10 parâmetros; a conta de migração não lê nem os
  e-mails nem as chaves das passkeys; o job de limpeza apaga também o desafio vencido há mais de 1 dia.
  Conferido quebrando de propósito: com um `GRANT DELETE` a mais em `PASSKEY`, o caso das permissões
  falha (desfeito em seguida).
- `Run-AllTests.ps1` e oito scripts de `infra/scripts` passaram a funcionar com `powershell -File`
  (item 32).
- Total da suíte: **375** casos em **43** arquivos, todos passando (445 s).
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
