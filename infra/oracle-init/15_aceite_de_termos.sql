-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 15 - ACEITE DOS TERMOS DE USO E DA POLITICA DE PRIVACIDADE (LGPD)
-- #########################################################
-- O sistema guarda CPF, e-mail e telefone. A LGPD pede que se possa provar QUAL texto a pessoa
-- aceitou, QUANDO e DE ONDE. No schema KAWASHI_ENV_<AMB>_LOGIN:
--
--   TERMO          cada versao publicada de cada documento (termos de uso, politica de
--                  privacidade), com o TEXTO e o SHA-256 dele. Vale a versao mais recente de cada
--                  documento. So o DBA publica (infra/scripts/publicar-termo.ps1); a API so le.
--   ACEITE_TERMO   quem aceitou qual versao, quando e de qual IP. IMUTAVEL: a API so insere
--                  (nada de UPDATE nem DELETE), e o aceite vai para o LOG_SEGURANCA (TERMO_ACEITO).
--
-- A API recusa (403) os pedidos de quem nao aceitou as versoes vigentes, menos o proprio login.
-- O texto que nasce aqui e um RASCUNHO: a Kawashi precisa redigir os textos de verdade e publicar
-- como versao nova.
--
-- Idempotente: pode ser rodado de novo num banco que ja tem tudo.

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

    PROCEDURE criar_termos(p_ambiente VARCHAR2) IS
        v_env   VARCHAR2(60) := 'KAWASHI_ENV_' || p_ambiente;
        v_login VARCHAR2(60) := v_env || '_LOGIN';
        v_log   VARCHAR2(60) := v_env || '_LOG';
        v_app   VARCHAR2(60) := v_env || '_APP';
        v_agora VARCHAR2(40) := 'SYS_EXTRACT_UTC(SYSTIMESTAMP)';
        v_total NUMBER;
    BEGIN
        IF NOT existe_tabela(v_login, 'TERMO') THEN
            executar('CREATE TABLE ' || v_login || '.TERMO (
                ID             NUMBER GENERATED ALWAYS AS IDENTITY,
                DOCUMENTO      VARCHAR2(30)    NOT NULL,
                VERSAO         VARCHAR2(20)    NOT NULL,
                TEXTO          CLOB            NOT NULL,
                HASH_TEXTO     VARCHAR2(64)    NOT NULL,
                PUBLICADO_POR  VARCHAR2(128)   NOT NULL,
                PUBLICADO_EM   TIMESTAMP(6)    DEFAULT ' || v_agora || ' NOT NULL,
                CONSTRAINT PK_TERMO PRIMARY KEY (ID),
                CONSTRAINT UK_TERMO UNIQUE (DOCUMENTO, VERSAO),
                CONSTRAINT CK_TERMO_DOCUMENTO CHECK (DOCUMENTO IN (''TERMOS_DE_USO'', ''POLITICA_DE_PRIVACIDADE'')),
                CONSTRAINT CK_TERMO_HASH CHECK (REGEXP_LIKE(HASH_TEXTO, ''^[0-9a-f]{64}$'')))');
        END IF;

        IF NOT existe_tabela(v_login, 'ACEITE_TERMO') THEN
            executar('CREATE TABLE ' || v_login || '.ACEITE_TERMO (
                ID          NUMBER GENERATED ALWAYS AS IDENTITY,
                USUARIO_ID  NUMBER          NOT NULL,
                TERMO_ID    NUMBER          NOT NULL,
                IP_ORIGEM   VARCHAR2(45),
                ACEITO_EM   TIMESTAMP(6)    DEFAULT ' || v_agora || ' NOT NULL,
                CONSTRAINT PK_ACEITE_TERMO PRIMARY KEY (ID),
                CONSTRAINT UK_ACEITE_TERMO UNIQUE (USUARIO_ID, TERMO_ID),
                CONSTRAINT FK_ACEITE_TERMO_USUARIO FOREIGN KEY (USUARIO_ID) REFERENCES ' || v_login || '.USUARIO (ID),
                CONSTRAINT FK_ACEITE_TERMO_TERMO FOREIGN KEY (TERMO_ID) REFERENCES ' || v_login || '.TERMO (ID))');
        END IF;

        -- Publicar: o hash do texto e quem publicou sao postos pelo banco (o informado e ignorado).
        -- Um termo publicado nao muda: versao nova e uma linha nova.
        executar('CREATE OR REPLACE TRIGGER ' || v_login || '.TERMO_TRG
            BEFORE INSERT OR UPDATE OR DELETE ON ' || v_login || '.TERMO
            FOR EACH ROW
            BEGIN
                IF UPDATING OR DELETING THEN
                    RAISE_APPLICATION_ERROR(-20111, ''Termo publicado nao muda nem sai: publique uma versao nova.'');
                END IF;
                :NEW.HASH_TEXTO := LOWER(RAWTOHEX(DBMS_CRYPTO.HASH(:NEW.TEXTO, 4)));
                :NEW.PUBLICADO_POR := NVL(SYS_CONTEXT(''USERENV'', ''PROXY_USER''), SYS_CONTEXT(''USERENV'', ''SESSION_USER''));
                :NEW.PUBLICADO_EM := ' || v_agora || ';
            END;');

        -- Aceite: a hora e do servidor; cada aceite vai para o LOG_SEGURANCA.
        executar('CREATE OR REPLACE TRIGGER ' || v_login || '.ACEITE_TERMO_TRG
            BEFORE INSERT ON ' || v_login || '.ACEITE_TERMO
            FOR EACH ROW
            DECLARE
                v_doc VARCHAR2(30);
                v_ver VARCHAR2(20);
            BEGIN
                :NEW.ACEITO_EM := ' || v_agora || ';
                SELECT DOCUMENTO, VERSAO INTO v_doc, v_ver FROM ' || v_login || '.TERMO WHERE ID = :NEW.TERMO_ID;
                INSERT INTO ' || v_log || '.LOG_SEGURANCA (ORDEM, EVENTO, USUARIO_ID, DETALHE, IP_ORIGEM, FEITO_POR, HASH)
                VALUES (0, ''TERMO_ACEITO'', :NEW.USUARIO_ID, v_doc || '' versao '' || v_ver, :NEW.IP_ORIGEM, ''USUARIO:'' || :NEW.USUARIO_ID, ''-'');
            END;');

        -- O evento TERMO_ACEITO esta na lista unica do LOG_SEGURANCA, no 14_autorizacao.sql (que roda antes).

        -- Versao 1 de cada documento: RASCUNHO, a ser substituido pelo texto redigido pela Kawashi.
        FOR d IN (SELECT 'TERMOS_DE_USO' doc, 'Termos de uso do sistema Kawashi (RASCUNHO, versao 1). Ao usar o sistema, voce concorda em acessar '
                         || 'apenas os dados das empresas em que tem acesso, nao compartilhar sua passkey nem seus codigos de recuperacao, '
                         || 'e comunicar ao administrador da sua empresa qualquer acesso indevido. Este texto e provisorio e sera '
                         || 'substituido pela versao redigida pela Kawashi.' txt FROM dual
                  UNION ALL
                  SELECT 'POLITICA_DE_PRIVACIDADE', 'Politica de privacidade do sistema Kawashi (RASCUNHO, versao 1). O sistema guarda nome, CPF ou CNPJ, '
                         || 'e-mail e telefone para o cadastro das empresas. CPF, e-mail e telefone sao gravados cifrados e aparecem '
                         || 'mascarados; ver o valor inteiro exige permissao propria e fica registrado. Os acessos e as alteracoes ficam '
                         || 'em log. Este texto e provisorio e sera substituido pela versao redigida pela Kawashi.' FROM dual) LOOP
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || v_login || '.TERMO WHERE DOCUMENTO = :d' INTO v_total USING d.doc;
            IF v_total = 0 THEN
                EXECUTE IMMEDIATE 'INSERT INTO ' || v_login || '.TERMO (DOCUMENTO, VERSAO, TEXTO, HASH_TEXTO, PUBLICADO_POR) VALUES (:d, ''1'', :t, RPAD(''0'', 64, ''0''), ''-'')'
                    USING d.doc, d.txt;
            END IF;
        END LOOP;

        -- So o schema de EXECUCAO da API: le os termos; o aceite, so insere e le.
        executar('GRANT SELECT ON ' || v_login || '.TERMO TO ' || v_app);
        executar('GRANT SELECT, INSERT ON ' || v_login || '.ACEITE_TERMO TO ' || v_app);
    END;
BEGIN
    -- O gatilho do termo calcula o SHA-256 do texto com o DBMS_CRYPTO.
    FOR a IN (SELECT 'TESTE_DEV' amb FROM dual UNION ALL SELECT 'TESTE_INFRA' FROM dual UNION ALL SELECT 'DEV' FROM dual
              UNION ALL SELECT 'INFRA' FROM dual UNION ALL SELECT 'HOMOLOG' FROM dual UNION ALL SELECT 'PROD' FROM dual) LOOP
        EXECUTE IMMEDIATE 'GRANT EXECUTE ON SYS.DBMS_CRYPTO TO KAWASHI_ENV_' || a.amb || '_LOGIN';
        criar_termos(a.amb);
    END LOOP;
    COMMIT;
END;
/
