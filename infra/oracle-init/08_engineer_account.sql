-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 17 - CONTA PESSOAL DO ENGENHEIRO DE PROJETO
-- #########################################################
-- Conta humana, nao de aplicacao: usada pelo engenheiro do projeto para administrar
-- o banco no dia a dia. Diferente de SYS/SYSTEM (master da engine), esta conta e
-- nomeada e atribuivel - passa pelos mesmos triggers de auditoria/contexto do
-- oracle-init/05_context_triggers.sql, que isentam apenas SYS/SYSTEM.
--
-- Username e senha vem do .env (ENGINEER_USER / ENGINEER_USER_PASSWORD) - nao ficam
-- hardcoded aqui. Para adicionar outro engenheiro, crie um novo par de variaveis e
-- repita este bloco com o novo usuario; nao compartilhe esta conta entre pessoas.
--
-- TODO (debito tecnico intencional): GRANT DBA e privilegio total, aceito por decisao do
-- engenheiro do projeto (Caio) enquanto ele programa sozinho e precisa de liberdade total
-- para criar/ajustar qualquer objeto sem fricção. Quando houver mais de uma pessoa
-- operando o banco, revisar e reduzir para um conjunto explicito de privilegios
-- (ex: ROLE_KAWASHI_INFRA + grants pontuais) em vez de DBA.
DECLARE
    V_ENGINEER_USER VARCHAR2(30);
    V_ENGINEER_PASS VARCHAR2(100);
BEGIN
    DBMS_SYSTEM.GET_ENV('ENGINEER_USER', V_ENGINEER_USER);
    DBMS_SYSTEM.GET_ENV('ENGINEER_USER_PASSWORD', V_ENGINEER_PASS);

    IF V_ENGINEER_USER IS NULL OR V_ENGINEER_PASS IS NULL THEN
        RAISE_APPLICATION_ERROR(-20096, 'ENGINEER_USER / ENGINEER_USER_PASSWORD nao definidos no container.');
    END IF;

    -- Protecao contra SQL Injection via higienizacao do nome de usuario
    IF NOT REGEXP_LIKE(V_ENGINEER_USER, '^[A-Za-z][A-Za-z0-9_]{0,29}$') THEN
        RAISE_APPLICATION_ERROR(-20095, 'ENGINEER_USER fora do padrao de nomenclatura.');
    END IF;

    EXECUTE IMMEDIATE 'CREATE USER ' || V_ENGINEER_USER ||
                      ' IDENTIFIED BY "' || V_ENGINEER_PASS || '" ' ||
                      ' PROFILE KAWASHI_SECURE_PROFILE ' ||
                      ' DEFAULT TABLESPACE TS_KAWASHI_DATA';

    -- Onboarding seguro: senha do .env e apenas a inicial, deve ser trocada no primeiro logon
    EXECUTE IMMEDIATE 'ALTER USER ' || V_ENGINEER_USER || ' PASSWORD EXPIRE';

    -- Privilegio total de administracao (uso pessoal do engenheiro do projeto, nao da aplicacao)
    EXECUTE IMMEDIATE 'GRANT DBA TO ' || V_ENGINEER_USER;
    EXECUTE IMMEDIATE 'GRANT ROLE_KAWASHI_INFRA TO ' || V_ENGINEER_USER;
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -01920 THEN RAISE; END IF; -- usuario ja existe, script e re-executavel
END;
/
