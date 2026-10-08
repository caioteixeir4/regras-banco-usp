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

    -- CORRIGIDO (achado testando ao vivo, ver item 14 de infra/docs/bugs-primeiro-teste.md):
    -- KAWASHI_SECURE_PROFILE e pensado pra pessoa (SESSIONS_PER_USER=3) - um
    -- pool de conexoes de verdade (HikariCP, 10 conexoes por padrao) quebraria
    -- a aplicacao na propria inicializacao. KAWASHI_SERVICE_PROFILE (ver
    -- 02_global_hardening.sql) mantem a mesma politica de senha, mas com
    -- limites de sessao/tempo dimensionados pra uma conta de servico.
    EXECUTE IMMEDIATE 'ALTER USER ' || V_APP_USER || ' PROFILE KAWASHI_SERVICE_PROFILE';
    EXECUTE IMMEDIATE 'ALTER USER ' || V_APP_USER || ' DEFAULT TABLESPACE TS_KAWASHI_DATA';

    -- CORRIGIDO (achado testando contra o Oracle de verdade): a imagem
    -- gvenzl/oracle-free NAO concede o privilegio de sistema UNLIMITED
    -- TABLESPACE ao criar o APP_USER - ela da uma quota especifica na
    -- tablespace embutida USERS. Ou seja, o REVOKE original sempre falhava
    -- com ORA-01952 ("nunca foi concedido"), e por estar dentro do MESMO
    -- bloco PL/SQL sem tratamento de erro, esse erro abortava TODAS as
    -- linhas seguintes (quota, password expire, grant da role) - o usuario
    -- da aplicacao ficava sem nada disso configurado, silenciosamente.
    -- Corrigido para: (1) fechar a quota que a propria imagem concedeu em
    -- USERS, (2) ignorar o REVOKE se o privilegio realmente nao existir.
    BEGIN
        EXECUTE IMMEDIATE 'ALTER USER ' || V_APP_USER || ' QUOTA 0 ON USERS';
    EXCEPTION
        WHEN OTHERS THEN NULL; -- ok se a tablespace USERS nem existir/ja estiver sem quota
    END;
    BEGIN
        EXECUTE IMMEDIATE 'REVOKE UNLIMITED TABLESPACE FROM ' || V_APP_USER;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE != -1952 THEN RAISE; END IF; -- -1952 = privilegio nunca foi concedido, ok ignorar
    END;

    -- GARANTIA OPERACIONAL: Concede cota ilimitada apenas no espaço seguro dedicado a ele
    EXECUTE IMMEDIATE 'ALTER USER ' || V_APP_USER || ' QUOTA UNLIMITED ON TS_KAWASHI_DATA';

    -- CORRIGIDO: NAO forcar PASSWORD EXPIRE aqui. Testamos isso ao vivo com o
    -- ENGINEER_USER (que tambem tinha PASSWORD EXPIRE) e travou toda automacao
    -- que conecta via sqlplus nao-interativo - o Oracle exige responder a troca
    -- de senha antes de aceitar qualquer outro comando. Isso faz sentido pra
    -- conta de PESSOA (ver 08_engineer_account.sql, onde a troca interativa e
    -- justamente o objetivo), mas nao pra conta de APLICACAO: um pool de
    -- conexao JDBC do Spring Boot jamais vai conseguir responder a esse prompt
    -- interativo - a conexao simplesmente falharia pra sempre no primeiro uso.

    -- Distribuição controlada de acessos e atribuição de papéis. A propria
    -- imagem tambem concede DB_DEVELOPER_ROLE (role generica dela, fora do
    -- nosso controle de RBAC) - removemos pra manter so os privilegios que
    -- nos mesmos definimos e auditamos.
    BEGIN
        EXECUTE IMMEDIATE 'REVOKE DB_DEVELOPER_ROLE FROM ' || V_APP_USER;
    EXCEPTION
        WHEN OTHERS THEN NULL; -- ok se esta role nao existir/nao tiver sido concedida em versoes futuras da imagem
    END;
    EXECUTE IMMEDIATE 'GRANT KAWASHI_READWRITE TO ' || V_APP_USER;
END;
/


-- #########################################################
-- PASSO 14 - LOCKOUT DE CREDENCIAIS EXPOSTAS NATIVAS
-- #########################################################
-- CORRIGIDO: testado ao vivo, SCOTT e HR (schemas de demonstracao classicos
-- do Oracle) nao existem nesta imagem minima gvenzl/oracle-free - o ALTER
-- USER falhava com ORA-01918 ("usuario nao existe"). Nao e um problema de
-- seguranca (se a conta nao existe, nao ha o que explorar), mas o script
-- ficava com erro no log por algo que nao e realmente um erro. Envolvido em
-- tratamento de erro pra rodar limpo independente de quais contas de demo a
-- imagem realmente cria (pode variar por versao).
DECLARE
    PROCEDURE lock_if_exists(p_username VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'ALTER USER ' || p_username || ' ACCOUNT LOCK';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE != -1918 THEN RAISE; END IF; -- -1918 = usuario nao existe, ok ignorar
    END;
BEGIN
    lock_if_exists('SCOTT');
    lock_if_exists('HR');
    lock_if_exists('OUTLN');
    lock_if_exists('DBSNMP');
    lock_if_exists('DIP');
    lock_if_exists('ANONYMOUS');
END;
/