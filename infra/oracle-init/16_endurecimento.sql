-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 16 - ENDURECIMENTO (AJUSTES DA REVISAO DE SEGURANCA DE 23/11/2026)
-- #########################################################
-- Uma API comprometida so deve conseguir o que a API normal faz. A revisao achou permissoes e
-- caminhos a mais; este passo os fecha em bancos que ja existem (num banco novo, o 13 e o 14 ja
-- nascem assim):
--
--   1. USUARIO: a API so liga e desliga a conta (UPDATE so na coluna ATIVO). Trocar HANDLE ou
--      e-mail, nunca.
--   2. PERFIL: a API so cria e le. Nenhum UPDATE.
--   3. TOKEN: revogado e para sempre (REVOGADO_EM e MOTIVO nao voltam nem mudam), o teto absoluto
--      nao aumenta, e dono, empresa, escopo e hash do token nao mudam. ORA-20112.
--
-- Idempotente.

DECLARE
    PROCEDURE executar(p_sql VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
    END;

    PROCEDURE revogar(p_sql VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE NOT IN (-1927, -1952) THEN  -- "nao foi concedido": ja esta como deve
                RAISE;
            END IF;
    END;

    PROCEDURE endurecer(p_ambiente VARCHAR2) IS
        v_env    VARCHAR2(60) := 'KAWASHI_ENV_' || p_ambiente;
        v_login  VARCHAR2(60) := v_env || '_LOGIN';
        v_sessao VARCHAR2(60) := v_env || '_SESSAO';
        v_app    VARCHAR2(60) := v_env || '_APP';
    BEGIN
        revogar('REVOKE UPDATE ON ' || v_login || '.USUARIO FROM ' || v_app);
        executar('GRANT UPDATE (ATIVO) ON ' || v_login || '.USUARIO TO ' || v_app);
        revogar('REVOKE UPDATE ON ' || v_login || '.PERFIL FROM ' || v_app);

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
            END;');
    END;
BEGIN
    FOR a IN (SELECT 'TESTE_DEV' amb FROM dual UNION ALL SELECT 'TESTE_INFRA' FROM dual UNION ALL SELECT 'DEV' FROM dual
              UNION ALL SELECT 'INFRA' FROM dual UNION ALL SELECT 'HOMOLOG' FROM dual UNION ALL SELECT 'PROD' FROM dual) LOOP
        endurecer(a.amb);
    END LOOP;
END;
/
