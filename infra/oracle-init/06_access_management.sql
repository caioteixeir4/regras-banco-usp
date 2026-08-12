-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 13 - GESTÃO RIGOROSA DE ACESSOS (LEAST PRIVILEGE)
-- #########################################################

-- Criação das Roles de privilégios mínimos para a aplicação.
-- Por que esse helper em vez de um CREATE ROLE direto? O Oracle nao tem
-- "CREATE ROLE IF NOT EXISTS" nativo - se a role ja existir, o CREATE simples
-- falharia com ORA-01921 e pararia a execucao do script inteiro. Capturando
-- especificamente esse codigo de erro (e relancando qualquer outro erro
-- diferente disso), o script fica seguro para rodar mais de uma vez (por
-- exemplo, se o container for reiniciado sem apagar o volume de dados).
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
-- O usuario da aplicacao ja e criado pela propria imagem gvenzl/oracle-free a partir das
-- variaveis de ambiente APP_USER/APP_USER_PASSWORD (ver docker-compose.yml + .env). O nome
-- do usuario e lido dinamicamente do ambiente do container (nao fica hardcoded aqui), entao
-- trocar de usuario no futuro exige apenas editar o .env - este script nao precisa mudar.
DECLARE
    V_APP_USER VARCHAR2(30);
BEGIN
    DBMS_SYSTEM.GET_ENV('APP_USER', V_APP_USER);

    IF V_APP_USER IS NULL THEN
        RAISE_APPLICATION_ERROR(-20097, 'Variavel de ambiente APP_USER nao definida no container.');
    END IF;

    -- Protecao contra SQL Injection via higienizacao do nome de usuario
    IF NOT REGEXP_LIKE(V_APP_USER, '^[A-Za-z][A-Za-z0-9_]{0,29}$') THEN
        RAISE_APPLICATION_ERROR(-20098, 'APP_USER fora do padrao de nomenclatura.');
    END IF;

    EXECUTE IMMEDIATE 'ALTER USER ' || V_APP_USER || ' PROFILE KAWASHI_SECURE_PROFILE';
    EXECUTE IMMEDIATE 'ALTER USER ' || V_APP_USER || ' DEFAULT TABLESPACE TS_KAWASHI_DATA';

    -- Correção estrita de segurança: remove o privilégio nocivo de escrita em qualquer local do banco
    EXECUTE IMMEDIATE 'REVOKE UNLIMITED TABLESPACE FROM ' || V_APP_USER;

    -- GARANTIA OPERACIONAL: Concede cota ilimitada apenas no espaço seguro dedicado a ele
    EXECUTE IMMEDIATE 'ALTER USER ' || V_APP_USER || ' QUOTA UNLIMITED ON TS_KAWASHI_DATA';

    -- Força o onboarding seguro (o desenvolvedor deve trocar a senha no primeiro logon)
    EXECUTE IMMEDIATE 'ALTER USER ' || V_APP_USER || ' PASSWORD EXPIRE';

    -- Distribuição controlada de acessos e atribuição de papéis
    EXECUTE IMMEDIATE 'GRANT KAWASHI_READWRITE TO ' || V_APP_USER;
END;
/


-- #########################################################
-- PASSO 14 - LOCKOUT DE CREDENCIAIS EXPOSTAS NATIVAS
-- #########################################################
ALTER USER SCOTT ACCOUNT LOCK;
ALTER USER HR ACCOUNT LOCK;
ALTER USER OUTLN ACCOUNT LOCK;
ALTER USER DBSNMP ACCOUNT LOCK;
ALTER USER DIP ACCOUNT LOCK;
ALTER USER ANONYMOUS ACCOUNT LOCK;