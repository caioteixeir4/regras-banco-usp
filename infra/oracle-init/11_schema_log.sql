-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 21 - SCHEMA DE LOG DA APLICACAO, UM POR AMBIENTE
-- #########################################################
-- Cada ambiente ganha um schema KAWASHI_ENV_<AMBIENTE>_LOG com os logs da API:
--
--   LOG_ALTERACAO  quem criou/alterou/apagou qual registro (encadeado por hash)
--   LOG_ACESSO     cada chamada a API
--   LOG_CADEIA     controle interno do encadeamento (ninguem de fora enxerga)
--
-- POR QUE ESTAS TABELAS SAO CRIADAS AQUI, e nao pelo Flyway do repositorio da API
-- (que cria todas as outras tabelas de negocio): quem e DONO de uma tabela sempre
-- consegue alterar e apagar as linhas dela. A API entra no banco como o schema do
-- ambiente (proxy); se ela criasse as tabelas de log, seria dona delas, e "a API so
-- insere" seria uma promessa, nao uma garantia. Aqui o dono e o schema _LOG, em
-- que NINGUEM loga (NO AUTHENTICATION, sem CREATE SESSION, sem proxy), e o schema
-- de execucao da API (_APP) recebe so INSERT e SELECT.
--
-- ENCADEAMENTO (LOG_ALTERACAO): um trigger, que roda como o dono, numera cada
-- linha (ORDEM, sem buracos), carimba a hora do SERVIDOR e grava
-- HASH = SHA-256(hash da linha anterior + conteudo desta). Quem insere nao escolhe
-- nenhum desses valores. Apagar ou alterar uma linha pelo meio quebra a corrente e
-- aparece na view V_LOG_ALTERACAO_QUEBRAS (vazia = corrente inteira).
--
-- LIMITE HONESTO: quem tem DBA consegue recalcular a corrente inteira. O
-- encadeamento protege contra adulteracao parcial e contra a propria aplicacao;
-- contra um DBA mal-intencionado a defesa e a trilha de auditoria do banco
-- (03_dynamic_tables.sql / 05_context_triggers.sql), que registra o que ele fez.
--
-- O trigger trava a linha de controle (LOG_CADEIA) ate o fim da transacao de quem
-- insere: as gravacoes de log de um mesmo ambiente sao serializadas. E o preco de
-- uma corrente sem buracos; a API grava o log como ultima instrucao da transacao.
--
-- Idempotente: pode ser rodado de novo num banco que ja tem os schemas.

DECLARE
    PROCEDURE executar(p_sql VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
    END;

    FUNCTION existe_tabela(p_dono VARCHAR2, p_tabela VARCHAR2) RETURN BOOLEAN IS
        v_total NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_total FROM dba_tables WHERE owner = p_dono AND table_name = p_tabela;
        RETURN v_total > 0;
    END;

    PROCEDURE criar_schema_de_log(p_ambiente VARCHAR2) IS
        v_env   VARCHAR2(60) := 'KAWASHI_ENV_' || p_ambiente;
        v_log   VARCHAR2(60) := 'KAWASHI_ENV_' || p_ambiente || '_LOG';
        v_app   VARCHAR2(60) := 'KAWASHI_ENV_' || p_ambiente || '_APP';
        v_ts   VARCHAR2(60) := 'TS_KAWASHI_ENV_' || p_ambiente;
        v_total NUMBER;
        -- O que entra no hash de cada linha. Usado IGUAL no trigger e na view de conferencia.
        v_conteudo VARCHAR2(600) :=
            q'[NVL(#P#HASH_ANTERIOR, '-') || '|' || #P#ORDEM || '|' || #P#TABELA || '|' || #P#REGISTRO_ID || '|' || #P#ACAO || '|' || #P#USUARIO || '|' || TO_CHAR(#P#DATA_HORA, 'YYYY-MM-DD"T"HH24:MI:SS.FF6') || '|' || #P#DETALHE]';
    BEGIN
        SELECT COUNT(*) INTO v_total FROM dba_users WHERE username = v_log;
        IF v_total = 0 THEN
            -- Mesmo tablespace do ambiente "pai". Nenhum privilegio de sistema: ninguem loga aqui.
            executar('CREATE USER ' || v_log || ' NO AUTHENTICATION DEFAULT TABLESPACE ' || v_ts
                     || ' QUOTA UNLIMITED ON ' || v_ts);
        END IF;

        IF NOT existe_tabela(v_log, 'LOG_CADEIA') THEN
            executar('CREATE TABLE ' || v_log || '.LOG_CADEIA (
                TABELA        VARCHAR2(30) NOT NULL,
                ULTIMA_ORDEM  NUMBER       DEFAULT 0 NOT NULL,
                ULTIMO_HASH   VARCHAR2(64),
                CONSTRAINT PK_LOG_CADEIA PRIMARY KEY (TABELA))');
            executar('INSERT INTO ' || v_log || '.LOG_CADEIA (TABELA) VALUES (''LOG_ALTERACAO'')');
        END IF;

        IF NOT existe_tabela(v_log, 'LOG_ALTERACAO') THEN
            executar('CREATE TABLE ' || v_log || '.LOG_ALTERACAO (
                ID             NUMBER GENERATED ALWAYS AS IDENTITY,
                ORDEM          NUMBER             NOT NULL,
                TABELA         VARCHAR2(30)       NOT NULL,
                REGISTRO_ID    NUMBER             NOT NULL,
                ACAO           VARCHAR2(10)       NOT NULL,
                USUARIO        VARCHAR2(128)      NOT NULL,
                DATA_HORA      TIMESTAMP(6)       DEFAULT SYSTIMESTAMP NOT NULL,
                DETALHE        VARCHAR2(1000 CHAR),
                HASH_ANTERIOR  VARCHAR2(64),
                HASH           VARCHAR2(64)       NOT NULL,
                CONSTRAINT PK_LOG_ALTERACAO PRIMARY KEY (ID),
                CONSTRAINT UK_LOG_ALTERACAO_ORDEM UNIQUE (ORDEM),
                CONSTRAINT CK_LOG_ALTERACAO_ACAO CHECK (ACAO IN (''INSERT'', ''UPDATE'', ''DELETE'')))');
            executar('CREATE INDEX ' || v_log || '.IX_LOG_ALTERACAO_REGISTRO ON ' || v_log
                     || '.LOG_ALTERACAO (TABELA, REGISTRO_ID)');
        END IF;

        IF NOT existe_tabela(v_log, 'LOG_ACESSO') THEN
            executar('CREATE TABLE ' || v_log || '.LOG_ACESSO (
                ID          NUMBER GENERATED ALWAYS AS IDENTITY,
                USUARIO     VARCHAR2(128),
                IP_ORIGEM   VARCHAR2(45),
                METODO      VARCHAR2(10)        NOT NULL,
                CAMINHO     VARCHAR2(500 CHAR)  NOT NULL,
                STATUS      NUMBER(3)           NOT NULL,
                DATA_HORA   TIMESTAMP(6)        DEFAULT SYSTIMESTAMP NOT NULL,
                CONSTRAINT PK_LOG_ACESSO PRIMARY KEY (ID))');
            executar('CREATE INDEX ' || v_log || '.IX_LOG_ACESSO_DATA ON ' || v_log || '.LOG_ACESSO (DATA_HORA)');
        END IF;

        -- Numera, carimba a hora e encadeia. ORDEM, DATA_HORA, HASH_ANTERIOR e HASH informados por
        -- quem insere sao IGNORADOS: valem os calculados aqui.
        executar('CREATE OR REPLACE TRIGGER ' || v_log || '.LOG_ALTERACAO_CADEIA_TRG
            BEFORE INSERT ON ' || v_log || '.LOG_ALTERACAO
            FOR EACH ROW
            DECLARE
                v_hash RAW(32);
            BEGIN
                SELECT ULTIMA_ORDEM + 1, ULTIMO_HASH INTO :NEW.ORDEM, :NEW.HASH_ANTERIOR
                  FROM ' || v_log || '.LOG_CADEIA WHERE TABELA = ''LOG_ALTERACAO'' FOR UPDATE;
                :NEW.DATA_HORA := SYSTIMESTAMP;
                SELECT STANDARD_HASH(' || REPLACE(v_conteudo, '#P#', ':NEW.') || ', ''SHA256'') INTO v_hash FROM DUAL;
                :NEW.HASH := LOWER(RAWTOHEX(v_hash));
                UPDATE ' || v_log || '.LOG_CADEIA SET ULTIMA_ORDEM = :NEW.ORDEM, ULTIMO_HASH = :NEW.HASH
                 WHERE TABELA = ''LOG_ALTERACAO'';
            END;');

        -- A hora do LOG_ACESSO tambem e a do servidor, nao a que a aplicacao disser.
        executar('CREATE OR REPLACE TRIGGER ' || v_log || '.LOG_ACESSO_HORA_TRG
            BEFORE INSERT ON ' || v_log || '.LOG_ACESSO
            FOR EACH ROW
            BEGIN
                :NEW.DATA_HORA := SYSTIMESTAMP;
            END;');

        -- Conferencia da corrente: devolve uma linha por problema; vazia = corrente inteira.
        executar('CREATE OR REPLACE VIEW ' || v_log || '.V_LOG_ALTERACAO_QUEBRAS AS
            SELECT ORDEM, PROBLEMA FROM (
                SELECT l.ORDEM,
                       CASE
                           WHEN l.ORDEM <> NVL(LAG(l.ORDEM) OVER (ORDER BY l.ORDEM), 0) + 1
                               THEN ''falta linha antes desta (buraco na numeracao)''
                           WHEN NVL(l.HASH_ANTERIOR, ''-'') <> NVL(LAG(l.HASH) OVER (ORDER BY l.ORDEM), ''-'')
                               THEN ''nao encadeia com a linha anterior''
                           WHEN l.HASH <> LOWER(RAWTOHEX(STANDARD_HASH(' || REPLACE(v_conteudo, '#P#', 'l.') || ', ''SHA256'')))
                               THEN ''conteudo alterado depois de gravado''
                       END AS PROBLEMA
                  FROM ' || v_log || '.LOG_ALTERACAO l)
             WHERE PROBLEMA IS NOT NULL
            UNION ALL
            SELECT c.ULTIMA_ORDEM, ''faltam linhas no fim (a ultima gravada nao esta mais na tabela)''
              FROM ' || v_log || '.LOG_CADEIA c
             WHERE c.TABELA = ''LOG_ALTERACAO''
               AND c.ULTIMA_ORDEM <> (SELECT NVL(MAX(ORDEM), 0) FROM ' || v_log || '.LOG_ALTERACAO)');

        -- So o schema de EXECUCAO da API (_APP, ver 09_environments.sql secao 2.1) INSERE e LE.
        -- Sem UPDATE, sem DELETE, e nada sobre LOG_CADEIA. O schema do ambiente (a conta de
        -- migracao e as pessoas) nao recebe nada aqui.
        executar('GRANT INSERT, SELECT ON ' || v_log || '.LOG_ALTERACAO TO ' || v_app);
        executar('GRANT INSERT, SELECT ON ' || v_log || '.LOG_ACESSO TO ' || v_app);
        executar('GRANT SELECT ON ' || v_log || '.V_LOG_ALTERACAO_QUEBRAS TO ' || v_app);
        -- Bancos criados antes da separacao das contas davam estes privilegios ao schema do
        -- ambiente: tira, se ainda existirem.
        FOR p IN (SELECT privilege, table_name FROM dba_tab_privs WHERE owner = v_log AND grantee = v_env) LOOP
            executar('REVOKE ' || p.privilege || ' ON ' || v_log || '.' || p.table_name || ' FROM ' || v_env);
        END LOOP;
    END;
BEGIN
    criar_schema_de_log('TESTE_DEV');
    criar_schema_de_log('TESTE_INFRA');
    criar_schema_de_log('DEV');
    criar_schema_de_log('INFRA');
    criar_schema_de_log('HOMOLOG');
    criar_schema_de_log('PROD');
    COMMIT;
END;
/
