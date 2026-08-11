-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 15 - AUTOMATIC DATA PURGE E CONTROLE DE CONTAS INATIVAS
-- #########################################################
BEGIN
    DBMS_SCHEDULER.CREATE_JOB (
        job_name        => 'KAWASHI_DB_MAINTENANCE_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'DECLARE 
                                v_rows NUMBER := 1; 
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

                                -- 3. CORREÇÃO CLAUDE: Controle e exclusão de aspas triplas no array de ignorados
                                FOR r IN (
                                    SELECT username FROM dba_users 
                                    WHERE last_login < SYSTIMESTAMP - INTERVAL ''90'' DAY
                                    AND account_status = ''OPEN''
                                    AND username NOT IN (''SYS'',''SYSTEM'',''DBSNMP'')
                                ) LOOP
                                    EXECUTE IMMEDIATE ''ALTER USER '' || r.username || '' ACCOUNT LOCK'';
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