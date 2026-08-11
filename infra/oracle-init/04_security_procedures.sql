-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 5 - PROCEDURE AUTÔNOMA À PROVA DE FALHAS (ANTI-SPOF)
-- #########################################################
CREATE OR REPLACE PROCEDURE KAWASHI_WRITE_SECURITY_LOG (
    P_EVENT_TYPE   VARCHAR2,
    P_DETAILS      VARCHAR2
)
AS
    PRAGMA AUTONOMOUS_TRANSACTION;
    V_ERRM         VARCHAR2(4000); -- Variável para higienizar a captura do erro
BEGIN
    INSERT INTO KAWASHI_SECURITY_LOG (
        DB_USER, OS_USER, IP_ADDRESS, CLIENT_PROGRAM, EVENT_TYPE, DETAILS
    )
    VALUES (
        SYS_CONTEXT('USERENV', 'SESSION_USER'),
        SYS_CONTEXT('USERENV', 'OS_USER'),
        SYS_CONTEXT('USERENV', 'IP_ADDRESS'),
        SYS_CONTEXT('USERENV', 'CLIENT_PROGRAM'),
        P_EVENT_TYPE,
        P_DETAILS
    );
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        BEGIN
            -- Captura o erro na variável local antes de realizar o insert de contingência
            V_ERRM := SUBSTR(SQLERRM, 1, 3800);
            
            INSERT INTO KAWASHI_SECURITY_LOG_FALLBACK (ERROR_MSG)
            VALUES ('FALHA CRITICA NO LOG PRINCIPAL: ' || V_ERRM || ' | EVENTO: ' || P_EVENT_TYPE);
            COMMIT;
        EXCEPTION
            WHEN OTHERS THEN
                NULL; -- Salvaguarda final: garantia de disponibilidade do logon
        END;
END;
/