-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 18 - CONVITE DE VINCULO (DAR ACESSO A QUEM JA TEM CONTA EM OUTRA EMPRESA)
-- #########################################################
-- O administrador de uma empresa convida uma pessoa que JA tem conta (em outra empresa) para trabalhar
-- tambem na dele. Nada muda ate a PROPRIA pessoa aceitar, entrando com a passkey dela.
--
-- CONVITE_VINCULO (no _LOGIN) guarda, de forma que nao da para mudar depois:
--   quem convidou (CONVIDADO_POR, e o id do usuario), quando (hora do banco), de qual IP, para qual
--   empresa e com qual cargo; e a resposta: aceito, recusado ou cancelado, por quem, quando e de qual IP.
-- Cada convite e cada resposta vao SOZINHOS para o LOG_PERMISSAO (a historia de cargos da empresa) e
-- para o LOG_SEGURANCA (com o IP), os dois encadeados por hash. O vinculo criado no aceite aponta para o
-- convite (USUARIO_EMPRESA.CONVITE_VINCULO_ID): de qualquer acesso da para chegar em quem convidou.
--
-- Regras do banco (ORA-20114):
--   - quem convidou, empresa, cargo, IP, hora e validade nao mudam depois de criados;
--   - a situacao so sai de PENDENTE, uma vez;
--   - aceitar ou recusar, so o proprio convidado (RESPONDIDO_POR = USUARIO:<o convidado>);
--   - um convite pendente por pessoa e empresa; validade de no maximo 30 dias.
-- A API so le, cria e responde (UPDATE so nas colunas da resposta); ninguem apaga.
--
-- Idempotente.

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

    FUNCTION existe_coluna(p_dono VARCHAR2, p_tabela VARCHAR2, p_coluna VARCHAR2) RETURN BOOLEAN IS
        v_total NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_total FROM dba_tab_columns WHERE owner = p_dono AND table_name = p_tabela AND column_name = p_coluna;
        RETURN v_total > 0;
    END;

    PROCEDURE aplicar(p_ambiente VARCHAR2) IS
        v_env   VARCHAR2(60) := 'KAWASHI_ENV_' || p_ambiente;
        v_login VARCHAR2(60) := v_env || '_LOGIN';
        v_log   VARCHAR2(60) := v_env || '_LOG';
        v_app   VARCHAR2(60) := v_env || '_APP';
        v_agora VARCHAR2(40) := 'SYS_EXTRACT_UTC(SYSTIMESTAMP)';
    BEGIN
        IF NOT existe_tabela(v_login, 'CONVITE_VINCULO') THEN
            executar('CREATE TABLE ' || v_login || '.CONVITE_VINCULO (
                ID                        NUMBER GENERATED ALWAYS AS IDENTITY,
                USUARIO_ID                NUMBER          NOT NULL,
                EMPRESA_ID                NUMBER          NOT NULL,
                PERFIL_ID                 NUMBER          NOT NULL,
                CONVIDADO_POR             VARCHAR2(128)   NOT NULL,
                CONVIDADO_POR_USUARIO_ID  NUMBER,
                IP_ORIGEM                 VARCHAR2(45),
                CRIADO_EM                 TIMESTAMP(6)    DEFAULT ' || v_agora || ' NOT NULL,
                EXPIRA_EM                 TIMESTAMP(6)    NOT NULL,
                SITUACAO                  VARCHAR2(12)    DEFAULT ''PENDENTE'' NOT NULL,
                RESPONDIDO_POR            VARCHAR2(128),
                RESPONDIDO_EM             TIMESTAMP(6),
                IP_RESPOSTA               VARCHAR2(45),
                CONSTRAINT PK_CONVITE_VINCULO PRIMARY KEY (ID),
                CONSTRAINT FK_CONVITE_VINCULO_USUARIO FOREIGN KEY (USUARIO_ID) REFERENCES ' || v_login || '.USUARIO (ID),
                CONSTRAINT FK_CONVITE_VINCULO_CONVIDOU FOREIGN KEY (CONVIDADO_POR_USUARIO_ID) REFERENCES ' || v_login || '.USUARIO (ID),
                CONSTRAINT FK_CONVITE_VINCULO_PERFIL FOREIGN KEY (PERFIL_ID, EMPRESA_ID) REFERENCES ' || v_login || '.PERFIL (ID, EMPRESA_ID),
                CONSTRAINT CK_CONVITE_VINCULO_SITUACAO CHECK (SITUACAO IN (''PENDENTE'', ''ACEITO'', ''RECUSADO'', ''CANCELADO'')),
                CONSTRAINT CK_CONVITE_VINCULO_RESPOSTA CHECK ((SITUACAO = ''PENDENTE'' AND RESPONDIDO_EM IS NULL AND RESPONDIDO_POR IS NULL)
                    OR (SITUACAO <> ''PENDENTE'' AND RESPONDIDO_EM IS NOT NULL AND RESPONDIDO_POR IS NOT NULL)),
                CONSTRAINT CK_CONVITE_VINCULO_VALIDADE CHECK (EXPIRA_EM > CRIADO_EM AND EXPIRA_EM <= CRIADO_EM + INTERVAL ''30'' DAY))');
            executar('CREATE INDEX ' || v_login || '.IX_CONVITE_VINCULO_USUARIO ON ' || v_login || '.CONVITE_VINCULO (USUARIO_ID, SITUACAO)');
            executar('CREATE INDEX ' || v_login || '.IX_CONVITE_VINCULO_EMPRESA ON ' || v_login || '.CONVITE_VINCULO (EMPRESA_ID, SITUACAO)');
            -- Um convite pendente por pessoa e empresa.
            executar('CREATE UNIQUE INDEX ' || v_login || '.UX_CONVITE_VINCULO_PENDENTE ON ' || v_login || '.CONVITE_VINCULO
                (CASE WHEN SITUACAO = ''PENDENTE'' THEN USUARIO_ID END, CASE WHEN SITUACAO = ''PENDENTE'' THEN EMPRESA_ID END)');
        END IF;

        -- O vinculo aponta para o convite que o criou: de qualquer acesso se chega em quem convidou.
        IF NOT existe_coluna(v_login, 'USUARIO_EMPRESA', 'CONVITE_VINCULO_ID') THEN
            executar('ALTER TABLE ' || v_login || '.USUARIO_EMPRESA ADD (CONVITE_VINCULO_ID NUMBER)');
            executar('ALTER TABLE ' || v_login || '.USUARIO_EMPRESA ADD CONSTRAINT FK_USUARIO_EMPRESA_CONVITE
                FOREIGN KEY (CONVITE_VINCULO_ID) REFERENCES ' || v_login || '.CONVITE_VINCULO (ID)');
        END IF;

        -- Quem convidou, quando e de onde nao mudam; a resposta e uma so, e aceitar ou recusar e do convidado.
        executar('CREATE OR REPLACE TRIGGER ' || v_login || '.CONVITE_VINCULO_TRG
            BEFORE INSERT OR UPDATE OR DELETE ON ' || v_login || '.CONVITE_VINCULO
            FOR EACH ROW
            BEGIN
                IF DELETING THEN
                    RAISE_APPLICATION_ERROR(-20114, ''Convite de vinculo nao se apaga: cancele.'');
                END IF;
                IF INSERTING THEN
                    :NEW.CRIADO_EM := ' || v_agora || ';
                    :NEW.SITUACAO := ''PENDENTE'';
                    :NEW.RESPONDIDO_POR := NULL;
                    :NEW.RESPONDIDO_EM := NULL;
                    :NEW.IP_RESPOSTA := NULL;
                    IF SYS_CONTEXT(''USERENV'', ''SESSION_USER'') = ''' || v_app || ''' THEN
                        IF NOT REGEXP_LIKE(:NEW.CONVIDADO_POR, ''^USUARIO:[0-9]+$'')
                           OR :NEW.CONVIDADO_POR <> ''USUARIO:'' || :NEW.CONVIDADO_POR_USUARIO_ID THEN
                            RAISE_APPLICATION_ERROR(-20114, ''Informe quem convidou (CONVIDADO_POR = USUARIO:<id>, igual a CONVIDADO_POR_USUARIO_ID).'');
                        END IF;
                    ELSE
                        :NEW.CONVIDADO_POR := NVL(SYS_CONTEXT(''USERENV'', ''PROXY_USER''), SYS_CONTEXT(''USERENV'', ''SESSION_USER''));
                        :NEW.CONVIDADO_POR_USUARIO_ID := NULL;
                    END IF;
                    IF :NEW.CONVIDADO_POR_USUARIO_ID = :NEW.USUARIO_ID THEN
                        RAISE_APPLICATION_ERROR(-20114, ''Ninguem convida a si mesmo.'');
                    END IF;
                    RETURN;
                END IF;
                -- UPDATE
                IF :NEW.USUARIO_ID <> :OLD.USUARIO_ID OR :NEW.EMPRESA_ID <> :OLD.EMPRESA_ID OR :NEW.PERFIL_ID <> :OLD.PERFIL_ID
                   OR :NEW.CONVIDADO_POR <> :OLD.CONVIDADO_POR OR NVL(:NEW.CONVIDADO_POR_USUARIO_ID, -1) <> NVL(:OLD.CONVIDADO_POR_USUARIO_ID, -1)
                   OR NVL(:NEW.IP_ORIGEM, ''-'') <> NVL(:OLD.IP_ORIGEM, ''-'') OR :NEW.CRIADO_EM <> :OLD.CRIADO_EM
                   OR :NEW.EXPIRA_EM <> :OLD.EXPIRA_EM THEN
                    RAISE_APPLICATION_ERROR(-20114, ''Quem convidou, empresa, cargo, IP, hora e validade do convite nao mudam.'');
                END IF;
                IF :OLD.SITUACAO <> ''PENDENTE'' OR :NEW.SITUACAO = ''PENDENTE'' THEN
                    RAISE_APPLICATION_ERROR(-20114, ''O convite ja foi respondido (ou a resposta nao e valida): a resposta e uma so.'');
                END IF;
                IF :NEW.SITUACAO IN (''ACEITO'', ''RECUSADO'') THEN
                    IF :OLD.EXPIRA_EM <= ' || v_agora || ' THEN
                        RAISE_APPLICATION_ERROR(-20114, ''O convite venceu.'');
                    END IF;
                    IF SYS_CONTEXT(''USERENV'', ''SESSION_USER'') = ''' || v_app || '''
                       AND NVL(:NEW.RESPONDIDO_POR, ''-'') <> ''USUARIO:'' || :OLD.USUARIO_ID THEN
                        RAISE_APPLICATION_ERROR(-20114, ''So o proprio convidado aceita ou recusa.'');
                    END IF;
                END IF;
                IF SYS_CONTEXT(''USERENV'', ''SESSION_USER'') = ''' || v_app || ''' THEN
                    IF NOT REGEXP_LIKE(NVL(:NEW.RESPONDIDO_POR, ''-''), ''^(USUARIO:[0-9]+|SCRIPT:[A-Z_]+)$'') THEN
                        RAISE_APPLICATION_ERROR(-20114, ''Informe quem respondeu (RESPONDIDO_POR = USUARIO:<id>).'');
                    END IF;
                ELSE
                    :NEW.RESPONDIDO_POR := NVL(SYS_CONTEXT(''USERENV'', ''PROXY_USER''), SYS_CONTEXT(''USERENV'', ''SESSION_USER''));
                END IF;
                :NEW.RESPONDIDO_EM := ' || v_agora || ';
            END;');

        -- Cada convite e cada resposta vao sozinhos para os dois logs encadeados.
        executar('CREATE OR REPLACE TRIGGER ' || v_login || '.CONVITE_VINCULO_LOG_TRG
            AFTER INSERT OR UPDATE OF SITUACAO ON ' || v_login || '.CONVITE_VINCULO
            FOR EACH ROW
            DECLARE
                v_perfil VARCHAR2(50 CHAR);
                v_evento VARCHAR2(30);
            BEGIN
                SELECT NOME INTO v_perfil FROM ' || v_login || '.PERFIL WHERE ID = :NEW.PERFIL_ID;
                IF INSERTING THEN
                    INSERT INTO ' || v_log || '.LOG_PERMISSAO (ORDEM, EVENTO, EMPRESA_ID, USUARIO_ID, PERFIL_NOVO, FEITO_POR, HASH)
                    VALUES (0, ''VINCULO_CONVIDADO'', :NEW.EMPRESA_ID, :NEW.USUARIO_ID, v_perfil, :NEW.CONVIDADO_POR, ''-'');
                    INSERT INTO ' || v_log || '.LOG_SEGURANCA (ORDEM, EVENTO, USUARIO_ID, DETALHE, IP_ORIGEM, FEITO_POR, HASH)
                    VALUES (0, ''VINCULO_CONVIDADO'', :NEW.USUARIO_ID, ''convite '' || :NEW.ID || '': empresa '' || :NEW.EMPRESA_ID
                            || '', cargo '' || v_perfil, :NEW.IP_ORIGEM, :NEW.CONVIDADO_POR, ''-'');
                ELSE
                    v_evento := CASE :NEW.SITUACAO WHEN ''ACEITO'' THEN ''CONVITE_ACEITO'' WHEN ''RECUSADO'' THEN ''CONVITE_RECUSADO''
                                ELSE ''CONVITE_CANCELADO'' END;
                    INSERT INTO ' || v_log || '.LOG_PERMISSAO (ORDEM, EVENTO, EMPRESA_ID, USUARIO_ID, PERFIL_NOVO, FEITO_POR, HASH)
                    VALUES (0, v_evento, :NEW.EMPRESA_ID, :NEW.USUARIO_ID, v_perfil, :NEW.RESPONDIDO_POR, ''-'');
                    INSERT INTO ' || v_log || '.LOG_SEGURANCA (ORDEM, EVENTO, USUARIO_ID, DETALHE, IP_ORIGEM, FEITO_POR, HASH)
                    VALUES (0, ''VINCULO_CONVITE_RESPONDIDO'', :NEW.USUARIO_ID, ''convite '' || :NEW.ID || '' '' || :NEW.SITUACAO
                            || '' (convidado por '' || :NEW.CONVIDADO_POR || '')'', :NEW.IP_RESPOSTA, :NEW.RESPONDIDO_POR, ''-'');
                END IF;
            END;');

        -- A API le, cria e responde. Nada de apagar, nada de mudar quem convidou.
        executar('GRANT SELECT, INSERT ON ' || v_login || '.CONVITE_VINCULO TO ' || v_app);
        executar('GRANT UPDATE (SITUACAO, RESPONDIDO_POR, IP_RESPOSTA) ON ' || v_login || '.CONVITE_VINCULO TO ' || v_app);
    END;
BEGIN
    FOR a IN (SELECT 'TESTE_DEV' amb FROM dual UNION ALL SELECT 'TESTE_INFRA' FROM dual UNION ALL SELECT 'DEV' FROM dual
              UNION ALL SELECT 'INFRA' FROM dual UNION ALL SELECT 'HOMOLOG' FROM dual UNION ALL SELECT 'PROD' FROM dual) LOOP
        aplicar(a.amb);
    END LOOP;
    COMMIT;
    FOR v IN (SELECT owner, object_name FROM dba_objects
               WHERE owner LIKE 'KAWASHI\_ENV\_%' ESCAPE '\' AND object_type IN ('VIEW', 'TRIGGER') AND status <> 'VALID') LOOP
        -- A coluna nova no USUARIO_EMPRESA invalida os gatilhos e a view dele: recompila.
        EXECUTE IMMEDIATE 'ALTER ' || CASE WHEN v.object_name LIKE '%\_TRG' ESCAPE '\' THEN 'TRIGGER ' ELSE 'VIEW ' END
            || v.owner || '.' || v.object_name || ' COMPILE';
    END LOOP;
END;
/
