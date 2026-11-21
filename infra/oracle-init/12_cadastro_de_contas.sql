-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 12 - CADASTRO DE CONTAS: QUEM E, O QUE PODE, QUANDO A SENHA VENCE
-- #########################################################
-- O Oracle sabe que a conta JOAO existe, mas nao sabe que o Joao e "Desenvolvedor Pleno",
-- nem que a conta API_DEV e "a conta de execucao da API no ambiente DEV". Essa informacao
-- vivia so na cabeca de quem rodou o script de criacao.
--
-- Este arquivo cria:
--   KAWASHI_CONTA                -> uma linha por conta criada (pessoa, API ou administrador),
--                                   com perfil, nome e cargo. E a UNICA coisa que o banco nao
--                                   tem como saber sozinho.
--   KAWASHI_REGISTRAR_CONTA      -> o unico caminho para gravar nessa tabela. Os scripts
--                                   create-team-member.ps1 e create-api-account.ps1 chamam.
--   V_KAWASHI_CONTA_LIBERACOES   -> o que cada conta PODE: ambientes (proxy), roles,
--                                   privilegios de sistema e de objeto. Lido AO VIVO do
--                                   dicionario do Oracle, nao copiado.
--   V_KAWASHI_CONTAS             -> o painel: uma linha por conta com cargo, liberacoes,
--                                   idade da senha, quando vence e o que esta pendente.
--
-- Decisao de projeto: liberacoes e datas de senha NAO sao gravadas na tabela. Uma copia
-- envelhece (alguem da um GRANT por fora e a tabela continua dizendo o contrario). A view
-- le a verdade direto do dicionario; a tabela guarda so o que e declarado por gente.
-- Pelo mesmo motivo, a view tambem mostra conta que existe no banco e NAO foi cadastrada
-- ("SEM CADASTRO"): conta criada por fora dos scripts aparece, nao some.
--
-- A tabela fica em TS_KAWASHI_DATA (cifrada em disco pelo enable-tde.ps1), e nao em SYSTEM,
-- porque nome e cargo de pessoa sao dados pessoais.
--
-- Re-executavel: pode rodar de novo num banco que ja tem tudo.

DECLARE
    v_existe NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_existe FROM dba_tables WHERE owner = 'SYS' AND table_name = 'KAWASHI_CONTA';
    IF v_existe = 0 THEN
        EXECUTE IMMEDIATE q'[
            CREATE TABLE KAWASHI_CONTA (
                USERNAME    VARCHAR2(128)       NOT NULL,
                TIPO        VARCHAR2(10)        NOT NULL,
                PERFIL      VARCHAR2(30)        NOT NULL,
                NOME        VARCHAR2(200 CHAR),
                CARGO       VARCHAR2(100 CHAR),
                AMBIENTE    VARCHAR2(30),
                CRIADA_EM   TIMESTAMP           DEFAULT SYSTIMESTAMP NOT NULL,
                CRIADA_POR  VARCHAR2(128)       NOT NULL,
                ALTERADA_EM TIMESTAMP,
                ALTERADA_POR VARCHAR2(128),
                CONSTRAINT PK_KAWASHI_CONTA PRIMARY KEY (USERNAME),
                CONSTRAINT CK_KAWASHI_CONTA_TIPO CHECK (TIPO IN ('PESSOA', 'API', 'ADMIN')),
                CONSTRAINT CK_KAWASHI_CONTA_MAIUSCULA CHECK (USERNAME = UPPER(USERNAME))
            ) TABLESPACE TS_KAWASHI_DATA]';
        EXECUTE IMMEDIATE q'[COMMENT ON TABLE KAWASHI_CONTA IS 'Cadastro das contas criadas pelos scripts: quem e (nome, cargo), que tipo (pessoa, API, administrador) e com que perfil nasceu. Liberacoes e validade de senha vem das views V_KAWASHI_CONTAS e V_KAWASHI_CONTA_LIBERACOES.']';
    END IF;

    -- Desligamento (quem saiu do time): quando, quem desligou e por que. Acrescentadas depois da
    -- primeira versao da tabela, por isso cada uma so entra se ainda nao existir.
    FOR c IN (SELECT 'DESLIGADA_EM TIMESTAMP' AS def, 'DESLIGADA_EM' AS nome FROM dual
              UNION ALL SELECT 'DESLIGADA_POR VARCHAR2(128)', 'DESLIGADA_POR' FROM dual
              UNION ALL SELECT 'MOTIVO_DESLIGAMENTO VARCHAR2(300 CHAR)', 'MOTIVO_DESLIGAMENTO' FROM dual) LOOP
        SELECT COUNT(*) INTO v_existe FROM dba_tab_columns
         WHERE owner = 'SYS' AND table_name = 'KAWASHI_CONTA' AND column_name = c.nome;
        IF v_existe = 0 THEN
            EXECUTE IMMEDIATE 'ALTER TABLE KAWASHI_CONTA ADD (' || c.def || ')';
        END IF;
    END LOOP;
END;
/

-- ---------------------------------------------------------------------------
-- O unico caminho de escrita. Roda com os direitos do dono (SYS), entao quem
-- chama nao precisa (nem recebe) INSERT/UPDATE na tabela.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE KAWASHI_REGISTRAR_CONTA (
    p_username IN VARCHAR2,
    p_tipo     IN VARCHAR2,
    p_perfil   IN VARCHAR2,
    p_nome     IN VARCHAR2 DEFAULT NULL,
    p_cargo    IN VARCHAR2 DEFAULT NULL,
    p_ambiente IN VARCHAR2 DEFAULT NULL
) AS
    v_username VARCHAR2(128) := UPPER(TRIM(p_username));
    v_existe   NUMBER;
    v_quem     VARCHAR2(128) := SYS_CONTEXT('USERENV', 'SESSION_USER');
BEGIN
    -- So se cadastra conta que existe: o cadastro descreve o banco, nao inventa.
    SELECT COUNT(*) INTO v_existe FROM dba_users WHERE username = v_username;
    IF v_existe = 0 THEN
        RAISE_APPLICATION_ERROR(-20080, 'Conta ' || v_username || ' nao existe no banco: nada a cadastrar.');
    END IF;
    IF p_tipo NOT IN ('PESSOA', 'API', 'ADMIN') OR p_tipo IS NULL THEN
        RAISE_APPLICATION_ERROR(-20081, 'Tipo de conta invalido: use PESSOA, API ou ADMIN.');
    END IF;
    IF TRIM(p_perfil) IS NULL THEN
        RAISE_APPLICATION_ERROR(-20082, 'Perfil obrigatorio.');
    END IF;

    -- Uma conta desligada continua desligada quando alguem so completa o cadastro dela. Mas se o
    -- mesmo nome foi apagado e criado DE NOVO depois do desligamento, e outra conta: o
    -- desligamento antigo deixa de valer para ela.
    UPDATE KAWASHI_CONTA c
       SET c.DESLIGADA_EM = NULL, c.DESLIGADA_POR = NULL, c.MOTIVO_DESLIGAMENTO = NULL
     WHERE c.USERNAME = v_username
       AND c.DESLIGADA_EM IS NOT NULL
       AND (SELECT CAST(u.created AS TIMESTAMP) FROM dba_users u WHERE u.username = v_username) > c.DESLIGADA_EM;

    MERGE INTO KAWASHI_CONTA c
    USING (SELECT v_username AS username FROM dual) n
       ON (c.USERNAME = n.username)
     WHEN MATCHED THEN UPDATE SET
          c.TIPO = p_tipo,
          c.PERFIL = TRIM(p_perfil),
          -- Nome e cargo so mudam quando um valor novo e informado: recadastrar sem eles nao apaga.
          c.NOME = NVL(TRIM(p_nome), c.NOME),
          c.CARGO = NVL(TRIM(p_cargo), c.CARGO),
          c.AMBIENTE = NVL(TRIM(p_ambiente), c.AMBIENTE),
          c.ALTERADA_EM = SYSTIMESTAMP,
          c.ALTERADA_POR = v_quem
     WHEN NOT MATCHED THEN INSERT (USERNAME, TIPO, PERFIL, NOME, CARGO, AMBIENTE, CRIADA_POR)
          VALUES (v_username, p_tipo, TRIM(p_perfil), TRIM(p_nome), TRIM(p_cargo), TRIM(p_ambiente), v_quem);
    COMMIT;
END;
/

-- ---------------------------------------------------------------------------
-- DESLIGAMENTO: quem sai do time perde todo acesso na hora, e fica registrado.
--
-- A conta NAO e apagada aqui: fica trancada, para a auditoria continuar ligada a
-- um nome que existe (apagar e opcional, no script remove-team-member.ps1).
-- Em ordem:
--   1. tranca a conta e expira a senha (ninguem entra mais, nem com a senha certa);
--   2. tira o proxy em todos os ambientes;
--   3. revoga todas as roles, privilegios de sistema e permissoes em objetos;
--   4. derruba as sessoes abertas, inclusive as abertas POR PROXY: nelas o Oracle
--      mostra o nome do ambiente, nao o da pessoa, entao a sessao e achada pela
--      auditoria de logon (UNIFIED_AUDIT_TRAIL.DBPROXY_USERNAME + SESSIONID = AUDSID);
--   5. grava no cadastro quando, quem e por que.
-- So vale para conta de PESSOA (perfil KAWASHI_SECURE_PROFILE). Conta de API,
-- administrador, quem tem DBA e a propria conta de quem chama sao recusados.
-- O resumo do que foi feito sai por DBMS_OUTPUT, numa linha "RESUMO|...".
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE KAWASHI_DESLIGAR_CONTA (
    p_username IN VARCHAR2,
    p_motivo   IN VARCHAR2
) AS
    v_u        VARCHAR2(128) := UPPER(TRIM(p_username));
    v_quem     VARCHAR2(128) := SYS_CONTEXT('USERENV', 'SESSION_USER');
    v_perfil   VARCHAR2(128);
    v_tipo     VARCHAR2(10);
    v_dba      NUMBER;
    v_proxies  NUMBER := 0;
    v_roles    NUMBER := 0;
    v_privs    NUMBER := 0;
    v_objetos  NUMBER := 0;
    v_sessoes  NUMBER := 0;
BEGIN
    IF TRIM(p_motivo) IS NULL THEN
        RAISE_APPLICATION_ERROR(-20085, 'Informe o motivo do desligamento.');
    END IF;
    BEGIN
        SELECT profile INTO v_perfil FROM dba_users WHERE username = v_u;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20080, 'Conta ' || v_u || ' nao existe no banco.');
    END;
    BEGIN
        SELECT TIPO INTO v_tipo FROM KAWASHI_CONTA WHERE USERNAME = v_u;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        v_tipo := NULL;
    END;
    SELECT COUNT(*) INTO v_dba FROM dba_role_privs WHERE grantee = v_u AND granted_role = 'DBA';
    IF v_perfil <> 'KAWASHI_SECURE_PROFILE' OR v_tipo IN ('API', 'ADMIN') OR v_dba > 0 OR v_u = v_quem THEN
        RAISE_APPLICATION_ERROR(-20083, 'A conta ' || v_u || ' nao e de pessoa do time (e de API, administrador, '
            || 'tem DBA ou e a sua propria). Desligamento por aqui so vale para pessoas.');
    END IF;

    -- 1. ninguem entra mais
    EXECUTE IMMEDIATE 'ALTER USER "' || v_u || '" PASSWORD EXPIRE ACCOUNT LOCK';

    -- 2. proxy em todos os ambientes (em DBA_PROXIES, PROXY e quem entra e CLIENT e o ambiente)
    FOR p IN (SELECT client FROM dba_proxies WHERE proxy = v_u) LOOP
        EXECUTE IMMEDIATE 'ALTER USER "' || p.client || '" REVOKE CONNECT THROUGH "' || v_u || '"';
        v_proxies := v_proxies + 1;
    END LOOP;

    -- 3. roles, privilegios de sistema e permissoes diretas em objetos
    FOR r IN (SELECT granted_role FROM dba_role_privs WHERE grantee = v_u) LOOP
        EXECUTE IMMEDIATE 'REVOKE "' || r.granted_role || '" FROM "' || v_u || '"';
        v_roles := v_roles + 1;
    END LOOP;
    FOR s IN (SELECT privilege FROM dba_sys_privs WHERE grantee = v_u) LOOP
        EXECUTE IMMEDIATE 'REVOKE ' || s.privilege || ' FROM "' || v_u || '"';
        v_privs := v_privs + 1;
    END LOOP;
    FOR o IN (SELECT owner, table_name, privilege FROM dba_tab_privs WHERE grantee = v_u) LOOP
        EXECUTE IMMEDIATE 'REVOKE ' || o.privilege || ' ON "' || o.owner || '"."' || o.table_name || '" FROM "' || v_u || '"';
        v_objetos := v_objetos + 1;
    END LOOP;

    -- 4. sessoes abertas: direto na conta, ou por proxy. A sessao por proxy aparece com o nome do
    --    AMBIENTE, e o numero de sessao da auditoria NAO e o AUDSID do v$session (conferido). O
    --    que liga as duas e o processo do servidor: a auditoria grava o OS_PROCESS de cada logon,
    --    e o v$process diz qual processo atende cada sessao. A sessao e da pessoa quando o ULTIMO
    --    logon auditado naquele processo foi feito por proxy por ela, como aquele ambiente (o
    --    "ultimo" evita confundir com um processo antigo de mesmo numero, e nao depende de fuso).
    --    Depende da auditoria de LOGON ligada (02_global_hardening.sql).
    FOR s IN (SELECT ss.sid, ss.serial# AS serial
                FROM v$session ss JOIN v$process pp ON pp.addr = ss.paddr
               WHERE ss.username = v_u
                  OR EXISTS (SELECT 1
                               FROM (SELECT a.os_process, a.dbusername, a.dbproxy_username,
                                            ROW_NUMBER() OVER (PARTITION BY a.os_process ORDER BY a.event_timestamp DESC) AS rn
                                       FROM unified_audit_trail a
                                      WHERE a.action_name = 'LOGON'
                                        AND a.event_timestamp > SYSTIMESTAMP - INTERVAL '1' DAY) ult
                              WHERE ult.rn = 1
                                AND ult.os_process = pp.spid
                                AND ult.dbusername = ss.username
                                AND ult.dbproxy_username = v_u)) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'ALTER SYSTEM KILL SESSION ''' || s.sid || ',' || s.serial || ''' IMMEDIATE';
            v_sessoes := v_sessoes + 1;
        EXCEPTION
            -- ORA-00031 ("session marked for kill") vem mesmo com IMMEDIATE quando a sessao estava
            -- no meio de uma chamada, e ela cai do mesmo jeito (conferido): conta como derrubada.
            WHEN OTHERS THEN
                IF SQLCODE = -31 THEN
                    v_sessoes := v_sessoes + 1;
                END IF;
                -- outro erro: a sessao terminou sozinha entre a consulta e o KILL
        END;
    END LOOP;

    -- 5. registro
    MERGE INTO KAWASHI_CONTA c
    USING (SELECT v_u AS username FROM dual) n
       ON (c.USERNAME = n.username)
     WHEN MATCHED THEN UPDATE SET
          c.DESLIGADA_EM = SYSTIMESTAMP, c.DESLIGADA_POR = v_quem, c.MOTIVO_DESLIGAMENTO = TRIM(p_motivo),
          c.ALTERADA_EM = SYSTIMESTAMP, c.ALTERADA_POR = v_quem
     WHEN NOT MATCHED THEN INSERT (USERNAME, TIPO, PERFIL, CRIADA_POR, DESLIGADA_EM, DESLIGADA_POR, MOTIVO_DESLIGAMENTO)
          VALUES (v_u, 'PESSOA', 'SemCadastro', v_quem, SYSTIMESTAMP, v_quem, TRIM(p_motivo));
    COMMIT;

    DBMS_OUTPUT.PUT_LINE('RESUMO|proxies=' || v_proxies || '|roles=' || v_roles || '|privilegios=' || v_privs
        || '|objetos=' || v_objetos || '|sessoes=' || v_sessoes);
END;
/

-- ---------------------------------------------------------------------------
-- A regra da senha num lugar so, testavel sem esperar 90 dias: recebe o status
-- da conta, a idade da senha em dias e o limite, devolve a situacao.
--   CONTA BLOQUEADA  a conta esta travada (tentativas erradas ou bloqueio manual)
--   SEM DATA         o banco nao tem data de troca (nao deveria acontecer)
--   VENCIDA          idade maior que o limite
--   TROCA PENDENTE   conta nova: a senha temporaria nasce expirada e a pessoa
--                    ainda nao fez o primeiro login. Nao e pendencia do administrador.
--   VENCE EM BREVE   faltam 15 dias ou menos
--   EM DIA           o resto
-- A ordem importa: uma conta expirada HA MAIS tempo que o limite e VENCIDA, nao "nova".
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION KAWASHI_SITUACAO_DA_SENHA (
    p_status      IN VARCHAR2,
    p_idade_dias  IN NUMBER,
    p_limite_dias IN NUMBER
) RETURN VARCHAR2 DETERMINISTIC AS
BEGIN
    IF p_status LIKE '%LOCKED%' THEN RETURN 'CONTA BLOQUEADA'; END IF;
    IF p_idade_dias IS NULL OR p_limite_dias IS NULL THEN RETURN 'SEM DATA'; END IF;
    IF p_idade_dias > p_limite_dias THEN RETURN 'VENCIDA'; END IF;
    IF p_status LIKE 'EXPIRED%' THEN RETURN 'TROCA PENDENTE'; END IF;
    IF p_limite_dias - p_idade_dias <= 15 THEN RETURN 'VENCE EM BREVE'; END IF;
    RETURN 'EM DIA';
END;
/

-- ---------------------------------------------------------------------------
-- O que cada conta pode, lido ao vivo do dicionario.
-- "Conta" aqui e toda conta com um dos perfis de senha do projeto (pessoas e
-- administradores no KAWASHI_SECURE_PROFILE, APIs no KAWASHI_SERVICE_PROFILE).
-- Os schemas de ambiente (KAWASHI_ENV_*) nao entram: ninguem faz login neles.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_KAWASHI_CONTA_LIBERACOES AS
SELECT u.username AS USERNAME, 'AMBIENTE' AS TIPO_LIBERACAO, p.client AS LIBERACAO,
       'entra nesse schema por proxy: ' || u.username || '[' || p.client || ']' AS DETALHE
  FROM dba_users u JOIN dba_proxies p ON p.proxy = u.username
 WHERE u.profile LIKE 'KAWASHI\_%' ESCAPE '\'
UNION ALL
SELECT u.username, 'ROLE', r.granted_role,
       CASE WHEN r.admin_option = 'YES' THEN 'pode repassar a role' ELSE 'role concedida' END
  FROM dba_users u JOIN dba_role_privs r ON r.grantee = u.username
 WHERE u.profile LIKE 'KAWASHI\_%' ESCAPE '\'
UNION ALL
SELECT u.username, 'PRIVILEGIO', s.privilege, 'privilegio de sistema concedido direto'
  FROM dba_users u JOIN dba_sys_privs s ON s.grantee = u.username
 WHERE u.profile LIKE 'KAWASHI\_%' ESCAPE '\'
UNION ALL
SELECT u.username, 'OBJETO', t.privilege || ' em ' || t.owner || '.' || t.table_name, 'permissao direta em um objeto'
  FROM dba_users u JOIN dba_tab_privs t ON t.grantee = u.username
 WHERE u.profile LIKE 'KAWASHI\_%' ESCAPE '\';

COMMENT ON TABLE V_KAWASHI_CONTA_LIBERACOES IS 'Uma linha por liberacao de cada conta (ambiente via proxy, role, privilegio de sistema, permissao em objeto), lida ao vivo do dicionario.';

-- ---------------------------------------------------------------------------
-- O painel. Regras de senha:
--   * O limite de dias vem do proprio perfil KAWASHI_SECURE_PROFILE
--     (PASSWORD_LIFE_TIME, hoje 90). Mudou la, muda aqui.
--   * Pessoa/administrador: o Oracle BLOQUEIA sozinho ao vencer (com os dias
--     de tolerancia do perfil). A view so avisa antes.
--   * Conta de API: a senha NAO expira sozinha de proposito (uma API parada
--     de madrugada por senha vencida e pior que o risco). Em troca, a view
--     conta os mesmos dias e marca "VENCIDA" para alguem rotacionar a mao.
--   * "VENCE EM BREVE" = faltam 15 dias ou menos.
--   * Conta DESLIGADA (remove-team-member.ps1) nao tem senha cobrada; vira alarme se for
--     destrancada ou receber acesso de novo.
--   * "TROCA PENDENTE" = conta nova que ainda nao fez o primeiro login (a senha
--     temporaria nasce expirada). Nao e pendencia do administrador.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_KAWASHI_CONTAS AS
WITH limite AS (
    SELECT NVL(MAX(CASE WHEN REGEXP_LIKE(limit, '^\d+$') THEN TO_NUMBER(limit) END), 90) AS dias
      FROM dba_profiles
     WHERE profile = 'KAWASHI_SECURE_PROFILE' AND resource_name = 'PASSWORD_LIFE_TIME'
),
banco AS (
    SELECT username, profile, account_status, password_change_date, expiry_date, last_login, created
      FROM dba_users
     WHERE profile LIKE 'KAWASHI\_%' ESCAPE '\'
),
liberacoes AS (
    SELECT username,
           LISTAGG(CASE WHEN tipo_liberacao = 'AMBIENTE' THEN liberacao END, ', ') WITHIN GROUP (ORDER BY liberacao) AS ambientes,
           LISTAGG(CASE WHEN tipo_liberacao = 'ROLE' THEN liberacao END, ', ') WITHIN GROUP (ORDER BY liberacao) AS roles,
           LISTAGG(CASE WHEN tipo_liberacao = 'PRIVILEGIO' THEN liberacao END, ', ') WITHIN GROUP (ORDER BY liberacao) AS privilegios
      FROM V_KAWASHI_CONTA_LIBERACOES
     GROUP BY username
),
base AS (
    SELECT NVL(b.username, c.USERNAME) AS username,
           NVL(c.TIPO, CASE b.profile WHEN 'KAWASHI_SERVICE_PROFILE' THEN 'API' ELSE 'PESSOA' END) AS tipo,
           c.PERFIL AS perfil, c.NOME AS nome, c.CARGO AS cargo, c.AMBIENTE AS ambiente,
           CASE WHEN c.DESLIGADA_EM IS NOT NULL THEN 'DESLIGADA'
                WHEN b.username IS NULL THEN 'REMOVIDA'
                WHEN c.USERNAME IS NULL THEN 'SEM CADASTRO'
                ELSE 'OK' END AS cadastro,
           b.account_status, b.profile, b.password_change_date, b.last_login,
           NVL(c.CRIADA_EM, CAST(b.created AS TIMESTAMP)) AS criada_em, c.CRIADA_POR AS criada_por,
           c.DESLIGADA_EM AS desligada_em, c.DESLIGADA_POR AS desligada_por, c.MOTIVO_DESLIGAMENTO AS motivo_desligamento,
           b.username AS existe_no_banco,
           l.dias AS limite_dias,
           TRUNC(SYSDATE) - TRUNC(b.password_change_date) AS idade_dias
      FROM banco b
      FULL OUTER JOIN KAWASHI_CONTA c ON c.USERNAME = b.username
     CROSS JOIN limite l
),
situacao AS (
    SELECT x.*,
           x.limite_dias - x.idade_dias AS dias_para_vencer,
           -- Quem saiu (ou foi apagado) nao tem senha a cobrar.
           CASE WHEN x.cadastro IN ('REMOVIDA', 'DESLIGADA') THEN NULL
                ELSE KAWASHI_SITUACAO_DA_SENHA(x.account_status, x.idade_dias, x.limite_dias) END AS situacao_da_senha
      FROM base x
)
SELECT s.username                                   AS USERNAME,
       s.tipo                                       AS TIPO,
       s.perfil                                     AS PERFIL,
       s.nome                                       AS NOME,
       s.cargo                                      AS CARGO,
       s.ambiente                                   AS AMBIENTE,
       s.cadastro                                   AS CADASTRO,
       s.account_status                             AS STATUS_DA_CONTA,
       lb.ambientes                                 AS AMBIENTES_LIBERADOS,
       lb.roles                                     AS ROLES,
       lb.privilegios                               AS PRIVILEGIOS_DIRETOS,
       s.profile                                    AS PERFIL_DE_SENHA,
       s.password_change_date                       AS SENHA_TROCADA_EM,
       s.idade_dias                                 AS IDADE_DA_SENHA_DIAS,
       s.limite_dias                                AS LIMITE_DIAS,
       TRUNC(s.password_change_date) + s.limite_dias AS SENHA_VENCE_EM,
       s.dias_para_vencer                           AS DIAS_PARA_VENCER,
       s.situacao_da_senha                          AS SITUACAO_DA_SENHA,
       CASE WHEN s.cadastro IN ('REMOVIDA', 'DESLIGADA') THEN NULL
            WHEN s.profile = 'KAWASHI_SERVICE_PROFILE' THEN 'NAO (rotacao manual)'
            ELSE 'SIM (o banco bloqueia)' END       AS EXPIRA_SOZINHA,
       s.last_login                                 AS ULTIMO_LOGIN,
       s.criada_em                                  AS CRIADA_EM,
       s.criada_por                                 AS CRIADA_POR,
       -- O que precisa de acao de alguem. NULL = nada pendente.
       RTRIM(
           CASE WHEN s.cadastro = 'SEM CADASTRO' THEN 'conta sem cadastro; ' END ||
           -- Desligada tem de continuar trancada e sem acesso. Se alguem destrancar ou devolver um
           -- acesso por fora, e alarme (e o caso de quem tenta voltar pela porta dos fundos).
           CASE WHEN s.cadastro = 'DESLIGADA' AND s.existe_no_banco IS NOT NULL
                     AND NVL(s.account_status, 'X') NOT LIKE '%LOCKED%' THEN 'DESLIGADA MAS A CONTA ESTA ABERTA; ' END ||
           CASE WHEN s.cadastro = 'DESLIGADA' AND (lb.ambientes IS NOT NULL OR lb.roles IS NOT NULL OR lb.privilegios IS NOT NULL)
                THEN 'DESLIGADA MAS AINDA TEM ACESSO; ' END ||
           CASE WHEN s.cadastro = 'OK' AND s.tipo IN ('PESSOA', 'ADMIN') AND s.cargo IS NULL THEN 'sem cargo; ' END ||
           CASE WHEN s.cadastro = 'OK' AND s.tipo IN ('PESSOA', 'ADMIN') AND s.nome IS NULL THEN 'sem nome; ' END ||
           -- Troca gradual em andamento (rotate-api-password.ps1): a senha antiga ainda entra ate
           -- alguem encerrar o periodo. O normal e durar minutos; ficar esquecido e risco.
           CASE WHEN s.account_status LIKE '%IN ROLLOVER%' THEN 'senha antiga ainda vale (troca em andamento); ' END ||
           CASE s.situacao_da_senha
                WHEN 'VENCIDA' THEN 'senha vencida ha ' || (-s.dias_para_vencer) || ' dia(s); '
                WHEN 'VENCE EM BREVE' THEN 'senha vence em ' || s.dias_para_vencer || ' dia(s); '
                WHEN 'CONTA BLOQUEADA' THEN 'conta bloqueada; '
                WHEN 'SEM DATA' THEN 'sem data de troca de senha; ' END,
           '; ')                                    AS PENDENCIA,
       s.desligada_em                               AS DESLIGADA_EM,
       s.desligada_por                              AS DESLIGADA_POR,
       s.motivo_desligamento                        AS MOTIVO_DESLIGAMENTO
  FROM situacao s
  LEFT JOIN liberacoes lb ON lb.username = s.username;

COMMENT ON TABLE V_KAWASHI_CONTAS IS 'Painel de contas: uma linha por pessoa, API ou administrador, com cargo, liberacoes, idade e vencimento da senha (limite do KAWASHI_SECURE_PROFILE) e pendencias.';

-- ---------------------------------------------------------------------------
-- Quem le e quem grava.
--   Leitura: time de infra (ROLE_KAWASHI_INFRA). Desenvolvedor comum nao ve o cadastro dos outros.
--   Escrita: so pela procedure, e so o engenheiro do projeto (quem roda os scripts) a executa.
-- ---------------------------------------------------------------------------
GRANT SELECT ON V_KAWASHI_CONTAS TO ROLE_KAWASHI_INFRA;
GRANT SELECT ON V_KAWASHI_CONTA_LIBERACOES TO ROLE_KAWASHI_INFRA;

DECLARE
    v_engenheiro VARCHAR2(30);
BEGIN
    DBMS_SYSTEM.GET_ENV('ENGINEER_USER', v_engenheiro);
    IF v_engenheiro IS NOT NULL AND REGEXP_LIKE(v_engenheiro, '^[A-Za-z][A-Za-z0-9_]{0,29}$') THEN
        v_engenheiro := UPPER(v_engenheiro);
        EXECUTE IMMEDIATE 'GRANT EXECUTE ON KAWASHI_REGISTRAR_CONTA TO ' || v_engenheiro;
        EXECUTE IMMEDIATE 'GRANT EXECUTE ON KAWASHI_DESLIGAR_CONTA TO ' || v_engenheiro;

        -- As contas que nascem no bootstrap (e nao pelos scripts) entram aqui. So na primeira
        -- vez: se alguem ja ajustou o cadastro, rodar de novo nao desfaz.
        INSERT INTO KAWASHI_CONTA (USERNAME, TIPO, PERFIL, CARGO, CRIADA_POR)
        SELECT v_engenheiro, 'ADMIN', 'Engenheiro', 'Engenheiro responsavel pelo banco', 'BOOTSTRAP' FROM dual
         WHERE EXISTS (SELECT 1 FROM dba_users WHERE username = v_engenheiro)
           AND NOT EXISTS (SELECT 1 FROM KAWASHI_CONTA WHERE USERNAME = v_engenheiro);
    END IF;

    INSERT INTO KAWASHI_CONTA (USERNAME, TIPO, PERFIL, CRIADA_POR)
    SELECT 'KAWASHI_SPRING_USER', 'API', 'AplicacaoLegada', 'BOOTSTRAP' FROM dual
     WHERE EXISTS (SELECT 1 FROM dba_users WHERE username = 'KAWASHI_SPRING_USER')
       AND NOT EXISTS (SELECT 1 FROM KAWASHI_CONTA WHERE USERNAME = 'KAWASHI_SPRING_USER');

    -- Banco que ja tinha contas de API antes deste arquivo existir: cadastra pelo que o proxy
    -- revela (schema terminado em _APP = conta de execucao; schema dono = conta de migracao).
    INSERT INTO KAWASHI_CONTA (USERNAME, TIPO, PERFIL, AMBIENTE, CRIADA_POR)
    SELECT u.username, 'API',
           CASE WHEN MAX(p.client) LIKE '%\_APP' ESCAPE '\' THEN 'Execucao' ELSE 'Migracao' END,
           REGEXP_REPLACE(REGEXP_REPLACE(MAX(p.client), '^KAWASHI_ENV_', ''), '_APP$', ''),
           'BOOTSTRAP'
      FROM dba_users u JOIN dba_proxies p ON p.proxy = u.username
     WHERE u.profile = 'KAWASHI_SERVICE_PROFILE'
       AND NOT EXISTS (SELECT 1 FROM KAWASHI_CONTA c WHERE c.USERNAME = u.username)
     GROUP BY u.username;
    COMMIT;
END;
/
