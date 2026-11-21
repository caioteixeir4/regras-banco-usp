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
-- ATUALIZACAO: a API agora entra nos ambientes pelo MESMO caminho das pessoas (proxy no
-- schema do ambiente), com uma conta de servico criada por infra/scripts/create-api-account.ps1
-- (ver item 21 de infra/docs/bugs-primeiro-teste.md). Producao ficou de fora, igual as pessoas.
--
-- TODO (continua em aberto): o usuario de aplicacao do Spring Boot
-- (APP_USER / KAWASHI_SPRING_USER, ver 06_access_management.sql) foi criado ANTES
-- desta conversa sobre ambientes, com seu proprio schema/tablespace
-- (TS_KAWASHI_DATA), e segue existindo. Falta decidir: quando a aplicacao for de fato ao ar,
-- ela deve conectar contra KAWASHI_ENV_PROD (o schema de producao "de verdade"
-- deste modelo, o que exigiria uma excecao explicita a regra de que ninguem alcanca
-- producao por proxy), ou o KAWASHI_SPRING_USER atual continua sendo uma coisa a parte?
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
-- 2.1 SCHEMA DE EXECUCAO DA APLICACAO (_APP) - a API roda sem ser dona de nada
-- #########################################################
-- Quem entra por proxy num schema de ambiente age como o DONO dele, e o dono de uma tabela
-- sempre pode apaga-la (DROP nao exige privilegio nenhum sobre objeto proprio). Enquanto a API
-- atendia os pedidos por esse caminho, quem a invadisse podia destruir as tabelas.
--
-- Agora sao duas contas de API por ambiente (ver infra/scripts/create-api-account.ps1 -Papel):
--   * MIGRACAO: proxy no schema do ambiente (KAWASHI_ENV_<AMBIENTE>). Cria e altera tabelas.
--     So e usada na subida da aplicacao, pelo Flyway.
--   * EXECUCAO: proxy no schema KAWASHI_ENV_<AMBIENTE>_APP, criado aqui. Esse schema nao tem
--     tabela, nao tem quota e so tem CREATE SESSION: nao consegue criar nem apagar nada. Recebe
--     apenas SELECT/INSERT/UPDATE/DELETE nas tabelas de cadastro (concedidos pela propria
--     migracao, depois de cria-las) e INSERT/SELECT no schema de log (11_schema_log.sql).
--
-- Idempotente: pode ser rodado de novo num banco que ja tem os schemas.
DECLARE
    v_total NUMBER;
BEGIN
    FOR a IN (SELECT column_value AS nome
                FROM TABLE(sys.odcivarchar2list('TESTE_DEV', 'TESTE_INFRA', 'DEV', 'INFRA', 'HOMOLOG', 'PROD'))) LOOP
        SELECT COUNT(*) INTO v_total FROM dba_users WHERE username = 'KAWASHI_ENV_' || a.nome || '_APP';
        IF v_total = 0 THEN
            EXECUTE IMMEDIATE 'CREATE USER KAWASHI_ENV_' || a.nome || '_APP NO AUTHENTICATION';
            EXECUTE IMMEDIATE 'GRANT CREATE SESSION TO KAWASHI_ENV_' || a.nome || '_APP';
        END IF;
    END LOOP;
END;
/

-- Alem dos schemas de ambiente, cada ambiente tem um schema de LOG proprio
-- (KAWASHI_ENV_<AMBIENTE>_LOG), criado em 11_schema_log.sql: guarda os logs da
-- aplicacao e a conta de execucao da API so consegue INSERIR e LER nele.

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
