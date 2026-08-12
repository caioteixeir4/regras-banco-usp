-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 5 - PROCEDURE AUTÔNOMA À PROVA DE FALHAS (ANTI-SPOF)
-- #########################################################
-- Por que PRAGMA AUTONOMOUS_TRANSACTION? Esta procedure e chamada de dentro
-- de triggers (arquivo 05) que rodam no meio da transacao de OUTRA pessoa -
-- por exemplo, no exato momento em que alguem esta fazendo logon, ou no meio
-- de um DDL. Sem essa pragma, o COMMIT abaixo commitaria (ou um ROLLBACK do
-- chamador desfaria) a transacao inteira de quem disparou o trigger - o que
-- seria um efeito colateral perigoso (imagine um DDL de outra pessoa sendo
-- commitado sem querer so porque o log de auditoria deu commit).
-- AUTONOMOUS_TRANSACTION faz este bloco rodar como uma transacao 100%
-- independente: o log e gravado (ou falha) sem nenhuma interferencia na
-- transacao de quem chamou, e vice-versa.
--
-- Por que o EXCEPTION WHEN OTHERS aninhado (2 niveis)? Esta e a peca central
-- do design "fail-open para o proprio mecanismo de auditoria": um problema no
-- LOG nunca pode impedir alguem de logar ou de trabalhar no banco. O primeiro
-- nivel tenta gravar no log principal; se falhar, tenta gravar o motivo da
-- falha na tabela de fallback (mais simples, com menos motivo pra tambem
-- falhar); o segundo nivel garante que, mesmo se o FALLBACK falhar, o erro e
-- silenciado (NULL) em vez de subir e travar quem chamou. E uma escolha
-- deliberada de disponibilidade > completude do log.
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