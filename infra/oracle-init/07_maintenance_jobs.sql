-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 15 - AUTOMATIC DATA PURGE E CONTROLE DE CONTAS INATIVAS
-- #########################################################
-- Por que DBMS_SCHEDULER (dentro do banco) em vez de um cron do sistema
-- operacional? Um job do DBMS_SCHEDULER roda com o proprio Oracle, entao
-- funciona identico local, em outro container ou na nuvem, sem depender de
-- configurar nada no SO por fora - a "receita" da manutencao viaja junto com
-- o banco, no proprio dump/backup/replicacao dele.
--
-- job_action e passado como STRING (nao como bloco PL/SQL "normal") porque
-- DBMS_SCHEDULER.CREATE_JOB com job_type => 'PLSQL_BLOCK' espera o codigo a
-- ser executado como texto - o Oracle so vai compilar/rodar esse texto na
-- hora agendada, nao no momento em que este script roda. Por isso toda aspa
-- simples dentro do bloco esta duplicada ('') - e o jeito de "escapar" uma
-- aspa dentro de uma string SQL que ja esta entre aspas simples.
BEGIN
    DBMS_SCHEDULER.CREATE_JOB (
        job_name        => 'KAWASHI_DB_MAINTENANCE_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'DECLARE
                                v_rows NUMBER := 1;
                                v_app_user      VARCHAR2(30);
                                v_engineer_user VARCHAR2(30);
                            BEGIN
                                -- 1. Purge paginado da tabela de logs principal do SIEM
                                LOOP
                                    DELETE FROM KAWASHI_SECURITY_LOG
                                    WHERE EVENT_DATE < SYSTIMESTAMP - INTERVAL ''90'' DAY
                                    AND ROWNUM <= 10000;
                                    v_rows := SQL%ROWCOUNT;
                                    COMMIT;
                                    EXIT WHEN v_rows = 0;
                                END LOOP;

                                -- 2. Purge da tabela de contingencia fallback
                                DELETE FROM KAWASHI_SECURITY_LOG_FALLBACK
                                WHERE EVENT_DATE < SYSTIMESTAMP - INTERVAL ''90'' DAY;
                                COMMIT;

                                -- 3. Contas de servico/pessoais lidas do ambiente nunca devem ser
                                -- trancadas por inatividade (senao o proprio app ou o engenheiro
                                -- ficam fora do sistema sem ninguem ter feito nada de errado).
                                DBMS_SYSTEM.GET_ENV(''APP_USER'', v_app_user);
                                DBMS_SYSTEM.GET_ENV(''ENGINEER_USER'', v_engineer_user);

                                FOR r IN (
                                    SELECT username FROM dba_users
                                    WHERE last_login < SYSTIMESTAMP - INTERVAL ''90'' DAY
                                    AND account_status = ''OPEN''
                                    AND username NOT IN (''SYS'',''SYSTEM'',''DBSNMP'')
                                ) LOOP
                                    IF r.username NOT IN (NVL(v_app_user, ''#NONE#''), NVL(v_engineer_user, ''#NONE#'')) THEN
                                        EXECUTE IMMEDIATE ''ALTER USER '' || r.username || '' ACCOUNT LOCK'';
                                    END IF;
                                END LOOP;
                            END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=DAILY; BYHOUR=2; BYMINUTE=0', 
        enabled         => TRUE,
        comments        => 'Manutencao completa de dados e remocao automatica de contas abertas ociosas'
    );
END;
/


-- #########################################################
-- PASSO 16 - MANUTENÇÃO ISOLADA DE ÍNDICES (WEEKLY SCHEDULER)
-- #########################################################
-- Por que reconstruir (REBUILD) os indices periodicamente? A tabela de log
-- (KAWASHI_SECURITY_LOG) recebe INSERT o tempo todo e tambem sofre DELETE em
-- massa no job acima (purge de 90 dias) - com o tempo isso fragmenta os
-- indices (deixa "buracos" nas paginas), o que degrada a performance das
-- consultas que o SIEM faz por data/tipo/IP. REBUILD ONLINE reconstroi o
-- indice do zero sem bloquear leituras/escritas na tabela enquanto isso
-- acontece - importante porque este job roda enquanto o sistema continua
-- recebendo eventos de log normalmente.
BEGIN
    DBMS_SCHEDULER.CREATE_JOB (
        job_name        => 'KAWASHI_INDEX_REBUILD_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN
                                -- Executado isoladamente sem transacoes pendentes para mitigar falhas de dicionario
                                EXECUTE IMMEDIATE ''ALTER INDEX IDX_KAWASHI_LOG_DATE REBUILD ONLINE'';
                                EXECUTE IMMEDIATE ''ALTER INDEX IDX_KAWASHI_LOG_TYPE REBUILD ONLINE'';
                                EXECUTE IMMEDIATE ''ALTER INDEX IDX_KAWASHI_LOG_IP REBUILD ONLINE'';
                            END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=WEEKLY; BYDAY=SUN; BYHOUR=3; BYMINUTE=0', 
        enabled         => TRUE,
        comments        => 'Rebuild periodico focado em mitigar a fragmentacao dos indices do SIEM'
    );
END;
/