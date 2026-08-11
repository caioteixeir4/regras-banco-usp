-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 1 - FUNÇÃO CUSTOMIZADA DE VERIFICAÇÃO DE SENHA (NIST COMPLIANT)
-- #########################################################
CREATE OR REPLACE FUNCTION KAWASHI_PASSWORD_VERIFY(
    p_username     IN VARCHAR2,
    p_password     IN VARCHAR2,
    p_old_password IN VARCHAR2
) RETURN BOOLEAN AS
BEGIN
    IF LENGTH(p_password) < 12 THEN
        RAISE_APPLICATION_ERROR(-20001, 'A senha deve conter no minimo 12 caracteres.');
    END IF;

    IF INSTR(UPPER(p_password), UPPER(p_username)) > 0 THEN
        RAISE_APPLICATION_ERROR(-20002, 'A senha nao pode conter o nome do usuario.');
    END IF;

    IF NOT REGEXP_LIKE(p_password, '[A-Z]') OR       
       NOT REGEXP_LIKE(p_password, '[a-z]') OR       
       NOT REGEXP_LIKE(p_password, '[0-9]') OR       
       NOT REGEXP_LIKE(p_password, '[^A-Za-z0-9]') THEN
        RAISE_APPLICATION_ERROR(-20003, 'A senha deve conter maiuscula, minuscula, numero e caractere especial.');
    END IF;

    RETURN TRUE;
END;
/

-- #########################################################
-- PASSO 2 - PERFIL DE SEGURANÇA OPERACIONAL AJUSTADO
-- #########################################################
CREATE PROFILE KAWASHI_SECURE_PROFILE LIMIT
    FAILED_LOGIN_ATTEMPTS      5          
    PASSWORD_LOCK_TIME         1/24       
    PASSWORD_LIFE_TIME         90         
    PASSWORD_GRACE_TIME        7          
    PASSWORD_REUSE_TIME        365        
    PASSWORD_REUSE_MAX         10         
    SESSIONS_PER_USER          3          
    IDLE_TIME                  30         
    CONNECT_TIME               720        
    PASSWORD_VERIFY_FUNCTION   KAWASHI_PASSWORD_VERIFY;

-- #########################################################
-- PASSO 11 - TRILHA DE AUDITORIA UNIFICADA (ORACLE 23ai COMPLIANT)
-- #########################################################
-- Criacao da politica moderna de Unified Auditing suportada em PDBs
CREATE AUDIT POLICY KAWASHI_UNIFIED_AUDIT_POLICY
  ACTIONS CREATE USER, ALTER USER, DROP USER, GRANT, REVOKE, LOGON, LOGOFF;

-- Ativacao imediata da politica de monitoramento do SIEM
AUDIT POLICY KAWASHI_UNIFIED_AUDIT_POLICY;