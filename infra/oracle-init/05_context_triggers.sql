-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 6 - TRIGGER DE SEGURANÇA CONTEXTUAL DE LOGON
-- #########################################################
-- "AFTER LOGON ON DATABASE" e um trigger de sistema: dispara sozinho, pro
-- Oracle, toda vez que QUALQUER sessao autentica com sucesso neste PDB - nao
-- precisa ser "instalado" em nenhuma tabela, ele intercepta o proprio evento
-- de login. E aqui que a maior parte das regras de negocio de acesso do
-- projeto vive hoje (ver README, item de checklist "Zero Trust & MFA").
--
-- Por que RAISE_APPLICATION_ERROR aborta o login mas as chamadas de log nao
-- travam nada? Levantar esse erro dentro do proprio trigger de logon cancela
-- a conexao (o cliente recebe erro e nunca chega a "entrar" de fato) - e assim
-- que qualquer uma das 4 regras abaixo consegue efetivamente bloquear alguem.
-- Ja o KAWASHI_WRITE_SECURITY_LOG roda em transacao autonoma (arquivo 04),
-- entao registrar o evento nunca compete com essa decisao de permitir/negar.
CREATE OR REPLACE TRIGGER KAWASHI_CONTEXT_SECURITY_TRG
AFTER LOGON ON DATABASE
DECLARE
    V_IP            VARCHAR2(100);
    V_PROGRAM       VARCHAR2(200);
    V_OS_USER       VARCHAR2(100);
    V_HOUR          NUMBER;
    V_IP_ALLOWED    NUMBER;
    V_TOOL_BLOCKED  NUMBER;
    V_CURRENT_USER  VARCHAR2(100);
BEGIN
    V_CURRENT_USER := SYS_CONTEXT('USERENV', 'SESSION_USER');
    V_IP           := SYS_CONTEXT('USERENV', 'IP_ADDRESS');
    V_PROGRAM      := UPPER(SYS_CONTEXT('USERENV', 'CLIENT_PROGRAM_NAME'));
    V_OS_USER      := UPPER(SYS_CONTEXT('USERENV', 'OS_USER'));
    
    -- Normalização do fuso horário para Brasília (Evita disparidades com instâncias locais/Docker em UTC)
    V_HOUR         := TO_NUMBER(TO_CHAR(SYSTIMESTAMP AT TIME ZONE 'America/Sao_Paulo', 'HH24'));

    -- Monitoramento ativo e auditoria preventiva para credenciais administrativas master.
    -- SYS/SYSTEM sao isentos de TODAS as 4 regras abaixo (o RETURN sai do trigger na
    -- hora) porque sao as contas que o proprio Oracle usa internamente para operacoes
    -- de manutencao/boot - bloquear essas contas por engano poderia inviabilizar o
    -- proprio banco de subir. Isso e tambem o motivo pelo qual pessoas nao devem logar
    -- como SYS/SYSTEM no dia a dia (ver infra/oracle-init/08_engineer_account.sql):
    -- e a unica conta que escapa de toda a fiscalizacao deste trigger.
    IF V_CURRENT_USER IN ('SYS', 'SYSTEM') THEN
        KAWASHI_WRITE_SECURITY_LOG(
            'PRIVILEGED_LOGIN', 
            'Acesso administrativo direto estabelecido na infraestrutura.'
        );
        RETURN;
    END IF;

    -- =====================================================
    -- REGRA 1 - VALIDAÇÃO DE IP COM TRATAMENTO FAIL-OPEN
    -- =====================================================
    -- ATENCAO - LEIA ANTES DE ATIVAR O BLOQUEIO DE VERDADE (descomentar o
    -- RAISE_APPLICATION_ERROR mais abaixo): esta regra NAO isenta o
    -- ENGINEER_USER (diferente de SYS/SYSTEM, que tem RETURN antecipado la em
    -- cima). Ou seja, no dia em que o bloqueio for ativado, ATE o proprio
    -- engenheiro do projeto perde acesso se o IP da maquina dele nao estiver
    -- em KAWASHI_ALLOWED_IPS - inclusive quebrando o create-team-member.ps1 e
    -- o vault-init.ps1, que conectam usando ENGINEER_USER. Antes de ativar:
    --   1. Cadastre o IP de CADA maquina que precisa acessar o banco (a sua
    --      propria, a de cada pessoa do time, servidor da aplicacao, etc.)
    --      em KAWASHI_ALLOWED_IPS.
    --   2. So depois disso, descomente o RAISE_APPLICATION_ERROR.
    -- Hoje (fail-open) o create-team-member.ps1 funciona de qualquer lugar
    -- com conexao de rede ate a porta 1521 - isso muda no dia em que esta
    -- regra virar bloqueio de verdade.
    IF V_IP IS NOT NULL THEN
        BEGIN
            SELECT COUNT(*)
            INTO V_IP_ALLOWED
            FROM KAWASHI_ALLOWED_IPS
            WHERE IP_ADDRESS = V_IP;
        EXCEPTION
            WHEN OTHERS THEN
                V_IP_ALLOWED := 1; -- Fail-Open controlado prioritário
                KAWASHI_WRITE_SECURITY_LOG(
                    'WHITELIST_ERROR_FAIL_OPEN',
                    'Alerta: Whitelist inacessivel. Fail-open temporario ativo. Erro: ' || SQLERRM
                );
        END;

        IF V_IP_ALLOWED = 0 THEN
            KAWASHI_WRITE_SECURITY_LOG(
                'UNKNOWN_IP_WARNING',
                'Aviso: IP nao cadastrado na whitelist: ' || V_IP
            );
            
            -- TODO PRODUÇÃO: Descomentar a linha abaixo após validar todos os IPs de produção na tabela
            -- RAISE_APPLICATION_ERROR(-20001, 'Access Denied: Unauthorized IP Location.');
        END IF;
    END IF;

    -- =====================================================
    -- REGRA 2 - JANELA DE HORÁRIO CORPORATIVO (BRT)
    -- =====================================================
    -- Em dev, apenas registra o acesso fora da janela (fail-open), mesma postura
    -- da Regra 1 (IP) - nao faz sentido travar o proprio time enquanto o projeto
    -- ainda esta em desenvolvimento solo/sem horario fixo.
    IF V_HOUR >= 22 OR V_HOUR < 6 THEN
        KAWASHI_WRITE_SECURITY_LOG(
            'OUTSIDE_HOURS_WARNING',
            'Aviso: acesso fora da janela de manutencao autorizada.'
        );

        -- TODO PRODUÇÃO: Descomentar a linha abaixo quando a janela de horario
        -- corporativo for definida e validada com o time todo.
        -- RAISE_APPLICATION_ERROR(-20002, 'Access Denied: Maintenance window is closed.');
    END IF;

    -- =====================================================
    -- REGRA 3 - CONTA INSEGURA DE SISTEMA OPERACIONAL
    -- =====================================================
    -- Diferente das Regras 1, 2 e 4 (fail-open: registram e deixam passar),
    -- esta bloqueia de verdade mesmo em dev. Motivo: um SO_USER "root"/
    -- "administrator"/"guest" e um sinal de maquina mal configurada/conta
    -- generica compartilhada, nao uma configuracao legitima que muda de
    -- ambiente pra ambiente como IP ou horario - entao o risco de falso
    -- positivo bloqueando gente de verdade e bem menor.
    IF V_OS_USER IN ('ROOT', 'ADMINISTRATOR', 'GUEST') THEN
        KAWASHI_WRITE_SECURITY_LOG(
            'BLOCKED_OS_USER',
            'Conta de OS vulneravel interceptada: ' || V_OS_USER
        );
        RAISE_APPLICATION_ERROR(-20003, 'Access Denied: Insecure OS account.');
    END IF;

    -- =====================================================
    -- REGRA 4 - BLACKLIST DINÂMICA DE APLICATIVOS COM FAIL-OPEN
    -- =====================================================
    BEGIN
        SELECT COUNT(*)
        INTO V_TOOL_BLOCKED
        FROM KAWASHI_FORBIDDEN_TOOLS
        WHERE V_PROGRAM LIKE TOOL_PATTERN;
    EXCEPTION
        WHEN OTHERS THEN
            V_TOOL_BLOCKED := 0; -- Fail-open: evita bloqueio massivo se a tabela sofrer travas
            KAWASHI_WRITE_SECURITY_LOG(
                'FORBIDDEN_TOOLS_ERROR',
                'Tabela de ferramentas indisponivel. Fail-open ativo. Erro: ' || SQLERRM
            );
    END;

    IF V_TOOL_BLOCKED > 0 THEN
        KAWASHI_WRITE_SECURITY_LOG(
            'BLOCKED_TOOL',
            'Ferramenta nao autorizada interceptada: ' || V_PROGRAM
        );
        RAISE_APPLICATION_ERROR(-20004, 'Access Denied: Unauthorized client tool.');
    END IF;

    KAWASHI_WRITE_SECURITY_LOG('SUCCESSFUL_LOGIN', 'Sessao estabelecida com sucesso.');
END;
/

-- #########################################################
-- PASSO 8 - TRIGGER DE MONITORAMENTO DE LOGOFF
-- #########################################################
CREATE OR REPLACE TRIGGER KAWASHI_LOGOFF_SECURITY_TRG
BEFORE LOGOFF ON DATABASE
BEGIN
    IF SYS_CONTEXT('USERENV', 'SESSION_USER') NOT IN ('SYS', 'SYSTEM') THEN
        KAWASHI_WRITE_SECURITY_LOG(
            'SESSION_END',
            'Sessao normal de usuario encerrada com sucesso.'
        );
    END IF;
END;
/


-- #########################################################
-- PASSO 9 - TRIGGER DE AUDITORIA DE ALTERAÇÕES DDL CRÍTICAS
-- #########################################################
-- "AFTER DDL ON DATABASE" dispara depois de qualquer CREATE/ALTER/DROP no PDB.
-- ORA_SYSEVENT, ORA_DICT_OBJ_OWNER/NAME/TYPE sao funcoes especiais que SO
-- existem dentro do corpo de um trigger de sistema como este - e como o
-- Oracle expoe "o que mudou" pra quem esta escutando o evento. A ideia aqui
-- e simples: se alguem criar/alterar/derrubar uma tabela, indice, procedure
-- etc., isso fica registrado mesmo que a pessoa nunca tenha rodado nada
-- "suspeito" o bastante pra disparar as regras do trigger de logon.
CREATE OR REPLACE TRIGGER KAWASHI_DDL_AUDIT_TRG
AFTER DDL ON DATABASE
BEGIN
    IF SYS_CONTEXT('USERENV', 'SESSION_USER') NOT IN ('SYS', 'SYSTEM') THEN
        KAWASHI_WRITE_SECURITY_LOG(
            'DDL_MODIFICATION',
            'Evento: DDL_' || ORA_SYSEVENT || ' | Objeto: ' || ORA_DICT_OBJ_OWNER || '.' || ORA_DICT_OBJ_NAME || ' | Tipo: ' || ORA_DICT_OBJ_TYPE
        );
    END IF;
END;
/


-- #########################################################
-- PASSO 10 - TRIGGER DE AUDITORIA DE ESCALONAMENTO DE PRIVILÉGIOS
-- #########################################################
-- "AFTER GRANT ON DATABASE" e o trigger mais sensivel deste arquivo: dispara
-- toda vez que alguem concede um privilegio/role pra outra pessoa. E a
-- primeira linha de defesa contra escalonamento de privilegio silencioso -
-- se um usuario comprometido tentar se auto-conceder mais poder (ou dar poder
-- a um comparsa), fica registrado aqui, mesmo que a conta usada tenha DBA.
CREATE OR REPLACE TRIGGER KAWASHI_PRIVESC_AUDIT_TRG
AFTER GRANT ON DATABASE
BEGIN
    IF SYS_CONTEXT('USERENV', 'SESSION_USER') NOT IN ('SYS', 'SYSTEM') THEN
        KAWASHI_WRITE_SECURITY_LOG(
            'PRIVILEGE_GRANT_ALERT',
            'Concessao realizada por: ' || SYS_CONTEXT('USERENV', 'SESSION_USER') || ' | Beneficiado/Objeto: ' || ORA_DICT_OBJ_NAME
        );
    END IF;
END;
/

