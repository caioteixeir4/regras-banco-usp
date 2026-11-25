-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 19 - VPD: A EQUIPE DE INFRA NAO VE LINHA DE NEGOCIO
-- #########################################################
-- O time de Infra entra nos ambientes (HOMOLOG, por exemplo) para cuidar do banco: estrutura,
-- desempenho, logs tecnicos. Ele nao precisa ver os dados das empresas clientes. Com o VPD (Virtual
-- Private Database, pacote DBMS_RLS), o Oracle acrescenta sozinho um filtro a toda consulta nas
-- tabelas de negocio (EMPRESA, FILIAL, PESSOA, CONTATO, ENDERECO):
--
--   - quem entrou por proxy com uma conta de pessoa de perfil Infra ou EstagiarioInfra (o perfil vem
--     do cadastro de contas, SYS.KAWASHI_CONTA) recebe "1 = 0": nao le, nao altera, nao insere e
--     nao apaga nenhuma linha, nem com SELECT *;
--   - todo o resto (a API, a conta de migracao, o time de Desenvolvimento) nao e afetado.
--
-- Por que olhar a PESSOA e nao a role: entrando por proxy ("CONNECT THROUGH"), a sessao tem as roles
-- do schema do ambiente, nao as da pessoa. Quem e a pessoa vem de SYS_CONTEXT('USERENV','PROXY_USER').
--
-- Limites: SYS e quem tem EXEMPT ACCESS POLICY nao passam pelo filtro (conceder esse privilegio e DDL,
-- e fica no audit de DDL). Os dados pessoais ja sao cifrados pela API: o VPD decide QUAIS linhas, a
-- cifra decide o que da para LER nelas.
--
-- As politicas sao aplicadas por SYS.KAWASHI_LIGAR_VPD: aqui, para os ambientes que ja tem as
-- tabelas, e pelo afterMigrate.sql da API (que cria as tabelas) a cada migracao. Idempotente.

-- ---------------------------------------------------------------------------
-- A funcao da politica
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION KAWASHI_VPD_NEGOCIO (p_schema IN VARCHAR2, p_objeto IN VARCHAR2) RETURN VARCHAR2 AS
    v_pessoa VARCHAR2(128) := NVL(SYS_CONTEXT('USERENV', 'PROXY_USER'), SYS_CONTEXT('USERENV', 'SESSION_USER'));
    v_perfil VARCHAR2(30);
BEGIN
    SELECT MAX(PERFIL) INTO v_perfil FROM SYS.KAWASHI_CONTA WHERE USERNAME = v_pessoa AND TIPO = 'PESSOA';
    IF v_perfil IN ('Infra', 'EstagiarioInfra') THEN
        RETURN '1 = 0';
    END IF;
    RETURN NULL;
END;
/

-- ---------------------------------------------------------------------------
-- A procedure que aplica as politicas num ambiente
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE KAWASHI_LIGAR_VPD (p_ambiente IN VARCHAR2 DEFAULT NULL) AS
    v_quem  VARCHAR2(128) := SYS_CONTEXT('USERENV', 'SESSION_USER');
    v_env   VARCHAR2(128);
    v_total NUMBER;
BEGIN
    -- Quem chama de um schema de ambiente (o afterMigrate da API) so liga o PROPRIO ambiente.
    IF v_quem = 'SYS' AND p_ambiente IS NOT NULL THEN
        v_env := 'KAWASHI_ENV_' || UPPER(p_ambiente);
    ELSIF REGEXP_LIKE(v_quem, '^KAWASHI_ENV_[A-Z_]+$') AND v_quem NOT LIKE '%\_APP' ESCAPE '\'
          AND v_quem NOT LIKE '%\_LOG' ESCAPE '\' AND v_quem NOT LIKE '%\_LOGIN' ESCAPE '\'
          AND v_quem NOT LIKE '%\_SESSAO' ESCAPE '\' THEN
        v_env := v_quem;
    ELSE
        RAISE_APPLICATION_ERROR(-20092, 'KAWASHI_LIGAR_VPD: chamada so por um schema de ambiente (ou por SYS, com o ambiente).');
    END IF;
    IF NOT REGEXP_LIKE(v_env, '^KAWASHI_ENV_[A-Z_]{2,30}$') THEN
        RAISE_APPLICATION_ERROR(-20091, 'Ambiente invalido.');
    END IF;
    FOR t IN (SELECT table_name FROM dba_tables
               WHERE owner = v_env AND table_name IN ('EMPRESA', 'FILIAL', 'PESSOA', 'CONTATO', 'ENDERECO')) LOOP
        SELECT COUNT(*) INTO v_total FROM dba_policies
         WHERE object_owner = v_env AND object_name = t.table_name AND policy_name = 'KAWASHI_INFRA_NAO_VE';
        IF v_total = 0 THEN
            DBMS_RLS.ADD_POLICY(
                object_schema   => v_env,
                object_name     => t.table_name,
                policy_name     => 'KAWASHI_INFRA_NAO_VE',
                function_schema => 'SYS',
                policy_function => 'KAWASHI_VPD_NEGOCIO',
                statement_types => 'SELECT, INSERT, UPDATE, DELETE',
                update_check    => TRUE,
                policy_type     => DBMS_RLS.DYNAMIC);
        END IF;
    END LOOP;
END;
/

-- O schema de cada ambiente (a conta de migracao da API) chama a ligacao depois de criar as tabelas.
BEGIN
    FOR a IN (SELECT 'TESTE_DEV' amb FROM dual UNION ALL SELECT 'TESTE_INFRA' FROM dual UNION ALL SELECT 'DEV' FROM dual
              UNION ALL SELECT 'INFRA' FROM dual UNION ALL SELECT 'HOMOLOG' FROM dual UNION ALL SELECT 'PROD' FROM dual) LOOP
        EXECUTE IMMEDIATE 'GRANT EXECUTE ON SYS.KAWASHI_LIGAR_VPD TO KAWASHI_ENV_' || a.amb;
        KAWASHI_LIGAR_VPD(a.amb);
    END LOOP;
END;
/
