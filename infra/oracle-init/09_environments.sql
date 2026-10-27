-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 17 - AMBIENTES DE CICLO DE VIDA (TESTE_DEV / TESTE_INFRA / DEV / INFRA / HOMOLOG / PROD)
-- #########################################################
-- Isto implementa o item "Setup de 6 Bases" do roadmap do README, na forma que
-- da pra construir hoje: 6 SCHEMAS (usuarios donos de objetos) dentro do mesmo
-- banco/PDB unico que ja existe, um por etapa/equipe do fluxo de trabalho:
--
--   KAWASHI_ENV_TESTE_DEV   -> estagiarios do time de Desenvolvimento commitam aqui livremente
--   KAWASHI_ENV_TESTE_INFRA -> estagiarios do time de Infraestrutura commitam aqui livremente
--   KAWASHI_ENV_DEV         -> desenvolvedores commitam aqui livremente
--   KAWASHI_ENV_INFRA       -> time de infraestrutura commita aqui livremente
--   KAWASHI_ENV_HOMOLOG     -> destino de promocao vindo de DEV ou INFRA
--   KAWASHI_ENV_PROD        -> so o engenheiro do projeto (DBA) escreve aqui,
--                              manualmente, uma vez por mes, escolhendo o que
--                              de Homologacao ja foi validado
--
-- CORRIGIDO/EXPANDIDO (achado discutindo infra/tests/caixa-preta/Test-ControleColetivoDentroDoAmbiente.ps1):
-- ate a versao anterior deste arquivo, existia um UNICO ambiente "TESTE"
-- compartilhado por TODO estagiario, de qualquer time. Isso virou dois
-- ambientes de teste separados - um por time (Dev/Infra) - espelhando a
-- mesma separacao que ja existia entre DEV e INFRA "de verdade". O
-- `KAWASHI_ENV_TESTE` antigo foi renomeado para `KAWASHI_ENV_TESTE_DEV`
-- (mesmo proposito, time de Desenvolvimento); `KAWASHI_ENV_TESTE_INFRA` e
-- novo, para o time de Infraestrutura.
--
-- IMPORTANTE - isto e "isolamento logico", nao fisico: os 6 ainda rodam na
-- mesma instancia/PDB Oracle unica que ja temos. Um problema serio em TESTE
-- (ex: uma query mal escrita consumindo toda a CPU) ainda pode afetar PROD,
-- porque compartilham o mesmo motor por baixo. Isolamento de verdade (PDBs
-- separados ou containers/instancias separadas) e o proximo passo, quando a
-- arquitetura de hospedagem (local vs AWS) for decidida - fica registrado
-- como debito tecnico intencional, igual fizemos com o Vault em modo dev.
--
-- TODO (reconciliar futuramente): o usuario de aplicacao do Spring Boot
-- (APP_USER / KAWASHI_SPRING_USER, ver 06_access_management.sql) foi criado ANTES
-- desta conversa sobre ambientes, com seu proprio schema/tablespace
-- (TS_KAWASHI_DATA). Falta decidir: quando a aplicacao for de fato ao ar, ela
-- deve conectar contra KAWASHI_ENV_PROD (o schema de producao "de verdade"
-- deste modelo), ou o KAWASHI_SPRING_USER atual continua sendo uma coisa a parte?
-- Nao decidimos isso ainda - resolver antes de colocar dados reais em producao.

-- #########################################################
-- 1. TABLESPACES - um espaco fisico por ambiente
-- #########################################################
-- Mesma logica do 01_setup_kawashi.sql: cada ambiente ganha seu proprio
-- "HD virtual". Isso e o que faz a QUOTA (secao 3) funcionar como cerca real:
-- se uma pessoa so tem quota no tablespace de TESTE_DEV, ela fisicamente nao
-- consegue gravar em nenhum outro ambiente, mesmo que tente.
-- MAXSIZE em todos: mesma razao do 01_setup_kawashi.sql - sem teto, um erro de
-- estagiario/dev pode encher o disco da maquina inteira, nao so o ambiente dele.
--
-- Os schemas de SERVICO criados na secao 2.1 (SEFAZ, SIMPLES_NACIONAL, etc.)
-- NAO ganham tablespace proprio - moram no MESMO tablespace fisico do
-- ambiente "pai" deles. Criar 12 tablespaces (6 ambientes x 2 servicos) só
-- pra repetir um isolamento fisico que este projeto ja decidiu nao perseguir
-- ainda (ver Technical Debts do README) nao traria beneficio real agora.
CREATE TABLESPACE TS_KAWASHI_ENV_TESTE_DEV   DATAFILE 'ts_kawashi_env_teste_dev.dbf'   SIZE 50M  AUTOEXTEND ON MAXSIZE 1G;
CREATE TABLESPACE TS_KAWASHI_ENV_TESTE_INFRA DATAFILE 'ts_kawashi_env_teste_infra.dbf' SIZE 50M  AUTOEXTEND ON MAXSIZE 1G;
CREATE TABLESPACE TS_KAWASHI_ENV_DEV         DATAFILE 'ts_kawashi_env_dev.dbf'         SIZE 50M  AUTOEXTEND ON MAXSIZE 1G;
CREATE TABLESPACE TS_KAWASHI_ENV_INFRA       DATAFILE 'ts_kawashi_env_infra.dbf'       SIZE 50M  AUTOEXTEND ON MAXSIZE 1G;
CREATE TABLESPACE TS_KAWASHI_ENV_HOMOLOG     DATAFILE 'ts_kawashi_env_homolog.dbf'     SIZE 50M  AUTOEXTEND ON MAXSIZE 1G;
CREATE TABLESPACE TS_KAWASHI_ENV_PROD        DATAFILE 'ts_kawashi_env_prod.dbf'        SIZE 100M AUTOEXTEND ON MAXSIZE 2G;

-- #########################################################
-- 2. SCHEMAS DE AMBIENTE - usuarios "donos", ninguem loga neles direto
-- #########################################################
-- "NO AUTHENTICATION" cria um usuario que NAO TEM SENHA - ninguem consegue
-- fazer `CONNECT KAWASHI_ENV_DEV/alguma_senha`, porque nao existe senha
-- nenhuma pra tentar. Esse tipo de usuario existe so pra "ser dono" de
-- tabelas/views/procedures - e o jeito certo do Oracle de modelar "isto e um
-- ambiente compartilhado", nao uma pessoa. As pessoas de verdade (estagiarios,
-- devs, infra) acessam o ambiente atraves de PROXY AUTHENTICATION (secao 4),
-- nunca sabendo nem precisando saber alguma "senha do ambiente".
CREATE USER KAWASHI_ENV_TESTE_DEV   NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_TESTE_DEV   QUOTA UNLIMITED ON TS_KAWASHI_ENV_TESTE_DEV;
CREATE USER KAWASHI_ENV_TESTE_INFRA NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_TESTE_INFRA QUOTA UNLIMITED ON TS_KAWASHI_ENV_TESTE_INFRA;
CREATE USER KAWASHI_ENV_DEV         NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_DEV         QUOTA UNLIMITED ON TS_KAWASHI_ENV_DEV;
CREATE USER KAWASHI_ENV_INFRA       NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_INFRA       QUOTA UNLIMITED ON TS_KAWASHI_ENV_INFRA;
CREATE USER KAWASHI_ENV_HOMOLOG     NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_HOMOLOG     QUOTA UNLIMITED ON TS_KAWASHI_ENV_HOMOLOG;
CREATE USER KAWASHI_ENV_PROD        NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_PROD        QUOTA UNLIMITED ON TS_KAWASHI_ENV_PROD;

-- Cada schema de ambiente precisa poder criar seus proprios objetos (tabelas,
-- views, etc.) quando alguem estiver "conectado atraves dele" via proxy.
GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE SEQUENCE, CREATE PROCEDURE, CREATE TRIGGER
    TO KAWASHI_ENV_TESTE_DEV, KAWASHI_ENV_TESTE_INFRA, KAWASHI_ENV_DEV, KAWASHI_ENV_INFRA, KAWASHI_ENV_HOMOLOG, KAWASHI_ENV_PROD;

-- #########################################################
-- 2.1 SCHEMAS DE SERVICO - segmentacao por servico DENTRO de cada ambiente
-- #########################################################
-- NOVO: o banco de dados de negocio da Kawashi vai ter TABELAS PADRAO
-- compartilhadas entre servicos (ex: CLIENTE - dados cadastrais basicos que
-- qualquer servico usa; o conjunto completo, com ENDERECO, EMPRESA, FILIAL,
-- CONTATO, SOCIO etc., vive no repositorio de tabelas, nao aqui) e TABELAS
-- ESPECIFICAS de cada servico fiscal (ex: SEFAZ, SIMPLES_NACIONAL), que
-- referenciam as tabelas padrao via FK mas nao devem ser visiveis a quem nao
-- tem liberacao para aquele servico especifico. As REGRAS dessa segmentacao
-- (schemas, grants, proxy) sao deste repositorio; as tabelas em si, nao.
--
-- "Padrao" NAO ganha schema novo - continua sendo o proprio schema de
-- ambiente (KAWASHI_ENV_DEV, etc.) que ja existe, decisao deliberada pra nao
-- migrar nada que ja funciona. Isso tambem significa que a visibilidade do
-- padrao nao precisa de GRANT novo nenhum: quem ja tem CONNECT THROUGH no
-- ambiente ja ve as tabelas padrao dele, exatamente como ja funciona hoje.
--
-- Cada SERVICO ganha um schema novo, por ambiente, no formato
-- KAWASHI_ENV_<AMBIENTE>_<SERVICO> - tambem NO AUTHENTICATION, tambem
-- acessado via proxy, mas com uma liberacao ADITIVA e INDEPENDENTE da
-- liberacao do ambiente em si (ver infra/scripts/create-team-member.ps1,
-- parametro -Servicos): ter CONNECT THROUGH no ambiente nao da,  sozinho,
-- nenhum acesso aos schemas de servico dele.
--
-- Esta rodada implementa o padrao com 2 servicos de EXEMPLO (SEFAZ e
-- SIMPLES_NACIONAL) - mecanicamente repetivel pra mais servicos depois (so
-- replicar o mesmo bloco CREATE USER + GRANT com o novo nome).
CREATE USER KAWASHI_ENV_TESTE_DEV_SEFAZ             NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_TESTE_DEV   QUOTA UNLIMITED ON TS_KAWASHI_ENV_TESTE_DEV;
CREATE USER KAWASHI_ENV_TESTE_DEV_SIMPLES_NACIONAL  NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_TESTE_DEV   QUOTA UNLIMITED ON TS_KAWASHI_ENV_TESTE_DEV;
CREATE USER KAWASHI_ENV_TESTE_INFRA_SEFAZ           NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_TESTE_INFRA QUOTA UNLIMITED ON TS_KAWASHI_ENV_TESTE_INFRA;
CREATE USER KAWASHI_ENV_TESTE_INFRA_SIMPLES_NACIONAL NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_TESTE_INFRA QUOTA UNLIMITED ON TS_KAWASHI_ENV_TESTE_INFRA;
CREATE USER KAWASHI_ENV_DEV_SEFAZ                   NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_DEV         QUOTA UNLIMITED ON TS_KAWASHI_ENV_DEV;
CREATE USER KAWASHI_ENV_DEV_SIMPLES_NACIONAL        NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_DEV         QUOTA UNLIMITED ON TS_KAWASHI_ENV_DEV;
CREATE USER KAWASHI_ENV_INFRA_SEFAZ                 NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_INFRA       QUOTA UNLIMITED ON TS_KAWASHI_ENV_INFRA;
CREATE USER KAWASHI_ENV_INFRA_SIMPLES_NACIONAL      NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_INFRA       QUOTA UNLIMITED ON TS_KAWASHI_ENV_INFRA;
CREATE USER KAWASHI_ENV_HOMOLOG_SEFAZ               NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_HOMOLOG     QUOTA UNLIMITED ON TS_KAWASHI_ENV_HOMOLOG;
CREATE USER KAWASHI_ENV_HOMOLOG_SIMPLES_NACIONAL    NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_HOMOLOG     QUOTA UNLIMITED ON TS_KAWASHI_ENV_HOMOLOG;
CREATE USER KAWASHI_ENV_PROD_SEFAZ                  NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_PROD        QUOTA UNLIMITED ON TS_KAWASHI_ENV_PROD;
CREATE USER KAWASHI_ENV_PROD_SIMPLES_NACIONAL       NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_PROD        QUOTA UNLIMITED ON TS_KAWASHI_ENV_PROD;

GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE SEQUENCE, CREATE PROCEDURE, CREATE TRIGGER TO
    KAWASHI_ENV_TESTE_DEV_SEFAZ, KAWASHI_ENV_TESTE_DEV_SIMPLES_NACIONAL,
    KAWASHI_ENV_TESTE_INFRA_SEFAZ, KAWASHI_ENV_TESTE_INFRA_SIMPLES_NACIONAL,
    KAWASHI_ENV_DEV_SEFAZ, KAWASHI_ENV_DEV_SIMPLES_NACIONAL,
    KAWASHI_ENV_INFRA_SEFAZ, KAWASHI_ENV_INFRA_SIMPLES_NACIONAL,
    KAWASHI_ENV_HOMOLOG_SEFAZ, KAWASHI_ENV_HOMOLOG_SIMPLES_NACIONAL,
    KAWASHI_ENV_PROD_SEFAZ, KAWASHI_ENV_PROD_SIMPLES_NACIONAL;

-- NOTA: o GRANT REFERENCES (necessario pra uma tabela de servico ter FK pra
-- uma tabela padrao do mesmo ambiente) nao entra aqui - so pode ser concedido
-- depois que a tabela padrao referenciada EXISTIR. Ver
-- infra/oracle-init/11_fixture_contrato_segmentacao.sql, que cria a fixture
-- minima (CLIENTE + SEFAZ.CONFIGURACAO_FISCAL) e os GRANTs de REFERENCES juntos.

-- #########################################################
-- 3. QUEM PODE ENTRAR EM CADA AMBIENTE (PROXY AUTHENTICATION)
-- #########################################################
-- Este arquivo roda no bootstrap do container, ANTES de qualquer pessoa
-- (estagiario, dev, etc.) existir como usuario - por isso NAO ha nenhum
-- "GRANT CONNECT THROUGH <pessoa>" aqui. Quem concede isso, pessoa por
-- pessoa, e o infra/scripts/create-team-member.ps1, na hora de criar cada
-- conta, de acordo com o -Profile escolhido:
--
--   Profile EstagiarioDev   -> CONNECT THROUGH em KAWASHI_ENV_TESTE_DEV apenas
--   Profile EstagiarioInfra -> CONNECT THROUGH em KAWASHI_ENV_TESTE_INFRA apenas
--   Profile Desenvolvedor   -> CONNECT THROUGH em KAWASHI_ENV_DEV e
--                              KAWASHI_ENV_HOMOLOG (decisao do time: dev pode
--                              promover direto pra Homologacao, sem passar
--                              por Teste - a revisao de codigo dos estagiarios
--                              acontece no Git/PR, nao no banco)
--   Profile Infra           -> CONNECT THROUGH em KAWASHI_ENV_INFRA e
--                              KAWASHI_ENV_HOMOLOG, + ROLE_KAWASHI_INFRA
--   Profile HomologViewer   -> NAO usa proxy (ver secao 5) - so leitura
--
-- Por que so Dev/Infra alcancam Homologacao? Porque a regra combinada foi
-- "commits em Homologacao precisam vir do esquema de Desenvolvimento ou do
-- esquema de Infra" - ao dar CONNECT THROUGH em Homologacao SOMENTE pra quem
-- tambem tem CONNECT THROUGH em Dev ou Infra, ninguem com acesso apenas a
-- Teste (estagiario) ou apenas leitura (QA) consegue escrever la, garantindo
-- essa proveniencia na pratica.
--
-- Producao (KAWASHI_ENV_PROD) nao aparece em NENHUM profile de proxy: a
-- unica conta capaz de escrever la e o ENGINEER_USER (grant DBA, ver
-- 08_engineer_account.sql), que nao precisa de proxy porque DBA ja pode
-- operar como qualquer schema.
--
-- ACESSO A SERVICO (-Servicos): e ADITIVO e INDEPENDENTE do -Profile - para
-- cada servico pedido (ex: SEFAZ), create-team-member.ps1 concede CONNECT
-- THROUGH no(s) schema(s) KAWASHI_ENV_<AMBIENTE>_<SERVICO> de TODO ambiente
-- que o -Profile escolhido ja alcanca. Ex: um Desenvolvedor com -Servicos
-- SEFAZ ganha proxy em KAWASHI_ENV_DEV_SEFAZ E KAWASHI_ENV_HOMOLOG_SEFAZ, mas
-- continua sem nenhum acesso a KAWASHI_ENV_DEV_SIMPLES_NACIONAL. Nao ter
-- nenhum -Servicos continua sendo uma opcao valida (acesso so as tabelas
-- padrao do ambiente, sem nenhum servico especifico).
--
-- FORA DE ESCOPO POR ENQUANTO (decisao explicita): o perfil HomologViewer
-- (QA) nao tem, ainda, uma versao "por servico" - ele continua enxergando
-- (so leitura) tudo que a secao 5 ja cobre em KAWASHI_ENV_HOMOLOG, sem
-- segmentacao por SEFAZ/SIMPLES_NACIONAL dentro de Homologacao.

-- #########################################################
-- 4. PERFIL "QA / HOMOLOG VIEWER" - so leitura, so em Homologacao
-- #########################################################
-- Diferente dos outros perfis, um leitor de QA NAO deve poder "virar" o
-- schema de Homologacao (isso daria poder de escrita/DDL completo) - ele so
-- pode fazer SELECT. Por isso este perfil usa uma ROLE com GRANT SELECT
-- objeto a objeto, em vez de proxy authentication.
CREATE ROLE ROLE_KAWASHI_HOMOLOG_VIEWER;
GRANT CREATE SESSION TO ROLE_KAWASHI_HOMOLOG_VIEWER;

-- Problema pratico: "GRANT SELECT ON <tabela> TO role" so cobre tabelas que
-- JA EXISTEM no momento do grant. O Oracle nao tem um equivalente ao "ALTER
-- DEFAULT PRIVILEGES" do Postgres (privilegio automatico em objetos futuros).
-- A solucao e este trigger: toda vez que uma TABLE ou VIEW nova for criada
-- dentro do schema KAWASHI_ENV_HOMOLOG, ele concede SELECT automaticamente
-- pra role de QA - sem isso, cada tabela nova ficaria invisivel pro QA ate
-- alguem lembrar de rodar um GRANT manual.
--
-- BUG ENCONTRADO TESTANDO AO VIVO (infra/tests/caixa-branca/Test-HomologAutograntTrigger.ps1):
-- a primeira versao deste trigger chamava "EXECUTE IMMEDIATE 'GRANT ...'"
-- diretamente no corpo do AFTER CREATE. Isso SEMPRE falhava com ORA-04088 /
-- ORA-30511 ("invalid DDL operation in system triggers") assim que alguem de
-- verdade proxyava pra KAWASHI_ENV_HOMOLOG e tentava criar uma tabela - ou
-- seja, o trigger quebrava exatamente a unica coisa que Homologacao existe
-- pra permitir. O Oracle proibe rodar outra DDL (GRANT incluso) de dentro de
-- um trigger de schema que esta reagindo a uma DDL, porque o objeto que
-- disparou o trigger ainda nao terminou de ser gravado no dicionario.
--
-- A solucao padrao do Oracle pra esse caso e NAO rodar o GRANT na hora: o
-- trigger agenda um job (DBMS_SCHEDULER.CREATE_JOB, execucao imediata,
-- auto_drop) que roda o GRANT numa sessao/transacao totalmente separada,
-- milissegundos depois - fora do contexto restrito do trigger. Por isso
-- KAWASHI_ENV_HOMOLOG tambem precisa do privilegio CREATE JOB (ver GRANT
-- logo abaixo), que nao fazia parte do conjunto de GRANTs da secao 2.
--
-- NOTA: este trigger cobre so o schema PADRAO de Homologacao
-- (KAWASHI_ENV_HOMOLOG) - os schemas de servico de Homologacao
-- (KAWASHI_ENV_HOMOLOG_SEFAZ, etc.) nao tem trigger equivalente ainda (ver
-- decisao "fora de escopo" na secao 3 acima).
GRANT CREATE JOB TO KAWASHI_ENV_HOMOLOG;

CREATE OR REPLACE TRIGGER KAWASHI_ENV_HOMOLOG.KAWASHI_HOMOLOG_AUTOGRANT_TRG
AFTER CREATE ON KAWASHI_ENV_HOMOLOG.SCHEMA
DECLARE
    v_owner VARCHAR2(128) := ORA_DICT_OBJ_OWNER;
    v_name  VARCHAR2(128) := ORA_DICT_OBJ_NAME;
    v_type  VARCHAR2(128) := ORA_DICT_OBJ_TYPE;
BEGIN
    IF v_type IN ('TABLE', 'VIEW') THEN
        DBMS_SCHEDULER.CREATE_JOB(
            job_name   => 'KAWASHI_AUTOGRANT_' || TO_CHAR(SYSTIMESTAMP, 'HH24MISSFF3'),
            job_type   => 'PLSQL_BLOCK',
            job_action => 'BEGIN EXECUTE IMMEDIATE ''GRANT SELECT ON ' || v_owner || '.' || v_name ||
                          ' TO ROLE_KAWASHI_HOMOLOG_VIEWER''; END;',
            start_date => SYSTIMESTAMP,
            enabled    => TRUE,
            auto_drop  => TRUE
        );
    END IF;
END;
/
