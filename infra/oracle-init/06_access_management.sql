-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 13 - GESTÃO RIGOROSA DE ACESSOS (LEAST PRIVILEGE)
-- #########################################################

-- Criação das Roles de privilégios mínimos para a aplicação
DECLARE
    PROCEDURE create_role_if_not_exists(p_role VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'CREATE ROLE ' || p_role;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE != -01921 THEN RAISE; END IF; 
    END;
BEGIN
    create_role_if_not_exists('KAWASHI_READONLY');
    create_role_if_not_exists('KAWASHI_READWRITE');
END;
/

-- #########################################################
-- PASSO 13.1 - PRIVILÉGIOS DAS ROLES (LEAST PRIVILEGE)
-- #########################################################
-- READWRITE: privilegios minimos para o dono do schema construir e manter seus proprios objetos.
GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE SEQUENCE, CREATE PROCEDURE, CREATE TRIGGER
    TO KAWASHI_READWRITE;

-- READONLY: apenas conexao por enquanto; GRANT SELECT ON <tabela> deve ser adicionado
-- objeto a objeto quando o schema da aplicacao existir (evitar SELECT ANY TABLE).
GRANT CREATE SESSION TO KAWASHI_READONLY;

-- #########################################################
-- PASSO 13.2 - HARDENING DO USUARIO DA APLICACAO
-- #########################################################
-- O usuario da aplicacao (KAWASHI_USER) ja e criado pela propria imagem gvenzl/oracle-free
-- a partir das variaveis de ambiente APP_USER/APP_USER_PASSWORD (ver docker-compose.yml + .env).
-- Aqui so amarramos profile/quota/roles nele - nenhuma senha em texto puro no SQL.
ALTER USER KAWASHI_USER PROFILE KAWASHI_SECURE_PROFILE;
ALTER USER KAWASHI_USER DEFAULT TABLESPACE TS_KAWASHI_DATA;

-- Correção estrita de segurança: remove o privilégio nocivo de escrita em qualquer local do banco
REVOKE UNLIMITED TABLESPACE FROM KAWASHI_USER;

-- GARANTIA OPERACIONAL: Concede cota ilimitada apenas no espaço seguro dedicado a ele
ALTER USER KAWASHI_USER QUOTA UNLIMITED ON TS_KAWASHI_DATA;

-- Força o onboarding seguro (o desenvolvedor deve trocar a senha no primeiro logon)
ALTER USER KAWASHI_USER PASSWORD EXPIRE;

-- Distribuição controlada de acessos e atribuição de papéis
GRANT KAWASHI_READWRITE TO KAWASHI_USER;


-- #########################################################
-- PASSO 14 - LOCKOUT DE CREDENCIAIS EXPOSTAS NATIVAS
-- #########################################################
ALTER USER SCOTT ACCOUNT LOCK;
ALTER USER HR ACCOUNT LOCK;
ALTER USER OUTLN ACCOUNT LOCK;
ALTER USER DBSNMP ACCOUNT LOCK;
ALTER USER DIP ACCOUNT LOCK;
ALTER USER ANONYMOUS ACCOUNT LOCK;