-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 13 - LOGIN DA APLICACAO COM PASSKEY: SCHEMAS LOGIN E SESSAO, E OS LOGS DE SEGURANCA
-- #########################################################
-- O login da API e SO POR PASSKEY (WebAuthn/FIDO2: digital, rosto ou chave fisica). Nao existe
-- senha: nada para vazar, nada para digitar num site falso. Cada ambiente ganha dois schemas novos,
-- mais duas tabelas no schema de log:
--
--   KAWASHI_ENV_<AMB>_LOGIN   o que e permanente do usuario
--       USUARIO              quem entra: pessoa, e-mail (cifrado pela API) e o "handle" WebAuthn
--       PASSKEY              as chaves publicas cadastradas (a privada nunca sai do aparelho)
--       CONVITE              link de uso unico para cadastrar a primeira passkey (ou uma nova)
--       CODIGO_RECUPERACAO   codigos de uso unico para quem perdeu os aparelhos (so o hash)
--       PARAMETRO_SEGURANCA  os numeros das regras (validade do token, limites...)
--   KAWASHI_ENV_<AMB>_SESSAO  o que expira
--       TOKEN                a sessao: so o SHA-256 do token, validade deslizante com teto
--       DESAFIO              o desafio aleatorio de cada cerimonia WebAuthn (uso unico, 5 min)
--       BLOQUEIO_IP          IPs barrados por excesso de tentativas
--   KAWASHI_ENV_<AMB>_LOG     (ja existia, 11_schema_log.sql)
--       TENTATIVA_LOGIN      toda tentativa, certa ou errada
--       LOG_SEGURANCA        login, logout, passkey cadastrada ou removida, codigo usado...
--                            ENCADEADO por hash, como o LOG_ALTERACAO
--
-- POR QUE AS TABELAS SAO CRIADAS AQUI, e nao pelo Flyway da API (o mesmo motivo do log): quem e
-- dono de uma tabela consegue alterar e apagar tudo nela. Os donos sao schemas em que NINGUEM loga
-- (NO AUTHENTICATION). A API (schema _APP) recebe so o que precisa, e:
--   * so LE os parametros: quem invadir a API nao afrouxa as regras de seguranca;
--   * nao APAGA nada: passkey e codigo sao revogados (marcados), e a limpeza do que venceu e um
--     job do banco;
--   * no log, so insere.
-- A conta de MIGRACAO da API (dona das tabelas de cadastro) nao recebe NADA aqui.
--
-- A ligacao USUARIO.PESSOA_ID -> PESSOA e uma chave estrangeira entre schemas. A PESSOA e criada
-- pelo Flyway da API, DEPOIS deste arquivo (num banco novo); por isso a chave e criada pela
-- procedure SYS.KAWASHI_LIGAR_LOGIN_PESSOA, que este arquivo chama (para os ambientes em que a
-- PESSOA ja existe) e que o afterMigrate.sql da API chama em toda migracao.
--
-- HORA EM UTC, SEMPRE: as colunas de hora sao TIMESTAMP (sem fuso) e tudo e gravado e comparado
-- com SYS_EXTRACT_UTC(SYSTIMESTAMP). Comparar uma coluna TIMESTAMP com SYSTIMESTAMP faz o Oracle
-- interpretar a coluna no fuso da SESSAO de quem consulta: com a API no fuso -05:00, um token
-- vencido continuava valendo por mais 5 horas (achado 31 em infra/docs/bugs-primeiro-teste.md).
--
-- Idempotente: pode ser rodado de novo num banco que ja tem tudo.

-- ---------------------------------------------------------------------------
-- Procedure da chave USUARIO -> PESSOA (precisa existir antes do bloco que a usa)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE KAWASHI_LIGAR_LOGIN_PESSOA (p_ambiente IN VARCHAR2 DEFAULT NULL) AS
    v_quem VARCHAR2(128) := SYS_CONTEXT('USERENV', 'SESSION_USER');
    v_env  VARCHAR2(128);
    v_total NUMBER;
BEGIN
    -- Quem chama de um schema de ambiente (o afterMigrate da API) so liga o PROPRIO ambiente.
    IF v_quem = 'SYS' AND p_ambiente IS NOT NULL THEN
        v_env := 'KAWASHI_ENV_' || UPPER(p_ambiente);
    ELSIF REGEXP_LIKE(v_quem, '^KAWASHI_ENV_[A-Z_]+$') AND v_quem NOT LIKE '%\_APP' ESCAPE '\'
          AND v_quem NOT LIKE '%\_LOG' ESCAPE '\' AND v_quem NOT LIKE '%\_LOGIN' ESCAPE '\'
          AND v_quem NOT LIKE '%\_SESSAO' ESCAPE '\' THEN
        v_env := v_quem;
    ELSE
        RAISE_APPLICATION_ERROR(-20090, 'KAWASHI_LIGAR_LOGIN_PESSOA: chamada so por um schema de ambiente (ou por SYS, com o ambiente).');
    END IF;
    IF NOT REGEXP_LIKE(v_env, '^KAWASHI_ENV_[A-Z_]{2,30}$') THEN
        RAISE_APPLICATION_ERROR(-20091, 'Ambiente invalido.');
    END IF;

    SELECT COUNT(*) INTO v_total FROM dba_tables WHERE owner = v_env AND table_name = 'PESSOA';
    IF v_total = 0 THEN RETURN; END IF;  -- a API ainda nao criou a PESSOA neste ambiente
    SELECT COUNT(*) INTO v_total FROM dba_tables WHERE owner = v_env || '_LOGIN' AND table_name = 'USUARIO';
    IF v_total = 0 THEN RETURN; END IF;

    EXECUTE IMMEDIATE 'GRANT REFERENCES ON ' || v_env || '.PESSOA TO ' || v_env || '_LOGIN';
    SELECT COUNT(*) INTO v_total FROM dba_constraints
     WHERE owner = v_env || '_LOGIN' AND table_name = 'USUARIO' AND constraint_name = 'FK_USUARIO_PESSOA';
    IF v_total = 0 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE ' || v_env || '_LOGIN.USUARIO ADD CONSTRAINT FK_USUARIO_PESSOA '
                       || 'FOREIGN KEY (PESSOA_ID) REFERENCES ' || v_env || '.PESSOA (ID)';
    END IF;
END;
/

DECLARE
    PROCEDURE executar(p_sql VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
    END;

    FUNCTION existe_tabela(p_dono VARCHAR2, p_tabela VARCHAR2) RETURN BOOLEAN IS
        v_total NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_total FROM dba_tables WHERE owner = p_dono AND table_name = p_tabela;
        RETURN v_total > 0;
    END;

    PROCEDURE criar_usuario_dono(p_nome VARCHAR2, p_ts VARCHAR2) IS
        v_total NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_total FROM dba_users WHERE username = p_nome;
        IF v_total = 0 THEN
            executar('CREATE USER ' || p_nome || ' NO AUTHENTICATION DEFAULT TABLESPACE ' || p_ts
                     || ' QUOTA UNLIMITED ON ' || p_ts);
        END IF;
    END;

    PROCEDURE criar_login(p_ambiente VARCHAR2) IS
        v_env    VARCHAR2(60) := 'KAWASHI_ENV_' || p_ambiente;
        v_login  VARCHAR2(60) := v_env || '_LOGIN';
        v_sessao VARCHAR2(60) := v_env || '_SESSAO';
        v_log    VARCHAR2(60) := v_env || '_LOG';
        v_app    VARCHAR2(60) := v_env || '_APP';
        v_ts     VARCHAR2(60) := 'TS_KAWASHI_ENV_' || p_ambiente;
        v_agora  VARCHAR2(40) := 'SYS_EXTRACT_UTC(SYSTIMESTAMP)';
        -- O que entra no hash de cada linha do LOG_SEGURANCA. Igual no trigger e na view.
        v_conteudo VARCHAR2(700) :=
            q'[NVL(#P#HASH_ANTERIOR, '-') || '|' || #P#ORDEM || '|' || #P#EVENTO || '|' || #P#USUARIO_ID || '|' || #P#DETALHE || '|' || #P#IP_ORIGEM || '|' || #P#FEITO_POR || '|' || TO_CHAR(#P#DATA_HORA, 'YYYY-MM-DD"T"HH24:MI:SS.FF6')]';
    BEGIN
        criar_usuario_dono(v_login, v_ts);
        criar_usuario_dono(v_sessao, v_ts);

        -- ======================= LOGIN =======================
        IF NOT existe_tabela(v_login, 'USUARIO') THEN
            executar('CREATE TABLE ' || v_login || '.USUARIO (
                ID             NUMBER GENERATED ALWAYS AS IDENTITY,
                PESSOA_ID      NUMBER          NOT NULL,
                EMAIL_CIFRADO  VARCHAR2(1000)  NOT NULL,
                EMAIL_INDICE   VARCHAR2(64)    NOT NULL,
                HANDLE         VARCHAR2(43)    NOT NULL,
                ATIVO          BOOLEAN         DEFAULT TRUE NOT NULL,
                CRIADO_EM      TIMESTAMP(6)    DEFAULT ' || v_agora || ' NOT NULL,
                ATUALIZADO_EM  TIMESTAMP(6)    DEFAULT ' || v_agora || ' NOT NULL,
                CONSTRAINT PK_USUARIO PRIMARY KEY (ID),
                CONSTRAINT UK_USUARIO_PESSOA UNIQUE (PESSOA_ID),
                CONSTRAINT UK_USUARIO_EMAIL UNIQUE (EMAIL_INDICE),
                CONSTRAINT UK_USUARIO_HANDLE UNIQUE (HANDLE),
                CONSTRAINT CK_USUARIO_EMAIL_CIFRADO CHECK (EMAIL_CIFRADO LIKE ''v1:%'' AND LENGTH(EMAIL_CIFRADO) >= 43),
                CONSTRAINT CK_USUARIO_EMAIL_INDICE CHECK (REGEXP_LIKE(EMAIL_INDICE, ''^[0-9a-f]{64}$'')),
                CONSTRAINT CK_USUARIO_HANDLE CHECK (REGEXP_LIKE(HANDLE, ''^[A-Za-z0-9_-]{43}$'')))');
        END IF;

        IF NOT existe_tabela(v_login, 'PASSKEY') THEN
            executar('CREATE TABLE ' || v_login || '.PASSKEY (
                ID                NUMBER GENERATED ALWAYS AS IDENTITY,
                USUARIO_ID        NUMBER              NOT NULL,
                CREDENCIAL_ID     VARCHAR2(1400)      NOT NULL,
                DADOS_CREDENCIAL  VARCHAR2(4000)      NOT NULL,
                CONTADOR          NUMBER(19)          DEFAULT 0 NOT NULL,
                UV_INICIALIZADO   BOOLEAN             NOT NULL,
                BACKUP_ELEGIVEL   BOOLEAN             NOT NULL,
                BACKUP_FEITO      BOOLEAN             NOT NULL,
                TRANSPORTES       VARCHAR2(200),
                NOME              VARCHAR2(60 CHAR)   NOT NULL,
                CRIADA_EM         TIMESTAMP(6)        DEFAULT ' || v_agora || ' NOT NULL,
                ULTIMO_USO_EM     TIMESTAMP(6),
                REVOGADA_EM       TIMESTAMP(6),
                CONSTRAINT PK_PASSKEY PRIMARY KEY (ID),
                CONSTRAINT UK_PASSKEY_CREDENCIAL UNIQUE (CREDENCIAL_ID),
                CONSTRAINT FK_PASSKEY_USUARIO FOREIGN KEY (USUARIO_ID) REFERENCES ' || v_login || '.USUARIO (ID),
                CONSTRAINT CK_PASSKEY_CREDENCIAL CHECK (REGEXP_LIKE(CREDENCIAL_ID, ''^[A-Za-z0-9_-]+$'')),
                CONSTRAINT CK_PASSKEY_CONTADOR CHECK (CONTADOR >= 0))');
            executar('CREATE INDEX ' || v_login || '.IX_PASSKEY_USUARIO ON ' || v_login || '.PASSKEY (USUARIO_ID, REVOGADA_EM)');
        END IF;

        IF NOT existe_tabela(v_login, 'CONVITE') THEN
            executar('CREATE TABLE ' || v_login || '.CONVITE (
                ID          NUMBER GENERATED ALWAYS AS IDENTITY,
                USUARIO_ID  NUMBER          NOT NULL,
                TOKEN_HASH  VARCHAR2(64)    NOT NULL,
                FINALIDADE  VARCHAR2(20)    NOT NULL,
                CRIADO_POR  VARCHAR2(128)   NOT NULL,
                CRIADO_EM   TIMESTAMP(6)    DEFAULT ' || v_agora || ' NOT NULL,
                EXPIRA_EM   TIMESTAMP(6)    NOT NULL,
                USADO_EM    TIMESTAMP(6),
                CONSTRAINT PK_CONVITE PRIMARY KEY (ID),
                CONSTRAINT UK_CONVITE_TOKEN UNIQUE (TOKEN_HASH),
                CONSTRAINT FK_CONVITE_USUARIO FOREIGN KEY (USUARIO_ID) REFERENCES ' || v_login || '.USUARIO (ID),
                CONSTRAINT CK_CONVITE_TOKEN CHECK (REGEXP_LIKE(TOKEN_HASH, ''^[0-9a-f]{64}$'')),
                CONSTRAINT CK_CONVITE_FINALIDADE CHECK (FINALIDADE IN (''CADASTRO'', ''NOVA_PASSKEY'')),
                CONSTRAINT CK_CONVITE_VALIDADE CHECK (EXPIRA_EM > CRIADO_EM))');
            executar('CREATE INDEX ' || v_login || '.IX_CONVITE_USUARIO ON ' || v_login || '.CONVITE (USUARIO_ID)');
        END IF;

        IF NOT existe_tabela(v_login, 'CODIGO_RECUPERACAO') THEN
            executar('CREATE TABLE ' || v_login || '.CODIGO_RECUPERACAO (
                ID           NUMBER GENERATED ALWAYS AS IDENTITY,
                USUARIO_ID   NUMBER          NOT NULL,
                CODIGO_HASH  VARCHAR2(64)    NOT NULL,
                CRIADO_EM    TIMESTAMP(6)    DEFAULT ' || v_agora || ' NOT NULL,
                USADO_EM     TIMESTAMP(6),
                REVOGADO_EM  TIMESTAMP(6),
                CONSTRAINT PK_CODIGO_RECUPERACAO PRIMARY KEY (ID),
                CONSTRAINT UK_CODIGO_RECUPERACAO_HASH UNIQUE (CODIGO_HASH),
                CONSTRAINT FK_CODIGO_RECUPERACAO_USUARIO FOREIGN KEY (USUARIO_ID) REFERENCES ' || v_login || '.USUARIO (ID),
                CONSTRAINT CK_CODIGO_RECUPERACAO_HASH CHECK (REGEXP_LIKE(CODIGO_HASH, ''^[0-9a-f]{64}$'')))');
            executar('CREATE INDEX ' || v_login || '.IX_CODIGO_RECUPERACAO_USUARIO ON ' || v_login || '.CODIGO_RECUPERACAO (USUARIO_ID)');
        END IF;

        IF NOT existe_tabela(v_login, 'PARAMETRO_SEGURANCA') THEN
            executar('CREATE TABLE ' || v_login || '.PARAMETRO_SEGURANCA (
                CHAVE           VARCHAR2(40)        NOT NULL,
                VALOR           NUMBER              NOT NULL,
                DESCRICAO       VARCHAR2(200 CHAR)  NOT NULL,
                ATUALIZADO_POR  VARCHAR2(128),
                ATUALIZADO_EM   TIMESTAMP(6)        DEFAULT ' || v_agora || ' NOT NULL,
                CONSTRAINT PK_PARAMETRO_SEGURANCA PRIMARY KEY (CHAVE),
                CONSTRAINT CK_PARAMETRO_VALOR CHECK (VALOR > 0))');
            FOR p IN (SELECT 'TOKEN_MINUTOS' c, 15 v, 'Validade deslizante do token: cada uso empurra o vencimento para esta quantidade de minutos a frente.' d FROM dual
                      UNION ALL SELECT 'TOKEN_TETO_HORAS', 8, 'Teto da sessao: horas depois do login em que o token vence, mesmo em uso.' FROM dual
                      UNION ALL SELECT 'SESSOES_MAXIMAS', 3, 'Sessoes ativas por usuario; a seguinte derruba a mais antiga.' FROM dual
                      UNION ALL SELECT 'IP_MAX_FALHAS', 10, 'Logins com falha do mesmo IP, dentro da janela, que bloqueiam o IP.' FROM dual
                      UNION ALL SELECT 'IP_JANELA_MINUTOS', 10, 'Janela, em minutos, em que as falhas do mesmo IP sao contadas.' FROM dual
                      UNION ALL SELECT 'IP_BLOQUEIO_MINUTOS', 60, 'Minutos de bloqueio do IP.' FROM dual
                      UNION ALL SELECT 'DESAFIO_MINUTOS', 5, 'Validade do desafio de uma cerimonia de passkey (cadastro ou login).' FROM dual
                      UNION ALL SELECT 'CONVITE_HORAS', 24, 'Validade do convite de uso unico para cadastrar uma passkey.' FROM dual
                      UNION ALL SELECT 'CODIGOS_RECUPERACAO', 10, 'Quantos codigos de recuperacao o usuario recebe de uma vez.' FROM dual
                      UNION ALL SELECT 'PASSKEYS_MAXIMAS', 10, 'Passkeys ativas por usuario.' FROM dual) LOOP
                executar('INSERT INTO ' || v_login || '.PARAMETRO_SEGURANCA (CHAVE, VALOR, DESCRICAO, ATUALIZADO_POR) VALUES ('''
                         || p.c || ''', ' || p.v || ', ''' || p.d || ''', ''INSTALACAO'')');
            END LOOP;
        END IF;

        -- ======================= SESSAO =======================
        executar('GRANT REFERENCES ON ' || v_login || '.USUARIO TO ' || v_sessao);
        executar('GRANT REFERENCES ON ' || v_login || '.PASSKEY TO ' || v_sessao);
        IF NOT existe_tabela(v_sessao, 'TOKEN') THEN
            executar('CREATE TABLE ' || v_sessao || '.TOKEN (
                ID                  NUMBER GENERATED ALWAYS AS IDENTITY,
                USUARIO_ID          NUMBER          NOT NULL,
                PASSKEY_ID          NUMBER,
                TOKEN_HASH          VARCHAR2(64)    NOT NULL,
                ESCOPO              VARCHAR2(20)    DEFAULT ''COMPLETO'' NOT NULL,
                CRIADO_EM           TIMESTAMP(6)    DEFAULT ' || v_agora || ' NOT NULL,
                ULTIMO_USO_EM       TIMESTAMP(6)    DEFAULT ' || v_agora || ' NOT NULL,
                EXPIRA_EM           TIMESTAMP(6)    NOT NULL,
                EXPIRA_ABSOLUTO_EM  TIMESTAMP(6)    NOT NULL,
                REVOGADO_EM         TIMESTAMP(6),
                MOTIVO_REVOGACAO    VARCHAR2(20),
                IP_ORIGEM           VARCHAR2(45),
                CONSTRAINT PK_TOKEN PRIMARY KEY (ID),
                CONSTRAINT UK_TOKEN_HASH UNIQUE (TOKEN_HASH),
                CONSTRAINT FK_TOKEN_USUARIO FOREIGN KEY (USUARIO_ID) REFERENCES ' || v_login || '.USUARIO (ID),
                CONSTRAINT FK_TOKEN_PASSKEY FOREIGN KEY (PASSKEY_ID) REFERENCES ' || v_login || '.PASSKEY (ID),
                CONSTRAINT CK_TOKEN_HASH CHECK (REGEXP_LIKE(TOKEN_HASH, ''^[0-9a-f]{64}$'')),
                CONSTRAINT CK_TOKEN_ESCOPO CHECK (ESCOPO IN (''COMPLETO'', ''CADASTRAR_PASSKEY'')),
                CONSTRAINT CK_TOKEN_VALIDADE CHECK (EXPIRA_EM > CRIADO_EM AND EXPIRA_EM <= EXPIRA_ABSOLUTO_EM),
                CONSTRAINT CK_TOKEN_REVOGACAO CHECK ((REVOGADO_EM IS NULL AND MOTIVO_REVOGACAO IS NULL)
                    OR (REVOGADO_EM IS NOT NULL AND MOTIVO_REVOGACAO IN (''LOGOUT'', ''SAIR_DE_TODOS'', ''PASSKEY_REMOVIDA'',
                        ''LIMITE_SESSOES'', ''USUARIO_DESLIGADO'', ''RECUPERACAO'', ''SUSPEITA''))))');
            executar('CREATE INDEX ' || v_sessao || '.IX_TOKEN_USUARIO ON ' || v_sessao || '.TOKEN (USUARIO_ID, REVOGADO_EM)');
            executar('CREATE INDEX ' || v_sessao || '.IX_TOKEN_PASSKEY ON ' || v_sessao || '.TOKEN (PASSKEY_ID)');
            executar('CREATE INDEX ' || v_sessao || '.IX_TOKEN_EXPIRA ON ' || v_sessao || '.TOKEN (EXPIRA_ABSOLUTO_EM)');
        END IF;

        IF NOT existe_tabela(v_sessao, 'DESAFIO') THEN
            executar('CREATE TABLE ' || v_sessao || '.DESAFIO (
                ID          NUMBER GENERATED ALWAYS AS IDENTITY,
                VALOR       VARCHAR2(43)    NOT NULL,
                FINALIDADE  VARCHAR2(20)    NOT NULL,
                USUARIO_ID  NUMBER,
                CRIADO_EM   TIMESTAMP(6)    DEFAULT ' || v_agora || ' NOT NULL,
                EXPIRA_EM   TIMESTAMP(6)    NOT NULL,
                USADO_EM    TIMESTAMP(6),
                CONSTRAINT PK_DESAFIO PRIMARY KEY (ID),
                CONSTRAINT UK_DESAFIO_VALOR UNIQUE (VALOR),
                CONSTRAINT FK_DESAFIO_USUARIO FOREIGN KEY (USUARIO_ID) REFERENCES ' || v_login || '.USUARIO (ID),
                CONSTRAINT CK_DESAFIO_VALOR CHECK (REGEXP_LIKE(VALOR, ''^[A-Za-z0-9_-]{43}$'')),
                CONSTRAINT CK_DESAFIO_FINALIDADE CHECK (FINALIDADE IN (''LOGIN'', ''CADASTRO'')),
                CONSTRAINT CK_DESAFIO_CADASTRO CHECK (FINALIDADE = ''LOGIN'' OR USUARIO_ID IS NOT NULL),
                CONSTRAINT CK_DESAFIO_VALIDADE CHECK (EXPIRA_EM > CRIADO_EM))');
            executar('CREATE INDEX ' || v_sessao || '.IX_DESAFIO_EXPIRA ON ' || v_sessao || '.DESAFIO (EXPIRA_EM)');
        END IF;

        IF NOT existe_tabela(v_sessao, 'BLOQUEIO_IP') THEN
            executar('CREATE TABLE ' || v_sessao || '.BLOQUEIO_IP (
                IP             VARCHAR2(45)       NOT NULL,
                BLOQUEADO_ATE  TIMESTAMP(6)       NOT NULL,
                MOTIVO         VARCHAR2(100 CHAR) NOT NULL,
                CRIADO_EM      TIMESTAMP(6)       DEFAULT ' || v_agora || ' NOT NULL,
                CONSTRAINT PK_BLOQUEIO_IP PRIMARY KEY (IP))');
        END IF;

        -- ======================= LOG =======================
        IF NOT existe_tabela(v_log, 'TENTATIVA_LOGIN') THEN
            executar('CREATE TABLE ' || v_log || '.TENTATIVA_LOGIN (
                ID          NUMBER GENERATED ALWAYS AS IDENTITY,
                METODO      VARCHAR2(20)    NOT NULL,
                USUARIO_ID  NUMBER,
                IP_ORIGEM   VARCHAR2(45),
                SUCESSO     BOOLEAN         NOT NULL,
                MOTIVO      VARCHAR2(30),
                DATA_HORA   TIMESTAMP(6)    DEFAULT ' || v_agora || ' NOT NULL,
                CONSTRAINT PK_TENTATIVA_LOGIN PRIMARY KEY (ID),
                CONSTRAINT CK_TENTATIVA_METODO CHECK (METODO IN (''PASSKEY'', ''CODIGO_RECUPERACAO'', ''CONVITE'')),
                CONSTRAINT CK_TENTATIVA_MOTIVO CHECK (MOTIVO IS NULL OR MOTIVO IN (''CREDENCIAL_DESCONHECIDA'',
                    ''VERIFICACAO_FALHOU'', ''DESAFIO_INVALIDO'', ''USUARIO_INATIVO'', ''IP_BLOQUEADO'', ''CODIGO_INVALIDO'',
                    ''CONVITE_INVALIDO'', ''CONTADOR_SUSPEITO'')))');
            executar('CREATE INDEX ' || v_log || '.IX_TENTATIVA_IP ON ' || v_log || '.TENTATIVA_LOGIN (IP_ORIGEM, DATA_HORA)');
        END IF;

        IF NOT existe_tabela(v_log, 'LOG_SEGURANCA') THEN
            executar('CREATE TABLE ' || v_log || '.LOG_SEGURANCA (
                ID             NUMBER GENERATED ALWAYS AS IDENTITY,
                ORDEM          NUMBER              NOT NULL,
                EVENTO         VARCHAR2(40)        NOT NULL,
                USUARIO_ID     NUMBER,
                DETALHE        VARCHAR2(500 CHAR),
                IP_ORIGEM      VARCHAR2(45),
                FEITO_POR      VARCHAR2(128)       NOT NULL,
                DATA_HORA      TIMESTAMP(6)        DEFAULT ' || v_agora || ' NOT NULL,
                HASH_ANTERIOR  VARCHAR2(64),
                HASH           VARCHAR2(64)        NOT NULL,
                CONSTRAINT PK_LOG_SEGURANCA PRIMARY KEY (ID),
                CONSTRAINT UK_LOG_SEGURANCA_ORDEM UNIQUE (ORDEM),
                CONSTRAINT CK_LOG_SEGURANCA_EVENTO CHECK (EVENTO IN (''LOGIN'', ''LOGOUT'', ''SAIR_DE_TODOS'',
                    ''PASSKEY_CADASTRADA'', ''PASSKEY_REMOVIDA'', ''CODIGOS_GERADOS'', ''CODIGO_USADO'', ''CONVITE_CRIADO'',
                    ''CONVITE_USADO'', ''IP_BLOQUEADO'', ''SESSAO_ENCERRADA'', ''USUARIO_CRIADO'', ''PARAMETRO_ALTERADO'',
                    ''CONTADOR_SUSPEITO'')))');
            executar('CREATE INDEX ' || v_log || '.IX_LOG_SEGURANCA_USUARIO ON ' || v_log || '.LOG_SEGURANCA (USUARIO_ID, DATA_HORA)');
        END IF;
        executar('MERGE INTO ' || v_log || '.LOG_CADEIA c USING (SELECT ''LOG_SEGURANCA'' t FROM dual) n ON (c.TABELA = n.t)
                  WHEN NOT MATCHED THEN INSERT (TABELA) VALUES (n.t)');

        -- Hora do servidor (UTC) na tentativa; numeracao, hora e encadeamento no LOG_SEGURANCA.
        executar('CREATE OR REPLACE TRIGGER ' || v_log || '.TENTATIVA_LOGIN_HORA_TRG
            BEFORE INSERT ON ' || v_log || '.TENTATIVA_LOGIN
            FOR EACH ROW
            BEGIN
                :NEW.DATA_HORA := ' || v_agora || ';
            END;');
        executar('CREATE OR REPLACE TRIGGER ' || v_log || '.LOG_SEGURANCA_CADEIA_TRG
            BEFORE INSERT ON ' || v_log || '.LOG_SEGURANCA
            FOR EACH ROW
            DECLARE
                v_hash RAW(32);
            BEGIN
                SELECT ULTIMA_ORDEM + 1, ULTIMO_HASH INTO :NEW.ORDEM, :NEW.HASH_ANTERIOR
                  FROM ' || v_log || '.LOG_CADEIA WHERE TABELA = ''LOG_SEGURANCA'' FOR UPDATE;
                :NEW.DATA_HORA := ' || v_agora || ';
                SELECT STANDARD_HASH(' || REPLACE(v_conteudo, '#P#', ':NEW.') || ', ''SHA256'') INTO v_hash FROM DUAL;
                :NEW.HASH := LOWER(RAWTOHEX(v_hash));
                UPDATE ' || v_log || '.LOG_CADEIA SET ULTIMA_ORDEM = :NEW.ORDEM, ULTIMO_HASH = :NEW.HASH
                 WHERE TABELA = ''LOG_SEGURANCA'';
            END;');
        executar('CREATE OR REPLACE VIEW ' || v_log || '.V_LOG_SEGURANCA_QUEBRAS AS
            SELECT ORDEM, PROBLEMA FROM (
                SELECT l.ORDEM,
                       CASE
                           WHEN l.ORDEM <> NVL(LAG(l.ORDEM) OVER (ORDER BY l.ORDEM), 0) + 1
                               THEN ''falta linha antes desta (buraco na numeracao)''
                           WHEN NVL(l.HASH_ANTERIOR, ''-'') <> NVL(LAG(l.HASH) OVER (ORDER BY l.ORDEM), ''-'')
                               THEN ''nao encadeia com a linha anterior''
                           WHEN l.HASH <> LOWER(RAWTOHEX(STANDARD_HASH(' || REPLACE(v_conteudo, '#P#', 'l.') || ', ''SHA256'')))
                               THEN ''conteudo alterado depois de gravado''
                       END AS PROBLEMA
                  FROM ' || v_log || '.LOG_SEGURANCA l)
             WHERE PROBLEMA IS NOT NULL
            UNION ALL
            SELECT c.ULTIMA_ORDEM, ''faltam linhas no fim (a ultima gravada nao esta mais na tabela)''
              FROM ' || v_log || '.LOG_CADEIA c
             WHERE c.TABELA = ''LOG_SEGURANCA''
               AND c.ULTIMA_ORDEM <> (SELECT NVL(MAX(ORDEM), 0) FROM ' || v_log || '.LOG_SEGURANCA)');

        -- Mudanca de parametro de seguranca vai SOZINHA para o LOG_SEGURANCA: afrouxar uma regra
        -- nunca passa despercebido, nem quando e feito direto no banco.
        executar('GRANT INSERT ON ' || v_log || '.LOG_SEGURANCA TO ' || v_login);
        executar('CREATE OR REPLACE TRIGGER ' || v_login || '.PARAMETRO_SEGURANCA_LOG_TRG
            BEFORE UPDATE OR INSERT OR DELETE ON ' || v_login || '.PARAMETRO_SEGURANCA
            FOR EACH ROW
            BEGIN
                IF UPDATING OR INSERTING THEN
                    :NEW.ATUALIZADO_EM := ' || v_agora || ';
                    :NEW.ATUALIZADO_POR := NVL(SYS_CONTEXT(''USERENV'', ''PROXY_USER''), SYS_CONTEXT(''USERENV'', ''SESSION_USER''));
                END IF;
                IF UPDATING THEN
                    INSERT INTO ' || v_log || '.LOG_SEGURANCA (ORDEM, EVENTO, DETALHE, FEITO_POR, HASH)
                    VALUES (0, ''PARAMETRO_ALTERADO'', :OLD.CHAVE || '': '' || :OLD.VALOR || '' -> '' || :NEW.VALOR, :NEW.ATUALIZADO_POR, ''-'');
                ELSIF DELETING THEN
                    INSERT INTO ' || v_log || '.LOG_SEGURANCA (ORDEM, EVENTO, DETALHE, FEITO_POR, HASH)
                    VALUES (0, ''PARAMETRO_ALTERADO'', :OLD.CHAVE || '': apagado (era '' || :OLD.VALOR || '')'',
                            NVL(SYS_CONTEXT(''USERENV'', ''PROXY_USER''), SYS_CONTEXT(''USERENV'', ''SESSION_USER'')), ''-'');
                END IF;
            END;');

        -- ======================= PERMISSOES =======================
        -- So o schema de EXECUCAO da API (_APP), e nenhum DELETE. O schema do ambiente (conta de
        -- migracao e pessoas) nao recebe nada.
        executar('GRANT SELECT, INSERT, UPDATE ON ' || v_login || '.USUARIO TO ' || v_app);
        executar('GRANT SELECT, INSERT, UPDATE ON ' || v_login || '.PASSKEY TO ' || v_app);
        executar('GRANT SELECT, INSERT, UPDATE ON ' || v_login || '.CONVITE TO ' || v_app);
        executar('GRANT SELECT, INSERT, UPDATE ON ' || v_login || '.CODIGO_RECUPERACAO TO ' || v_app);
        executar('GRANT SELECT ON ' || v_login || '.PARAMETRO_SEGURANCA TO ' || v_app);
        executar('GRANT SELECT, INSERT, UPDATE ON ' || v_sessao || '.TOKEN TO ' || v_app);
        executar('GRANT SELECT, INSERT, UPDATE ON ' || v_sessao || '.DESAFIO TO ' || v_app);
        executar('GRANT SELECT, INSERT, UPDATE ON ' || v_sessao || '.BLOQUEIO_IP TO ' || v_app);
        executar('GRANT INSERT, SELECT ON ' || v_log || '.TENTATIVA_LOGIN TO ' || v_app);
        executar('GRANT INSERT, SELECT ON ' || v_log || '.LOG_SEGURANCA TO ' || v_app);
        executar('GRANT SELECT ON ' || v_log || '.V_LOG_SEGURANCA_QUEBRAS TO ' || v_app);
        -- O afterMigrate da API (conta de migracao, como dona da PESSOA) chama a ligacao da chave.
        executar('GRANT EXECUTE ON SYS.KAWASHI_LIGAR_LOGIN_PESSOA TO ' || v_env);
    END;
BEGIN
    criar_login('TESTE_DEV');
    criar_login('TESTE_INFRA');
    criar_login('DEV');
    criar_login('INFRA');
    criar_login('HOMOLOG');
    criar_login('PROD');
    COMMIT;
    -- Ambientes em que a API ja criou a PESSOA: liga a chave agora.
    FOR a IN (SELECT 'TESTE_DEV' amb FROM dual UNION ALL SELECT 'TESTE_INFRA' FROM dual UNION ALL SELECT 'DEV' FROM dual
              UNION ALL SELECT 'INFRA' FROM dual UNION ALL SELECT 'HOMOLOG' FROM dual UNION ALL SELECT 'PROD' FROM dual) LOOP
        KAWASHI_LIGAR_LOGIN_PESSOA(a.amb);
    END LOOP;
END;
/

-- ---------------------------------------------------------------------------
-- Limpeza diaria do que ja venceu (o schema SESSAO e o lugar do que expira).
-- A API nao apaga nada: quem apaga e este job do banco.
-- Token: 7 dias depois do teto. Desafio: 1 dia depois de vencer. Bloqueio de IP: 1 dia depois.
-- (A historia continua no LOG_SEGURANCA e na TENTATIVA_LOGIN.)
-- ---------------------------------------------------------------------------
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'KAWASHI_LIMPEZA_SESSAO_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => q'[BEGIN
            FOR u IN (SELECT username FROM dba_users WHERE username LIKE 'KAWASHI\_ENV\_%\_SESSAO' ESCAPE '\') LOOP
                EXECUTE IMMEDIATE 'DELETE FROM ' || u.username || '.TOKEN WHERE EXPIRA_ABSOLUTO_EM < SYS_EXTRACT_UTC(SYSTIMESTAMP) - INTERVAL ''7'' DAY';
                EXECUTE IMMEDIATE 'DELETE FROM ' || u.username || '.DESAFIO WHERE EXPIRA_EM < SYS_EXTRACT_UTC(SYSTIMESTAMP) - INTERVAL ''1'' DAY';
                EXECUTE IMMEDIATE 'DELETE FROM ' || u.username || '.BLOQUEIO_IP WHERE BLOQUEADO_ATE < SYS_EXTRACT_UTC(SYSTIMESTAMP) - INTERVAL ''1'' DAY';
            END LOOP;
            COMMIT;
        END;]',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=DAILY;BYHOUR=3;BYMINUTE=30',
        enabled         => TRUE,
        comments        => 'Kawashi: apaga sessoes, desafios e bloqueios de IP vencidos (13_schema_login.sql).');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -27477 THEN RAISE; END IF;  -- o job ja existe
END;
/
