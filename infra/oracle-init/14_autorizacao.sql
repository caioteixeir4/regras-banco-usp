-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 14 - AUTORIZACAO MULTIEMPRESA: PERFIS, PERMISSOES E O VINCULO DO USUARIO COM CADA EMPRESA
-- #########################################################
-- O login (13) diz QUEM e o usuario. Este passo diz O QUE ele pode fazer e EM QUAIS EMPRESAS.
-- Tudo no schema KAWASHI_ENV_<AMB>_LOGIN, mais um log no schema de log:
--
--   ADMIN_PLATAFORMA   a equipe da Kawashi: cria empresa nova e o primeiro administrador dela.
--                      Concedido so por script (infra/scripts/conceder-admin-plataforma.ps1); a API
--                      so le. NAO da acesso aos dados das empresas.
--   PERMISSAO          a lista fixa de acoes que a API protege. EXCLUSIVA_ADMIN: so o perfil
--                      ADMINISTRADOR pode ter (dar cargo, gerenciar usuarios).
--   PERFIL             os cargos DE CADA EMPRESA. O ADMINISTRADOR (FIXO) tem todas as permissoes,
--                      implicitamente: o banco recusa gravar ou tirar permissao dele, e recusa
--                      apaga-lo, desativa-lo ou renomea-lo.
--   PERFIL_PERMISSAO   as permissoes dos outros perfis. Tirar uma permissao e DESATIVAR a linha
--                      (a API nao tem DELETE em nada desta etapa).
--   USUARIO_EMPRESA    em quais empresas o usuario entra e com qual cargo em cada uma.
--   LOG_PERMISSAO      (schema de log) quem mudou o cargo de quem, quando, de qual perfil para
--                      qual; permissoes postas ou tiradas. Gravado por GATILHO, nao pela API (a API
--                      nem tem INSERT nele): nem mudanca feita direto no banco escapa. Encadeado por
--                      hash, como o LOG_SEGURANCA.
--   TOKEN.EMPRESA_ID   (coluna nova no schema de sessao) em qual empresa a sessao trabalha.
--
-- REGRAS GARANTIDAS PELO BANCO (alem da API):
--   * toda empresa com vinculos tem sempre PELO MENOS UM ADMINISTRADOR ATIVO: a troca ou a
--     desativacao que deixaria a empresa sem nenhum e recusada (com trava por empresa, para dois
--     administradores nao se rebaixarem ao mesmo tempo);
--   * o perfil do vinculo e da MESMA empresa (chave estrangeira composta);
--   * so o ADMINISTRADOR tem as permissoes exclusivas;
--   * quem faz cada mudanca fica registrado: pela API, "USUARIO:<id>" (ou "SCRIPT:<nome>" nos scripts; obrigatorio: sem ele a
--     gravacao e recusada); direto no banco, a conta de quem mudou.
--
-- As chaves para EMPRESA e PESSOA (criadas pelo Flyway da API) e a visao V_USUARIO_ACESSOS sao
-- feitas pela procedure SYS.KAWASHI_LIGAR_AUTORIZACAO, chamada aqui e pelo afterMigrate.sql da API.
--
-- Idempotente: pode ser rodado de novo num banco que ja tem tudo.

-- ---------------------------------------------------------------------------
-- Procedure das chaves para EMPRESA e PESSOA e da visao V_USUARIO_ACESSOS
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE KAWASHI_LIGAR_AUTORIZACAO (p_ambiente IN VARCHAR2 DEFAULT NULL) AS
    v_quem  VARCHAR2(128) := SYS_CONTEXT('USERENV', 'SESSION_USER');
    v_env   VARCHAR2(128);
    v_total NUMBER;

    PROCEDURE ligar(p_dono VARCHAR2, p_tabela VARCHAR2, p_nome VARCHAR2, p_coluna VARCHAR2) IS
    BEGIN
        SELECT COUNT(*) INTO v_total FROM dba_constraints WHERE owner = p_dono AND constraint_name = p_nome;
        IF v_total = 0 THEN
            EXECUTE IMMEDIATE 'ALTER TABLE ' || p_dono || '.' || p_tabela || ' ADD CONSTRAINT ' || p_nome
                           || ' FOREIGN KEY (' || p_coluna || ') REFERENCES ' || v_env || '.EMPRESA (ID)';
        END IF;
    END;
BEGIN
    -- Quem chama de um schema de ambiente (o afterMigrate da API) so liga o PROPRIO ambiente.
    IF v_quem = 'SYS' AND p_ambiente IS NOT NULL THEN
        v_env := 'KAWASHI_ENV_' || UPPER(p_ambiente);
    ELSIF REGEXP_LIKE(v_quem, '^KAWASHI_ENV_[A-Z_]+$') AND v_quem NOT LIKE '%\_APP' ESCAPE '\'
          AND v_quem NOT LIKE '%\_LOG' ESCAPE '\' AND v_quem NOT LIKE '%\_LOGIN' ESCAPE '\'
          AND v_quem NOT LIKE '%\_SESSAO' ESCAPE '\' THEN
        v_env := v_quem;
    ELSE
        RAISE_APPLICATION_ERROR(-20090, 'KAWASHI_LIGAR_AUTORIZACAO: chamada so por um schema de ambiente (ou por SYS, com o ambiente).');
    END IF;
    IF NOT REGEXP_LIKE(v_env, '^KAWASHI_ENV_[A-Z_]{2,30}$') THEN
        RAISE_APPLICATION_ERROR(-20091, 'Ambiente invalido.');
    END IF;

    SELECT COUNT(*) INTO v_total FROM dba_tables WHERE owner = v_env AND table_name IN ('EMPRESA', 'PESSOA');
    IF v_total < 2 THEN RETURN; END IF;  -- a API ainda nao criou os cadastros neste ambiente
    SELECT COUNT(*) INTO v_total FROM dba_tables WHERE owner = v_env || '_LOGIN' AND table_name = 'USUARIO_EMPRESA';
    IF v_total = 0 THEN RETURN; END IF;

    EXECUTE IMMEDIATE 'GRANT REFERENCES ON ' || v_env || '.EMPRESA TO ' || v_env || '_LOGIN';
    EXECUTE IMMEDIATE 'GRANT REFERENCES ON ' || v_env || '.EMPRESA TO ' || v_env || '_SESSAO';
    ligar(v_env || '_LOGIN', 'PERFIL', 'FK_PERFIL_EMPRESA', 'EMPRESA_ID');
    ligar(v_env || '_LOGIN', 'USUARIO_EMPRESA', 'FK_USUARIO_EMPRESA_EMPRESA', 'EMPRESA_ID');
    ligar(v_env || '_SESSAO', 'TOKEN', 'FK_TOKEN_EMPRESA', 'EMPRESA_ID');

    -- O painel dos usuarios le o nome e o cargo da PESSOA. O dono da visao (o schema _LOGIN)
    -- precisa ler a PESSOA com direito de repassar, para a API poder ler a visao.
    EXECUTE IMMEDIATE 'GRANT SELECT ON ' || v_env || '.PESSOA TO ' || v_env || '_LOGIN WITH GRANT OPTION';
    EXECUTE IMMEDIATE 'CREATE OR REPLACE VIEW ' || v_env || '_LOGIN.V_USUARIO_ACESSOS AS
        SELECT u.ID AS USUARIO_ID, p.NOME, p.CARGO, ue.EMPRESA_ID, pf.NOME AS PERFIL,
               (u.ATIVO AND ue.ATIVO) AS ATIVO,
               (SELECT COUNT(*) FROM ' || v_env || '_LOGIN.PASSKEY k WHERE k.USUARIO_ID = u.ID AND k.REVOGADA_EM IS NULL) AS PASSKEYS_ATIVAS,
               (SELECT MAX(k.ULTIMO_USO_EM) FROM ' || v_env || '_LOGIN.PASSKEY k WHERE k.USUARIO_ID = u.ID) AS ULTIMO_LOGIN_EM
          FROM ' || v_env || '_LOGIN.USUARIO u
          JOIN ' || v_env || '.PESSOA p ON p.ID = u.PESSOA_ID
          JOIN ' || v_env || '_LOGIN.USUARIO_EMPRESA ue ON ue.USUARIO_ID = u.ID
          JOIN ' || v_env || '_LOGIN.PERFIL pf ON pf.ID = ue.PERFIL_ID';
    EXECUTE IMMEDIATE 'GRANT SELECT ON ' || v_env || '_LOGIN.V_USUARIO_ACESSOS TO ' || v_env || '_APP';
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

    FUNCTION existe_coluna(p_dono VARCHAR2, p_tabela VARCHAR2, p_coluna VARCHAR2) RETURN BOOLEAN IS
        v_total NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_total FROM dba_tab_columns WHERE owner = p_dono AND table_name = p_tabela AND column_name = p_coluna;
        RETURN v_total > 0;
    END;

    -- Troca um CHECK pela versao nova (idempotente: apaga se existir e cria de novo).
    PROCEDURE trocar_check(p_dono VARCHAR2, p_tabela VARCHAR2, p_nome VARCHAR2, p_regra VARCHAR2) IS
        v_total NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_total FROM dba_constraints WHERE owner = p_dono AND constraint_name = p_nome;
        IF v_total > 0 THEN
            executar('ALTER TABLE ' || p_dono || '.' || p_tabela || ' DROP CONSTRAINT ' || p_nome);
        END IF;
        executar('ALTER TABLE ' || p_dono || '.' || p_tabela || ' ADD CONSTRAINT ' || p_nome || ' CHECK (' || p_regra || ')');
    END;

    PROCEDURE criar_autorizacao(p_ambiente VARCHAR2) IS
        v_env    VARCHAR2(60) := 'KAWASHI_ENV_' || p_ambiente;
        v_login  VARCHAR2(60) := v_env || '_LOGIN';
        v_sessao VARCHAR2(60) := v_env || '_SESSAO';
        v_log    VARCHAR2(60) := v_env || '_LOG';
        v_app    VARCHAR2(60) := v_env || '_APP';
        v_agora  VARCHAR2(40) := 'SYS_EXTRACT_UTC(SYSTIMESTAMP)';
        -- O que entra no hash de cada linha do LOG_PERMISSAO. Igual no trigger e na view.
        v_conteudo VARCHAR2(800) :=
            q'[NVL(#P#HASH_ANTERIOR, '-') || '|' || #P#ORDEM || '|' || #P#EVENTO || '|' || #P#EMPRESA_ID || '|' || #P#USUARIO_ID || '|' || #P#PERFIL_ANTERIOR || '|' || #P#PERFIL_NOVO || '|' || #P#PERMISSAO || '|' || #P#FEITO_POR || '|' || TO_CHAR(#P#DATA_HORA, 'YYYY-MM-DD"T"HH24:MI:SS.FF6')]';
        -- Quem fez: pela API (schema _APP), a API TEM de informar "USUARIO:<id>"; direto no banco,
        -- vale a conta de quem esta conectado (a pessoa, quando entra por proxy).
        v_quem VARCHAR2(800) :=
            'IF SYS_CONTEXT(''USERENV'', ''SESSION_USER'') = ''' || v_app || ''' THEN
                IF :NEW.ATUALIZADO_POR IS NULL OR NOT REGEXP_LIKE(:NEW.ATUALIZADO_POR, ''^(USUARIO:[0-9]+|SCRIPT:[A-Z_]+)$'') THEN
                    RAISE_APPLICATION_ERROR(-20104, ''A API precisa informar quem fez a mudanca (ATUALIZADO_POR = USUARIO:<id> ou SCRIPT:<nome>).'');
                END IF;
            ELSE
                :NEW.ATUALIZADO_POR := NVL(SYS_CONTEXT(''USERENV'', ''PROXY_USER''), SYS_CONTEXT(''USERENV'', ''SESSION_USER''));
            END IF;';
    BEGIN
        -- ======================= TABELAS =======================
        IF NOT existe_tabela(v_login, 'ADMIN_PLATAFORMA') THEN
            executar('CREATE TABLE ' || v_login || '.ADMIN_PLATAFORMA (
                USUARIO_ID     NUMBER              NOT NULL,
                CONCEDIDO_POR  VARCHAR2(128)       NOT NULL,
                MOTIVO         VARCHAR2(200 CHAR)  NOT NULL,
                CONCEDIDO_EM   TIMESTAMP(6)        DEFAULT ' || v_agora || ' NOT NULL,
                CONSTRAINT PK_ADMIN_PLATAFORMA PRIMARY KEY (USUARIO_ID),
                CONSTRAINT FK_ADMIN_PLATAFORMA_USUARIO FOREIGN KEY (USUARIO_ID) REFERENCES ' || v_login || '.USUARIO (ID))');
        END IF;

        IF NOT existe_tabela(v_login, 'PERMISSAO') THEN
            executar('CREATE TABLE ' || v_login || '.PERMISSAO (
                ID               NUMBER GENERATED ALWAYS AS IDENTITY,
                CODIGO           VARCHAR2(60)        NOT NULL,
                DESCRICAO        VARCHAR2(200 CHAR)  NOT NULL,
                EXCLUSIVA_ADMIN  BOOLEAN             DEFAULT FALSE NOT NULL,
                CONSTRAINT PK_PERMISSAO PRIMARY KEY (ID),
                CONSTRAINT UK_PERMISSAO_CODIGO UNIQUE (CODIGO),
                CONSTRAINT CK_PERMISSAO_CODIGO CHECK (REGEXP_LIKE(CODIGO, ''^[A-Z_]{3,60}$'')))');
        END IF;
        -- A lista nasce com o codigo da API: permissao nova e uma linha nova aqui.
        FOR p IN (SELECT 'EMPRESA_LER' c, 'Ver os dados da empresa' d, 0 x FROM dual
                  UNION ALL SELECT 'EMPRESA_ALTERAR', 'Alterar os dados da propria empresa', 0 FROM dual
                  UNION ALL SELECT 'FILIAL_LER', 'Ver filiais, e os contatos e enderecos delas', 0 FROM dual
                  UNION ALL SELECT 'FILIAL_GERENCIAR', 'Criar, alterar, inativar e excluir filiais, e os contatos e enderecos delas', 0 FROM dual
                  UNION ALL SELECT 'PESSOA_LER', 'Ver pessoas (documento, e-mail e telefone mascarados), e os contatos e enderecos delas', 0 FROM dual
                  UNION ALL SELECT 'PESSOA_GERENCIAR', 'Criar, alterar, inativar e excluir pessoas, e os contatos e enderecos delas', 0 FROM dual
                  UNION ALL SELECT 'DADO_PESSOAL_REVELAR', 'Ver o CPF/CNPJ, e-mail e telefone inteiros (fica no LOG_ACESSO)', 0 FROM dual
                  UNION ALL SELECT 'USUARIO_GERENCIAR', 'Criar usuarios, emitir convites, desativar e reativar o acesso a empresa', 1 FROM dual
                  UNION ALL SELECT 'PERFIL_GERENCIAR', 'Dar e trocar o cargo dos usuarios, criar e editar perfis', 1 FROM dual) LOOP
            executar('MERGE INTO ' || v_login || '.PERMISSAO t USING (SELECT ''' || p.c || ''' c FROM dual) n ON (t.CODIGO = n.c)
                      WHEN NOT MATCHED THEN INSERT (CODIGO, DESCRICAO, EXCLUSIVA_ADMIN) VALUES (''' || p.c || ''', ''' || p.d || ''', '
                      || CASE p.x WHEN 1 THEN 'TRUE' ELSE 'FALSE' END || ')');
        END LOOP;

        IF NOT existe_tabela(v_login, 'PERFIL') THEN
            executar('CREATE TABLE ' || v_login || '.PERFIL (
                ID              NUMBER GENERATED ALWAYS AS IDENTITY,
                EMPRESA_ID      NUMBER              NOT NULL,
                NOME            VARCHAR2(50 CHAR)   NOT NULL,
                DESCRICAO       VARCHAR2(200 CHAR),
                FIXO            BOOLEAN             DEFAULT FALSE NOT NULL,
                ATIVO           BOOLEAN             DEFAULT TRUE NOT NULL,
                ATUALIZADO_POR  VARCHAR2(128)       NOT NULL,
                CRIADO_EM       TIMESTAMP(6)        DEFAULT ' || v_agora || ' NOT NULL,
                ATUALIZADO_EM   TIMESTAMP(6)        DEFAULT ' || v_agora || ' NOT NULL,
                CONSTRAINT PK_PERFIL PRIMARY KEY (ID),
                CONSTRAINT UK_PERFIL UNIQUE (EMPRESA_ID, NOME),
                CONSTRAINT UK_PERFIL_ID_EMPRESA UNIQUE (ID, EMPRESA_ID))');
            -- No maximo um perfil FIXO (o ADMINISTRADOR) por empresa.
            executar('CREATE UNIQUE INDEX ' || v_login || '.UX_PERFIL_FIXO ON ' || v_login || '.PERFIL (CASE WHEN FIXO THEN EMPRESA_ID END)');
        END IF;

        IF NOT existe_tabela(v_login, 'PERFIL_PERMISSAO') THEN
            executar('CREATE TABLE ' || v_login || '.PERFIL_PERMISSAO (
                ID              NUMBER GENERATED ALWAYS AS IDENTITY,
                PERFIL_ID       NUMBER          NOT NULL,
                PERMISSAO_ID    NUMBER          NOT NULL,
                ATIVO           BOOLEAN         DEFAULT TRUE NOT NULL,
                ATUALIZADO_POR  VARCHAR2(128)   NOT NULL,
                CRIADO_EM       TIMESTAMP(6)    DEFAULT ' || v_agora || ' NOT NULL,
                ATUALIZADO_EM   TIMESTAMP(6)    DEFAULT ' || v_agora || ' NOT NULL,
                CONSTRAINT PK_PERFIL_PERMISSAO PRIMARY KEY (ID),
                CONSTRAINT UK_PERFIL_PERMISSAO UNIQUE (PERFIL_ID, PERMISSAO_ID),
                CONSTRAINT FK_PERFIL_PERMISSAO_PERFIL FOREIGN KEY (PERFIL_ID) REFERENCES ' || v_login || '.PERFIL (ID),
                CONSTRAINT FK_PERFIL_PERMISSAO_PERMISSAO FOREIGN KEY (PERMISSAO_ID) REFERENCES ' || v_login || '.PERMISSAO (ID))');
        END IF;

        IF NOT existe_tabela(v_login, 'USUARIO_EMPRESA') THEN
            executar('CREATE TABLE ' || v_login || '.USUARIO_EMPRESA (
                ID              NUMBER GENERATED ALWAYS AS IDENTITY,
                USUARIO_ID      NUMBER          NOT NULL,
                EMPRESA_ID      NUMBER          NOT NULL,
                PERFIL_ID       NUMBER          NOT NULL,
                ATIVO           BOOLEAN         DEFAULT TRUE NOT NULL,
                ATUALIZADO_POR  VARCHAR2(128)   NOT NULL,
                CRIADO_EM       TIMESTAMP(6)    DEFAULT ' || v_agora || ' NOT NULL,
                ATUALIZADO_EM   TIMESTAMP(6)    DEFAULT ' || v_agora || ' NOT NULL,
                CONSTRAINT PK_USUARIO_EMPRESA PRIMARY KEY (ID),
                CONSTRAINT UK_USUARIO_EMPRESA UNIQUE (USUARIO_ID, EMPRESA_ID),
                CONSTRAINT FK_USUARIO_EMPRESA_USUARIO FOREIGN KEY (USUARIO_ID) REFERENCES ' || v_login || '.USUARIO (ID),
                CONSTRAINT FK_USUARIO_EMPRESA_PERFIL FOREIGN KEY (PERFIL_ID, EMPRESA_ID) REFERENCES ' || v_login || '.PERFIL (ID, EMPRESA_ID))');
            executar('CREATE INDEX ' || v_login || '.IX_USUARIO_EMPRESA_EMPRESA ON ' || v_login || '.USUARIO_EMPRESA (EMPRESA_ID, ATIVO)');
            executar('CREATE INDEX ' || v_login || '.IX_USUARIO_EMPRESA_PERFIL ON ' || v_login || '.USUARIO_EMPRESA (PERFIL_ID, EMPRESA_ID)');
        END IF;

        -- Sessao presa a uma empresa.
        IF NOT existe_coluna(v_sessao, 'TOKEN', 'EMPRESA_ID') THEN
            executar('ALTER TABLE ' || v_sessao || '.TOKEN ADD (EMPRESA_ID NUMBER)');
            executar('CREATE INDEX ' || v_sessao || '.IX_TOKEN_EMPRESA ON ' || v_sessao || '.TOKEN (USUARIO_ID, EMPRESA_ID)');
        END IF;
        trocar_check(v_sessao, 'TOKEN', 'CK_TOKEN_REVOGACAO',
            q'[(REVOGADO_EM IS NULL AND MOTIVO_REVOGACAO IS NULL) OR (REVOGADO_EM IS NOT NULL AND MOTIVO_REVOGACAO IN ('LOGOUT', 'SAIR_DE_TODOS', 'PASSKEY_REMOVIDA', 'LIMITE_SESSOES', 'USUARIO_DESLIGADO', 'RECUPERACAO', 'SUSPEITA', 'TROCA_EMPRESA', 'VINCULO_DESATIVADO'))]');
        trocar_check(v_log, 'LOG_SEGURANCA', 'CK_LOG_SEGURANCA_EVENTO',
            q'[EVENTO IN ('LOGIN', 'LOGOUT', 'SAIR_DE_TODOS', 'PASSKEY_CADASTRADA', 'PASSKEY_REMOVIDA', 'CODIGOS_GERADOS', 'CODIGO_USADO', 'CONVITE_CRIADO', 'CONVITE_USADO', 'IP_BLOQUEADO', 'SESSAO_ENCERRADA', 'USUARIO_CRIADO', 'PARAMETRO_ALTERADO', 'CONTADOR_SUSPEITO', 'EMPRESA_ESCOLHIDA', 'EMPRESA_CRIADA', 'ADMIN_PLATAFORMA_CONCEDIDO', 'ADMIN_PLATAFORMA_REVOGADO')]');

        -- ======================= LOG_PERMISSAO (encadeado) =======================
        IF NOT existe_tabela(v_log, 'LOG_PERMISSAO') THEN
            executar('CREATE TABLE ' || v_log || '.LOG_PERMISSAO (
                ID               NUMBER GENERATED ALWAYS AS IDENTITY,
                ORDEM            NUMBER              NOT NULL,
                EVENTO           VARCHAR2(30)        NOT NULL,
                EMPRESA_ID       NUMBER              NOT NULL,
                USUARIO_ID       NUMBER,
                PERFIL_ANTERIOR  VARCHAR2(50 CHAR),
                PERFIL_NOVO      VARCHAR2(50 CHAR),
                PERMISSAO        VARCHAR2(60),
                FEITO_POR        VARCHAR2(128)       NOT NULL,
                DATA_HORA        TIMESTAMP(6)        DEFAULT ' || v_agora || ' NOT NULL,
                HASH_ANTERIOR    VARCHAR2(64),
                HASH             VARCHAR2(64)        NOT NULL,
                CONSTRAINT PK_LOG_PERMISSAO PRIMARY KEY (ID),
                CONSTRAINT UK_LOG_PERMISSAO_ORDEM UNIQUE (ORDEM),
                CONSTRAINT CK_LOG_PERMISSAO_EVENTO CHECK (EVENTO IN (''VINCULO_CRIADO'', ''PERFIL_TROCADO'', ''VINCULO_DESATIVADO'',
                    ''VINCULO_REATIVADO'', ''PERMISSAO_ADICIONADA'', ''PERMISSAO_REMOVIDA'', ''PERFIL_CRIADO'')))');
            executar('CREATE INDEX ' || v_log || '.IX_LOG_PERMISSAO_EMPRESA ON ' || v_log || '.LOG_PERMISSAO (EMPRESA_ID, DATA_HORA)');
        END IF;
        executar('MERGE INTO ' || v_log || '.LOG_CADEIA c USING (SELECT ''LOG_PERMISSAO'' t FROM dual) n ON (c.TABELA = n.t)
                  WHEN NOT MATCHED THEN INSERT (TABELA) VALUES (n.t)');
        executar('CREATE OR REPLACE TRIGGER ' || v_log || '.LOG_PERMISSAO_CADEIA_TRG
            BEFORE INSERT ON ' || v_log || '.LOG_PERMISSAO
            FOR EACH ROW
            DECLARE
                v_hash RAW(32);
            BEGIN
                SELECT ULTIMA_ORDEM + 1, ULTIMO_HASH INTO :NEW.ORDEM, :NEW.HASH_ANTERIOR
                  FROM ' || v_log || '.LOG_CADEIA WHERE TABELA = ''LOG_PERMISSAO'' FOR UPDATE;
                :NEW.DATA_HORA := ' || v_agora || ';
                SELECT STANDARD_HASH(' || REPLACE(v_conteudo, '#P#', ':NEW.') || ', ''SHA256'') INTO v_hash FROM DUAL;
                :NEW.HASH := LOWER(RAWTOHEX(v_hash));
                UPDATE ' || v_log || '.LOG_CADEIA SET ULTIMA_ORDEM = :NEW.ORDEM, ULTIMO_HASH = :NEW.HASH
                 WHERE TABELA = ''LOG_PERMISSAO'';
            END;');
        executar('CREATE OR REPLACE VIEW ' || v_log || '.V_LOG_PERMISSAO_QUEBRAS AS
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
                  FROM ' || v_log || '.LOG_PERMISSAO l)
             WHERE PROBLEMA IS NOT NULL
            UNION ALL
            SELECT c.ULTIMA_ORDEM, ''faltam linhas no fim (a ultima gravada nao esta mais na tabela)''
              FROM ' || v_log || '.LOG_CADEIA c
             WHERE c.TABELA = ''LOG_PERMISSAO''
               AND c.ULTIMA_ORDEM <> (SELECT NVL(MAX(ORDEM), 0) FROM ' || v_log || '.LOG_PERMISSAO)');
        -- Quem grava no LOG_PERMISSAO sao os gatilhos do schema _LOGIN (a API nao tem INSERT nele).
        executar('GRANT INSERT ON ' || v_log || '.LOG_PERMISSAO TO ' || v_login);

        -- ======================= GATILHOS =======================
        -- ADMIN_PLATAFORMA: quem concedeu e o LOG_SEGURANCA de cada concessao e revogacao.
        executar('CREATE OR REPLACE TRIGGER ' || v_login || '.ADMIN_PLATAFORMA_LOG_TRG
            BEFORE INSERT OR UPDATE OR DELETE ON ' || v_login || '.ADMIN_PLATAFORMA
            FOR EACH ROW
            DECLARE
                v_quem VARCHAR2(128) := NVL(SYS_CONTEXT(''USERENV'', ''PROXY_USER''), SYS_CONTEXT(''USERENV'', ''SESSION_USER''));
            BEGIN
                IF UPDATING THEN
                    RAISE_APPLICATION_ERROR(-20105, ''ADMIN_PLATAFORMA nao se altera: revogue e conceda de novo.'');
                ELSIF INSERTING THEN
                    :NEW.CONCEDIDO_POR := v_quem;
                    :NEW.CONCEDIDO_EM := ' || v_agora || ';
                    INSERT INTO ' || v_log || '.LOG_SEGURANCA (ORDEM, EVENTO, USUARIO_ID, DETALHE, FEITO_POR, HASH)
                    VALUES (0, ''ADMIN_PLATAFORMA_CONCEDIDO'', :NEW.USUARIO_ID, SUBSTR(:NEW.MOTIVO, 1, 500), v_quem, ''-'');
                ELSE
                    INSERT INTO ' || v_log || '.LOG_SEGURANCA (ORDEM, EVENTO, USUARIO_ID, DETALHE, FEITO_POR, HASH)
                    VALUES (0, ''ADMIN_PLATAFORMA_REVOGADO'', :OLD.USUARIO_ID, ''concedido em '' || TO_CHAR(:OLD.CONCEDIDO_EM, ''YYYY-MM-DD'') || '' por '' || :OLD.CONCEDIDO_POR, v_quem, ''-'');
                END IF;
            END;');

        -- PERFIL: o ADMINISTRADOR (FIXO) nao muda de nome, nao e desativado, nao deixa de ser fixo;
        -- nenhum perfil vira fixo depois de criado nem muda de empresa; perfil com usuarios ativos
        -- nao e desativado. A criacao vai para o LOG_PERMISSAO.
        executar('CREATE OR REPLACE TRIGGER ' || v_login || '.PERFIL_TRG
            BEFORE INSERT OR UPDATE ON ' || v_login || '.PERFIL
            FOR EACH ROW
            DECLARE
                v_total NUMBER;
            BEGIN
                ' || v_quem || '
                :NEW.ATUALIZADO_EM := ' || v_agora || ';
                IF INSERTING THEN
                    INSERT INTO ' || v_log || '.LOG_PERMISSAO (ORDEM, EVENTO, EMPRESA_ID, PERFIL_NOVO, FEITO_POR, HASH)
                    VALUES (0, ''PERFIL_CRIADO'', :NEW.EMPRESA_ID, :NEW.NOME, :NEW.ATUALIZADO_POR, ''-'');
                ELSE
                    IF :NEW.EMPRESA_ID <> :OLD.EMPRESA_ID OR (:NEW.FIXO AND NOT :OLD.FIXO) THEN
                        RAISE_APPLICATION_ERROR(-20101, ''Um perfil nao muda de empresa nem vira fixo depois de criado.'');
                    END IF;
                    IF :OLD.FIXO AND (NOT :NEW.FIXO OR NOT :NEW.ATIVO OR :NEW.NOME <> :OLD.NOME) THEN
                        RAISE_APPLICATION_ERROR(-20101, ''O perfil ADMINISTRADOR e fixo: nao muda de nome, nao e desativado.'');
                    END IF;
                    IF :OLD.ATIVO AND NOT :NEW.ATIVO THEN
                        SELECT COUNT(*) INTO v_total FROM ' || v_login || '.USUARIO_EMPRESA WHERE PERFIL_ID = :OLD.ID AND ATIVO;
                        IF v_total > 0 THEN
                            RAISE_APPLICATION_ERROR(-20102, ''Ha usuarios ativos com este perfil: troque o cargo deles antes.'');
                        END IF;
                    END IF;
                END IF;
            END;');

        -- PERFIL_PERMISSAO: o ADMINISTRADOR ja tem tudo (nao recebe linhas); permissao exclusiva do
        -- administrador nao vai para outro perfil; cada mudanca vai para o LOG_PERMISSAO.
        executar('CREATE OR REPLACE TRIGGER ' || v_login || '.PERFIL_PERMISSAO_TRG
            BEFORE INSERT OR UPDATE ON ' || v_login || '.PERFIL_PERMISSAO
            FOR EACH ROW
            DECLARE
                v_fixo      BOOLEAN;
                v_empresa   NUMBER;
                v_perfil    VARCHAR2(50 CHAR);
                v_codigo    VARCHAR2(60);
                v_exclusiva BOOLEAN;
            BEGIN
                ' || v_quem || '
                :NEW.ATUALIZADO_EM := ' || v_agora || ';
                IF UPDATING AND (:NEW.PERFIL_ID <> :OLD.PERFIL_ID OR :NEW.PERMISSAO_ID <> :OLD.PERMISSAO_ID) THEN
                    RAISE_APPLICATION_ERROR(-20106, ''Para trocar a permissao, desative esta linha e crie outra.'');
                END IF;
                SELECT FIXO, EMPRESA_ID, NOME INTO v_fixo, v_empresa, v_perfil FROM ' || v_login || '.PERFIL WHERE ID = :NEW.PERFIL_ID;
                SELECT CODIGO, EXCLUSIVA_ADMIN INTO v_codigo, v_exclusiva FROM ' || v_login || '.PERMISSAO WHERE ID = :NEW.PERMISSAO_ID;
                IF v_fixo THEN
                    RAISE_APPLICATION_ERROR(-20107, ''O ADMINISTRADOR ja tem todas as permissoes: nao se poe nem se tira permissao dele.'');
                END IF;
                IF v_exclusiva AND :NEW.ATIVO THEN
                    RAISE_APPLICATION_ERROR(-20108, ''A permissao '' || v_codigo || '' e exclusiva do ADMINISTRADOR.'');
                END IF;
                IF (INSERTING AND :NEW.ATIVO) OR (UPDATING AND :NEW.ATIVO AND NOT :OLD.ATIVO) THEN
                    INSERT INTO ' || v_log || '.LOG_PERMISSAO (ORDEM, EVENTO, EMPRESA_ID, PERFIL_NOVO, PERMISSAO, FEITO_POR, HASH)
                    VALUES (0, ''PERMISSAO_ADICIONADA'', v_empresa, v_perfil, v_codigo, :NEW.ATUALIZADO_POR, ''-'');
                ELSIF UPDATING AND :OLD.ATIVO AND NOT :NEW.ATIVO THEN
                    INSERT INTO ' || v_log || '.LOG_PERMISSAO (ORDEM, EVENTO, EMPRESA_ID, PERFIL_ANTERIOR, PERMISSAO, FEITO_POR, HASH)
                    VALUES (0, ''PERMISSAO_REMOVIDA'', v_empresa, v_perfil, v_codigo, :NEW.ATUALIZADO_POR, ''-'');
                END IF;
            END;');

        -- USUARIO_EMPRESA: o vinculo nao muda de usuario nem de empresa; perfil inativo nao recebe
        -- ninguem; cada mudanca (de qual perfil para qual) vai para o LOG_PERMISSAO.
        executar('CREATE OR REPLACE TRIGGER ' || v_login || '.USUARIO_EMPRESA_TRG
            BEFORE INSERT OR UPDATE ON ' || v_login || '.USUARIO_EMPRESA
            FOR EACH ROW
            DECLARE
                v_antes  VARCHAR2(50 CHAR);
                v_depois VARCHAR2(50 CHAR);
                v_ativo  BOOLEAN;
            BEGIN
                ' || v_quem || '
                :NEW.ATUALIZADO_EM := ' || v_agora || ';
                IF UPDATING AND (:NEW.USUARIO_ID <> :OLD.USUARIO_ID OR :NEW.EMPRESA_ID <> :OLD.EMPRESA_ID) THEN
                    RAISE_APPLICATION_ERROR(-20109, ''O vinculo nao muda de usuario nem de empresa.'');
                END IF;
                SELECT NOME, ATIVO INTO v_depois, v_ativo FROM ' || v_login || '.PERFIL WHERE ID = :NEW.PERFIL_ID;
                IF NOT v_ativo AND (INSERTING OR :NEW.PERFIL_ID <> :OLD.PERFIL_ID) THEN
                    RAISE_APPLICATION_ERROR(-20110, ''Este perfil esta desativado.'');
                END IF;
                IF INSERTING THEN
                    INSERT INTO ' || v_log || '.LOG_PERMISSAO (ORDEM, EVENTO, EMPRESA_ID, USUARIO_ID, PERFIL_NOVO, FEITO_POR, HASH)
                    VALUES (0, ''VINCULO_CRIADO'', :NEW.EMPRESA_ID, :NEW.USUARIO_ID, v_depois, :NEW.ATUALIZADO_POR, ''-'');
                ELSE
                    IF :NEW.PERFIL_ID <> :OLD.PERFIL_ID THEN
                        SELECT NOME INTO v_antes FROM ' || v_login || '.PERFIL WHERE ID = :OLD.PERFIL_ID;
                        INSERT INTO ' || v_log || '.LOG_PERMISSAO (ORDEM, EVENTO, EMPRESA_ID, USUARIO_ID, PERFIL_ANTERIOR, PERFIL_NOVO, FEITO_POR, HASH)
                        VALUES (0, ''PERFIL_TROCADO'', :NEW.EMPRESA_ID, :NEW.USUARIO_ID, v_antes, v_depois, :NEW.ATUALIZADO_POR, ''-'');
                    END IF;
                    IF :OLD.ATIVO AND NOT :NEW.ATIVO THEN
                        INSERT INTO ' || v_log || '.LOG_PERMISSAO (ORDEM, EVENTO, EMPRESA_ID, USUARIO_ID, PERFIL_ANTERIOR, FEITO_POR, HASH)
                        VALUES (0, ''VINCULO_DESATIVADO'', :NEW.EMPRESA_ID, :NEW.USUARIO_ID, v_depois, :NEW.ATUALIZADO_POR, ''-'');
                    ELSIF :NEW.ATIVO AND NOT :OLD.ATIVO THEN
                        INSERT INTO ' || v_log || '.LOG_PERMISSAO (ORDEM, EVENTO, EMPRESA_ID, USUARIO_ID, PERFIL_NOVO, FEITO_POR, HASH)
                        VALUES (0, ''VINCULO_REATIVADO'', :NEW.EMPRESA_ID, :NEW.USUARIO_ID, v_depois, :NEW.ATUALIZADO_POR, ''-'');
                    END IF;
                END IF;
            END;');

        -- Pelo menos um ADMINISTRADOR ativo por empresa. Depois de cada UPDATE, trava o perfil
        -- ADMINISTRADOR das empresas mexidas (dois administradores que se rebaixam ao mesmo tempo
        -- passam um de cada vez) e conta.
        executar('CREATE OR REPLACE TRIGGER ' || v_login || '.USUARIO_EMPRESA_ADMIN_TRG
            FOR UPDATE ON ' || v_login || '.USUARIO_EMPRESA
            COMPOUND TRIGGER
                TYPE t_ids IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
                v_ids t_ids;
                AFTER EACH ROW IS
                BEGIN
                    v_ids(v_ids.COUNT + 1) := :OLD.EMPRESA_ID;
                END AFTER EACH ROW;
                AFTER STATEMENT IS
                    v_total NUMBER;
                BEGIN
                    FOR i IN 1 .. v_ids.COUNT LOOP
                        FOR t IN (SELECT ID FROM ' || v_login || '.PERFIL WHERE EMPRESA_ID = v_ids(i) AND FIXO FOR UPDATE) LOOP
                            NULL;  -- so a trava
                        END LOOP;
                        SELECT COUNT(*) INTO v_total
                          FROM ' || v_login || '.USUARIO_EMPRESA ue JOIN ' || v_login || '.PERFIL p ON p.ID = ue.PERFIL_ID
                         WHERE ue.EMPRESA_ID = v_ids(i) AND ue.ATIVO AND p.FIXO;
                        IF v_total = 0 THEN
                            RAISE_APPLICATION_ERROR(-20103, ''A empresa '' || v_ids(i) || '' ficaria sem nenhum administrador ativo.'');
                        END IF;
                    END LOOP;
                END AFTER STATEMENT;
            END;');

        -- ======================= PERMISSOES =======================
        -- So o schema de EXECUCAO da API (_APP), e nenhum DELETE. ADMIN_PLATAFORMA e PERMISSAO: so
        -- ler. LOG_PERMISSAO: so ler (quem grava sao os gatilhos).
        executar('GRANT SELECT ON ' || v_login || '.ADMIN_PLATAFORMA TO ' || v_app);
        executar('GRANT SELECT ON ' || v_login || '.PERMISSAO TO ' || v_app);
        executar('GRANT SELECT, INSERT, UPDATE ON ' || v_login || '.PERFIL TO ' || v_app);
        executar('GRANT SELECT, INSERT, UPDATE ON ' || v_login || '.PERFIL_PERMISSAO TO ' || v_app);
        executar('GRANT SELECT, INSERT, UPDATE ON ' || v_login || '.USUARIO_EMPRESA TO ' || v_app);
        executar('GRANT SELECT ON ' || v_log || '.LOG_PERMISSAO TO ' || v_app);
        executar('GRANT SELECT ON ' || v_log || '.V_LOG_PERMISSAO_QUEBRAS TO ' || v_app);
        executar('GRANT EXECUTE ON SYS.KAWASHI_LIGAR_AUTORIZACAO TO ' || v_env);
    END;
BEGIN
    criar_autorizacao('TESTE_DEV');
    criar_autorizacao('TESTE_INFRA');
    criar_autorizacao('DEV');
    criar_autorizacao('INFRA');
    criar_autorizacao('HOMOLOG');
    criar_autorizacao('PROD');
    COMMIT;
    -- Ambientes em que a API ja criou os cadastros: liga as chaves e cria a visao agora.
    FOR a IN (SELECT 'TESTE_DEV' amb FROM dual UNION ALL SELECT 'TESTE_INFRA' FROM dual UNION ALL SELECT 'DEV' FROM dual
              UNION ALL SELECT 'INFRA' FROM dual UNION ALL SELECT 'HOMOLOG' FROM dual UNION ALL SELECT 'PROD' FROM dual) LOOP
        KAWASHI_LIGAR_AUTORIZACAO(a.amb);
    END LOOP;
END;
/
