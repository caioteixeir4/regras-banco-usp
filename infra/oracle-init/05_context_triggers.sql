-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 6 - TRIGGER DE SEGURANÇA CONTEXTUAL DE LOGON
-- #########################################################
CREATE OR REPLACE TRIGGER KAWASHI_CONTEXT_SECURITY_TRG
AFTER LOGON ON DATABASE
DECLARE
    V_IP            VARCHAR2(100);
    V_PROGRAM       VARCHAR2(200);
    V_OS_USER       VARCHAR2(100);
    V_HOUR          NUMBER;
    V_IP_ALLOWED    NUMBER;
    V_TOOL_BLOCKED  NUMBER;
    V_CURRENT_USER  VARCHAR2(100);
BEGIN
    V_CURRENT_USER := SYS_CONTEXT('USERENV', 'SESSION_USER');
    V_IP           := SYS_CONTEXT('USERENV', 'IP_ADDRESS');
    V_PROGRAM      := UPPER(SYS_CONTEXT('USERENV', 'CLIENT_PROGRAM_NAME'));
    V_OS_USER      := UPPER(SYS_CONTEXT('USERENV', 'OS_USER'));
    
    -- Normalização do fuso horário para Brasília (Evita disparidades com instâncias locais/Docker em UTC)
    V_HOUR         := TO_NUMBER(TO_CHAR(SYSTIMESTAMP AT TIME ZONE 'America/Sao_Paulo', 'HH24'));

    -- Monitoramento ativo e auditoria preventiva para credenciais administrativas master
    IF V_CURRENT_USER IN ('SYS', 'SYSTEM') THEN
        KAWASHI_WRITE_SECURITY_LOG(
            'PRIVILEGED_LOGIN', 
            'Acesso administrativo direto estabelecido na infraestrutura.'
        );
        RETURN;
    END IF;

    -- =====================================================
    -- REGRA 1 - VALIDAÇÃO DE IP COM TRATAMENTO FAIL-OPEN
    -- =====================================================
    IF V_IP IS NOT NULL THEN
        BEGIN
            SELECT COUNT(*)
            INTO V_IP_ALLOWED
            FROM KAWASHI_ALLOWED_IPS
            WHERE IP_ADDRESS = V_IP;
        EXCEPTION
            WHEN OTHERS THEN
                V_IP_ALLOWED := 1; -- Fail-Open controlado prioritário
                KAWASHI_WRITE_SECURITY_LOG(
                    'WHITELIST_ERROR_FAIL_OPEN',
                    'Alerta: Whitelist inacessivel. Fail-open temporario ativo. Erro: ' || SQLERRM
                );
        END;

        IF V_IP_ALLOWED = 0 THEN
            KAWASHI_WRITE_SECURITY_LOG(
                'UNKNOWN_IP_WARNING',
                'Aviso: IP nao cadastrado na whitelist: ' || V_IP
            );
            
            -- TODO PRODUÇÃO: Descomentar a linha abaixo após validar todos os IPs de produção na tabela
            -- RAISE_APPLICATION_ERROR(-20001, 'Access Denied: Unauthorized IP Location.');
        END IF;
    END IF;

    -- =====================================================
    -- REGRA 2 - JANELA DE HORÁRIO CORPORATIVO (BRT)
    -- =====================================================
    IF V_HOUR >= 22 OR V_HOUR < 6 THEN
        KAWASHI_WRITE_SECURITY_LOG(
            'BLOCKED_TIME',
            'Tentativa de acesso fora da janela de manutencao autorizada.'
        );
        RAISE_APPLICATION_ERROR(-20002, 'Access Denied: Maintenance window is closed.');
    END IF;

    -- =====================================================
    -- REGRA 3 - CONTA INSEGURA DE SISTEMA OPERACIONAL
    -- =====================================================
    IF V_OS_USER IN ('ROOT', 'ADMINISTRATOR', 'GUEST') THEN
        KAWASHI_WRITE_SECURITY_LOG(
            'BLOCKED_OS_USER',
            'Conta de OS vulneravel interceptada: ' || V_OS_USER
        );
        RAISE_APPLICATION_ERROR(-20003, 'Access Denied: Insecure OS account.');
    END IF;

    -- =====================================================
    -- REGRA 4 - BLACKLIST DINÂMICA DE APLICATIVOS COM FAIL-OPEN
    -- =====================================================
    BEGIN
        SELECT COUNT(*)
        INTO V_TOOL_BLOCKED
        FROM KAWASHI_FORBIDDEN_TOOLS
        WHERE V_PROGRAM LIKE TOOL_PATTERN;
    EXCEPTION
        WHEN OTHERS THEN
            V_TOOL_BLOCKED := 0; -- Fail-open: evita bloqueio massivo se a tabela sofrer travas
            KAWASHI_WRITE_SECURITY_LOG(
                'FORBIDDEN_TOOLS_ERROR',
                'Tabela de ferramentas indisponivel. Fail-open ativo. Erro: ' || SQLERRM
            );
    END;

    IF V_TOOL_BLOCKED > 0 THEN
        KAWASHI_WRITE_SECURITY_LOG(
            'BLOCKED_TOOL',
            'Ferramenta nao autorizada interceptada: ' || V_PROGRAM
        );
        RAISE_APPLICATION_ERROR(-20004, 'Access Denied: Unauthorized client tool.');
    END IF;

    KAWASHI_WRITE_SECURITY_LOG('SUCCESSFUL_LOGIN', 'Sessao estabelecida com sucesso.');
END;
/

-- #########################################################
-- PASSO 8 - TRIGGER DE MONITORAMENTO DE LOGOFF
-- #########################################################
CREATE OR REPLACE TRIGGER KAWASHI_LOGOFF_SECURITY_TRG
BEFORE LOGOFF ON DATABASE
BEGIN
    IF SYS_CONTEXT('USERENV', 'SESSION_USER') NOT IN ('SYS', 'SYSTEM') THEN
        KAWASHI_WRITE_SECURITY_LOG(
            'SESSION_END',
            'Sessao normal de usuario encerrada com sucesso.'
        );
    END IF;
END;
/


-- #########################################################
-- PASSO 9 - TRIGGER DE AUDITORIA DE ALTERAÇÕES DDL CRÍTICAS
-- #########################################################
CREATE OR REPLACE TRIGGER KAWASHI_DDL_AUDIT_TRG
AFTER DDL ON DATABASE
BEGIN
    IF SYS_CONTEXT('USERENV', 'SESSION_USER') NOT IN ('SYS', 'SYSTEM') THEN
        KAWASHI_WRITE_SECURITY_LOG(
            'DDL_MODIFICATION',
            'Evento: DDL_' || ORA_SYSEVENT || ' | Objeto: ' || ORA_DICT_OBJ_OWNER || '.' || ORA_DICT_OBJ_NAME || ' | Tipo: ' || ORA_DICT_OBJ_TYPE
        );
    END IF;
END;
/


-- #########################################################
-- PASSO 10 - TRIGGER DE AUDITORIA DE ESCALONAMENTO DE PRIVILÉGIOS
-- #########################################################
CREATE OR REPLACE TRIGGER KAWASHI_PRIVESC_AUDIT_TRG
AFTER GRANT ON DATABASE
BEGIN
    IF SYS_CONTEXT('USERENV', 'SESSION_USER') NOT IN ('SYS', 'SYSTEM') THEN
        KAWASHI_WRITE_SECURITY_LOG(
            'PRIVILEGE_GRANT_ALERT',
            'Concessao realizada por: ' || SYS_CONTEXT('USERENV', 'SESSION_USER') || ' | Beneficiado/Objeto: ' || ORA_DICT_OBJ_NAME
        );
    END IF;
END;
/

