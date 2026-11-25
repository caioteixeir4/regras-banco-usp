-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 17 - CONVITE POR E-MAIL, CONFIRMACAO COM PASSKEY E BLOQUEIO POR BLOCO IPv6
-- #########################################################
-- Achados 1, 4, 5, 8 e 11 da revisao de seguranca de 23/11/2026:
--
--   CONVITE.ENVIADO_POR_EMAIL   o segredo do convite foi para o e-mail da propria pessoa (e nao
--                               voltou para quem pediu). Nao muda depois de criado (ORA-20113).
--   USUARIO.EMAIL_CONFIRMADO_EM quando o e-mail foi confirmado: usar um convite que chegou POR
--                               E-MAIL prova que a caixa e da pessoa. Quem grava e o gatilho do
--                               CONVITE, nunca a API (ela so pode mudar ATIVO no USUARIO).
--   TOKEN.VERIFICADO_EM         ultima vez que a pessoa usou a passkey nesta sessao (login ou
--                               confirmacao). Operacao sensivel exige que seja recente
--                               (CONFIRMACAO_MINUTOS). Nao vai para o futuro nem volta (ORA-20112).
--   DESAFIO 'CONFIRMACAO'       o desafio da confirmacao, preso ao usuario.
--   TENTATIVA_LOGIN.IP_GRUPO    o IP agrupado (IPv4 inteiro; IPv6 pelo bloco /64): as falhas sao
--                               contadas por grupo, e quem tem um bloco IPv6 nao escapa trocando de
--                               endereco. O IP_ORIGEM continua com o endereco exato.
--
-- Os eventos novos do LOG_SEGURANCA (PASSKEY_CONFIRMADA, EMAIL_ENVIADO) ficam na lista unica do
-- 14_autorizacao.sql. Idempotente.

DECLARE
    PROCEDURE executar(p_sql VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
    END;

    FUNCTION existe_coluna(p_dono VARCHAR2, p_tabela VARCHAR2, p_coluna VARCHAR2) RETURN BOOLEAN IS
        v_total NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_total FROM dba_tab_columns WHERE owner = p_dono AND table_name = p_tabela AND column_name = p_coluna;
        RETURN v_total > 0;
    END;

    PROCEDURE trocar_check(p_dono VARCHAR2, p_tabela VARCHAR2, p_nome VARCHAR2, p_regra VARCHAR2) IS
        v_total NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_total FROM dba_constraints WHERE owner = p_dono AND constraint_name = p_nome;
        IF v_total > 0 THEN
            executar('ALTER TABLE ' || p_dono || '.' || p_tabela || ' DROP CONSTRAINT ' || p_nome);
        END IF;
        executar('ALTER TABLE ' || p_dono || '.' || p_tabela || ' ADD CONSTRAINT ' || p_nome || ' CHECK (' || p_regra || ')');
    END;

    PROCEDURE aplicar(p_ambiente VARCHAR2) IS
        v_env    VARCHAR2(60) := 'KAWASHI_ENV_' || p_ambiente;
        v_login  VARCHAR2(60) := v_env || '_LOGIN';
        v_sessao VARCHAR2(60) := v_env || '_SESSAO';
        v_log    VARCHAR2(60) := v_env || '_LOG';
        v_agora  VARCHAR2(40) := 'SYS_EXTRACT_UTC(SYSTIMESTAMP)';
        v_total  NUMBER;
    BEGIN
        -- ---------------- e-mail ----------------
        IF NOT existe_coluna(v_login, 'USUARIO', 'EMAIL_CONFIRMADO_EM') THEN
            executar('ALTER TABLE ' || v_login || '.USUARIO ADD (EMAIL_CONFIRMADO_EM TIMESTAMP(6))');
        END IF;
        IF NOT existe_coluna(v_login, 'CONVITE', 'ENVIADO_POR_EMAIL') THEN
            executar('ALTER TABLE ' || v_login || '.CONVITE ADD (ENVIADO_POR_EMAIL BOOLEAN DEFAULT FALSE NOT NULL)');
        END IF;
        executar('CREATE OR REPLACE TRIGGER ' || v_login || '.CONVITE_ENVIO_TRG
            BEFORE UPDATE ON ' || v_login || '.CONVITE
            FOR EACH ROW
            BEGIN
                IF :NEW.ENVIADO_POR_EMAIL <> :OLD.ENVIADO_POR_EMAIL THEN
                    RAISE_APPLICATION_ERROR(-20113, ''Como o convite foi entregue nao muda depois de criado.'');
                END IF;
            END;');
        -- Usou um convite que chegou por e-mail: a caixa e da pessoa.
        executar('CREATE OR REPLACE TRIGGER ' || v_login || '.CONVITE_CONFIRMA_EMAIL_TRG
            AFTER UPDATE OF USADO_EM ON ' || v_login || '.CONVITE
            FOR EACH ROW
            WHEN (OLD.USADO_EM IS NULL AND NEW.USADO_EM IS NOT NULL AND NEW.ENVIADO_POR_EMAIL)
            BEGIN
                UPDATE ' || v_login || '.USUARIO SET EMAIL_CONFIRMADO_EM = ' || v_agora || '
                 WHERE ID = :NEW.USUARIO_ID AND EMAIL_CONFIRMADO_EM IS NULL;
            END;');

        -- ---------------- confirmacao com passkey ----------------
        IF NOT existe_coluna(v_sessao, 'TOKEN', 'VERIFICADO_EM') THEN
            executar('ALTER TABLE ' || v_sessao || '.TOKEN ADD (VERIFICADO_EM TIMESTAMP(6))');
        END IF;
        executar('CREATE OR REPLACE TRIGGER ' || v_sessao || '.TOKEN_IMUTAVEL_TRG
            BEFORE UPDATE ON ' || v_sessao || '.TOKEN
            FOR EACH ROW
            BEGIN
                IF :OLD.REVOGADO_EM IS NOT NULL
                   AND (:NEW.REVOGADO_EM IS NULL OR :NEW.REVOGADO_EM <> :OLD.REVOGADO_EM
                        OR NVL(:NEW.MOTIVO_REVOGACAO, ''-'') <> :OLD.MOTIVO_REVOGACAO) THEN
                    RAISE_APPLICATION_ERROR(-20112, ''Token revogado nao volta a valer.'');
                END IF;
                IF :NEW.EXPIRA_ABSOLUTO_EM > :OLD.EXPIRA_ABSOLUTO_EM THEN
                    RAISE_APPLICATION_ERROR(-20112, ''O teto do token nao aumenta.'');
                END IF;
                IF :NEW.USUARIO_ID <> :OLD.USUARIO_ID OR :NEW.TOKEN_HASH <> :OLD.TOKEN_HASH OR :NEW.ESCOPO <> :OLD.ESCOPO
                   OR NVL(:NEW.EMPRESA_ID, -1) <> NVL(:OLD.EMPRESA_ID, -1) OR NVL(:NEW.PASSKEY_ID, -1) <> NVL(:OLD.PASSKEY_ID, -1) THEN
                    RAISE_APPLICATION_ERROR(-20112, ''Dono, empresa, escopo e hash do token nao mudam: emita outro.'');
                END IF;
                IF (:OLD.VERIFICADO_EM IS NOT NULL AND (:NEW.VERIFICADO_EM IS NULL OR :NEW.VERIFICADO_EM < :OLD.VERIFICADO_EM))
                   OR :NEW.VERIFICADO_EM > ' || v_agora || ' + INTERVAL ''1'' SECOND THEN
                    RAISE_APPLICATION_ERROR(-20112, ''A ultima confirmacao com a passkey nao volta nem vai para o futuro.'');
                END IF;
            END;');
        trocar_check(v_sessao, 'DESAFIO', 'CK_DESAFIO_FINALIDADE', q'[FINALIDADE IN ('LOGIN', 'CADASTRO', 'CONFIRMACAO')]');
        -- Confirmacao que falha conta como tentativa do IP, como um login com falha.
        trocar_check(v_log, 'TENTATIVA_LOGIN', 'CK_TENTATIVA_METODO', q'[METODO IN ('PASSKEY', 'CODIGO_RECUPERACAO', 'CONVITE', 'CONFIRMACAO')]');
        EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || v_login || '.PARAMETRO_SEGURANCA WHERE CHAVE = ''CONFIRMACAO_MINUTOS''' INTO v_total;
        IF v_total = 0 THEN
            executar('INSERT INTO ' || v_login || '.PARAMETRO_SEGURANCA (CHAVE, VALOR, DESCRICAO, ATUALIZADO_POR) VALUES '
                || '(''CONFIRMACAO_MINUTOS'', 5, ''Minutos em que a ultima passkey usada vale para operacao sensivel; depois, a pessoa confirma de novo.'', ''INSTALACAO'')');
        END IF;

        -- ---------------- IPv6 por bloco ----------------
        IF NOT existe_coluna(v_log, 'TENTATIVA_LOGIN', 'IP_GRUPO') THEN
            executar('ALTER TABLE ' || v_log || '.TENTATIVA_LOGIN ADD (IP_GRUPO VARCHAR2(45))');
            executar('CREATE INDEX ' || v_log || '.IX_TENTATIVA_IP_GRUPO ON ' || v_log || '.TENTATIVA_LOGIN (IP_GRUPO, DATA_HORA)');
        END IF;
    END;
BEGIN
    FOR a IN (SELECT 'TESTE_DEV' amb FROM dual UNION ALL SELECT 'TESTE_INFRA' FROM dual UNION ALL SELECT 'DEV' FROM dual
              UNION ALL SELECT 'INFRA' FROM dual UNION ALL SELECT 'HOMOLOG' FROM dual UNION ALL SELECT 'PROD' FROM dual) LOOP
        aplicar(a.amb);
    END LOOP;
    COMMIT;
    -- A coluna nova no USUARIO invalida a view do painel de usuarios (V_USUARIO_ACESSOS): recompila.
    FOR v IN (SELECT owner, object_name FROM dba_objects
               WHERE owner LIKE 'KAWASHI\_ENV\_%' ESCAPE '\' AND object_type = 'VIEW' AND status <> 'VALID') LOOP
        EXECUTE IMMEDIATE 'ALTER VIEW ' || v.owner || '.' || v.object_name || ' COMPILE';
    END LOOP;
END;
/
