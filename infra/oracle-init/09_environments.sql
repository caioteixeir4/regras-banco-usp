-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 17 - AMBIENTES DE CICLO DE VIDA (TESTE / DEV / INFRA / HOMOLOG / PROD)
-- #########################################################
-- Isto implementa o item "Setup de 5 Bases" do roadmap do README, na forma que
-- da pra construir hoje: 5 SCHEMAS (usuarios donos de objetos) dentro do mesmo
-- banco/PDB unico que ja existe, um por etapa do fluxo de trabalho do time:
--
--   KAWASHI_ENV_TESTE     -> estagiarios commitam aqui livremente
--   KAWASHI_ENV_DEV       -> desenvolvedores commitam aqui livremente
--   KAWASHI_ENV_INFRA     -> time de infraestrutura commita aqui livremente
--   KAWASHI_ENV_HOMOLOG   -> destino de promocao vindo de DEV ou INFRA
--   KAWASHI_ENV_PROD      -> so o engenheiro do projeto (DBA) escreve aqui,
--                            manualmente, uma vez por mes, escolhendo o que
--                            de Homologacao ja foi validado
--
-- IMPORTANTE - isto e "isolamento logico", nao fisico: os 5 ainda rodam na
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
-- se uma pessoa so tem quota no tablespace de TESTE, ela fisicamente nao
-- consegue gravar em nenhum outro ambiente, mesmo que tente.
-- MAXSIZE em todos: mesma razao do 01_setup_kawashi.sql - sem teto, um erro de
-- estagiario/dev pode encher o disco da maquina inteira, nao so o ambiente dele.
CREATE TABLESPACE TS_KAWASHI_ENV_TESTE    DATAFILE 'ts_kawashi_env_teste.dbf'    SIZE 50M  AUTOEXTEND ON MAXSIZE 1G;
CREATE TABLESPACE TS_KAWASHI_ENV_DEV      DATAFILE 'ts_kawashi_env_dev.dbf'      SIZE 50M  AUTOEXTEND ON MAXSIZE 1G;
CREATE TABLESPACE TS_KAWASHI_ENV_INFRA    DATAFILE 'ts_kawashi_env_infra.dbf'    SIZE 50M  AUTOEXTEND ON MAXSIZE 1G;
CREATE TABLESPACE TS_KAWASHI_ENV_HOMOLOG  DATAFILE 'ts_kawashi_env_homolog.dbf'  SIZE 50M  AUTOEXTEND ON MAXSIZE 1G;
CREATE TABLESPACE TS_KAWASHI_ENV_PROD     DATAFILE 'ts_kawashi_env_prod.dbf'     SIZE 100M AUTOEXTEND ON MAXSIZE 2G;

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
CREATE USER KAWASHI_ENV_TESTE   NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_TESTE   QUOTA UNLIMITED ON TS_KAWASHI_ENV_TESTE;
CREATE USER KAWASHI_ENV_DEV     NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_DEV     QUOTA UNLIMITED ON TS_KAWASHI_ENV_DEV;
CREATE USER KAWASHI_ENV_INFRA   NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_INFRA   QUOTA UNLIMITED ON TS_KAWASHI_ENV_INFRA;
CREATE USER KAWASHI_ENV_HOMOLOG NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_HOMOLOG QUOTA UNLIMITED ON TS_KAWASHI_ENV_HOMOLOG;
CREATE USER KAWASHI_ENV_PROD    NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_PROD    QUOTA UNLIMITED ON TS_KAWASHI_ENV_PROD;

-- Cada schema de ambiente precisa poder criar seus proprios objetos (tabelas,
-- views, etc.) quando alguem estiver "conectado atraves dele" via proxy.
GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE SEQUENCE, CREATE PROCEDURE, CREATE TRIGGER
    TO KAWASHI_ENV_TESTE, KAWASHI_ENV_DEV, KAWASHI_ENV_INFRA, KAWASHI_ENV_HOMOLOG, KAWASHI_ENV_PROD;

-- #########################################################
-- 3. QUEM PODE ENTRAR EM CADA AMBIENTE (PROXY AUTHENTICATION)
-- #########################################################
-- Este arquivo roda no bootstrap do container, ANTES de qualquer pessoa
-- (estagiario, dev, etc.) existir como usuario - por isso NAO ha nenhum
-- "GRANT CONNECT THROUGH <pessoa>" aqui. Quem concede isso, pessoa por
-- pessoa, e o infra/scripts/create-team-member.ps1, na hora de criar cada
-- conta, de acordo com o -Profile escolhido:
--
--   Profile Estagiario     -> CONNECT THROUGH em KAWASHI_ENV_TESTE apenas
--   Profile Desenvolvedor  -> CONNECT THROUGH em KAWASHI_ENV_DEV e
--                             KAWASHI_ENV_HOMOLOG (decisao do time: dev pode
--                             promover direto pra Homologacao, sem passar
--                             por Teste - a revisao de codigo dos estagiarios
--                             acontece no Git/PR, nao no banco)
--   Profile Infra          -> CONNECT THROUGH em KAWASHI_ENV_INFRA e
--                             KAWASHI_ENV_HOMOLOG, + ROLE_KAWASHI_INFRA
--   Profile HomologViewer  -> NAO usa proxy (ver secao 5) - so leitura
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
