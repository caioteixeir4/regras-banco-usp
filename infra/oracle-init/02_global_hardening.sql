-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 1 - FUNÇÃO CUSTOMIZADA DE VERIFICAÇÃO DE SENHA (NIST COMPLIANT)
-- #########################################################
-- O Oracle nao valida complexidade de senha por padrao - ele so aceita o que
-- mandarem, do jeito que for. Essa funcao e o "gancho" que o Oracle chama
-- automaticamente toda vez que alguem tenta definir/trocar uma senha em um
-- usuario associado ao profile que referencia ela (ver PASSO 2, campo
-- PASSWORD_VERIFY_FUNCTION). Ela PRECISA:
--   - retornar BOOLEAN (TRUE = senha aceita)
--   - ou lancar RAISE_APPLICATION_ERROR pra recusar com uma mensagem clara
-- Os codigos de erro (-20001, -20002, -20003) sao arbitrarios dentro da faixa
-- reservada da Oracle para erros de aplicacao (-20000 a -20999) - nao colidem
-- com nenhum erro nativo do banco (ORA-xxxxx com outros numeros).
CREATE OR REPLACE FUNCTION KAWASHI_PASSWORD_VERIFY(
    p_username     IN VARCHAR2,
    p_password     IN VARCHAR2,
    p_old_password IN VARCHAR2
) RETURN BOOLEAN AS
BEGIN
    IF LENGTH(p_password) < 12 THEN
        RAISE_APPLICATION_ERROR(-20001, 'A senha deve conter no minimo 12 caracteres.');
    END IF;

    IF INSTR(UPPER(p_password), UPPER(p_username)) > 0 THEN
        RAISE_APPLICATION_ERROR(-20002, 'A senha nao pode conter o nome do usuario.');
    END IF;

    IF NOT REGEXP_LIKE(p_password, '[A-Z]') OR       
       NOT REGEXP_LIKE(p_password, '[a-z]') OR       
       NOT REGEXP_LIKE(p_password, '[0-9]') OR       
       NOT REGEXP_LIKE(p_password, '[^A-Za-z0-9]') THEN
        RAISE_APPLICATION_ERROR(-20003, 'A senha deve conter maiuscula, minuscula, numero e caractere especial.');
    END IF;

    RETURN TRUE;
END;
/

-- #########################################################
-- PASSO 2 - PERFIL DE SEGURANÇA OPERACIONAL AJUSTADO
-- #########################################################
-- Um PROFILE e um conjunto de limites (senha + sessao) que se aplica a
-- qualquer usuario que o tiver associado (ver ALTER USER ... PROFILE nos
-- arquivos 06 e 08). Sem um profile customizado, o Oracle usa o profile
-- "DEFAULT", que praticamente nao impoe limite nenhum. O que cada linha
-- resolve, na pratica:
--   FAILED_LOGIN_ATTEMPTS 5   -> trava a conta apos 5 senhas erradas seguidas
--                                (mitiga forca bruta contra o login).
--   PASSWORD_LOCK_TIME    1/24 -> conta trancada por forca bruta destrava
--                                sozinha em 1 hora (1/24 de dia), sem
--                                precisar de um admin pra destravar manualmente.
--   PASSWORD_LIFE_TIME    90  -> senha expira a cada 90 dias (rotacao
--                                periodica obrigatoria).
--   PASSWORD_GRACE_TIME   7   -> apos expirar, da 7 dias de tolerancia pra
--                                trocar antes de bloquear de vez o acesso.
--   PASSWORD_REUSE_TIME/MAX  -> nao deixa reutilizar nenhuma das ultimas 10
--                                senhas nem repetir uma senha usada nos
--                                ultimos 365 dias (evita "trocar e voltar
--                                pra mesma senha de sempre").
--   SESSIONS_PER_USER     3  -> limita quantas conexoes simultaneas o mesmo
--                                usuario pode abrir (contem uso indevido de
--                                credencial vazada/compartilhada).
--   IDLE_TIME             30 -> derruba sessao autenticada parada ha 30 min
--                                (uma tela de terminal esquecida logada nao
--                                fica vulneravel pra sempre).
--   CONNECT_TIME          720 -> forca reconexao (e reautenticacao) a cada
--                                12 horas, mesmo que a sessao esteja ativa.
--   PASSWORD_VERIFY_FUNCTION -> amarra este profile a funcao criada no
--                                PASSO 1 acima.
CREATE PROFILE KAWASHI_SECURE_PROFILE LIMIT
    FAILED_LOGIN_ATTEMPTS      5
    PASSWORD_LOCK_TIME         1/24
    PASSWORD_LIFE_TIME         90
    PASSWORD_GRACE_TIME        7
    PASSWORD_REUSE_TIME        365
    PASSWORD_REUSE_MAX         10
    SESSIONS_PER_USER          3
    IDLE_TIME                  30
    CONNECT_TIME               720
    PASSWORD_VERIFY_FUNCTION   KAWASHI_PASSWORD_VERIFY;

-- #########################################################
-- PASSO 11 - TRILHA DE AUDITORIA UNIFICADA (ORACLE 23ai COMPLIANT)
-- #########################################################
-- "Unified Auditing" e o mecanismo de auditoria nativo e atual do Oracle
-- (substitui o "Traditional Auditing" antigo). A vantagem de usar ele em vez
-- de reinventar isso via trigger: o proprio motor do banco grava o evento no
-- catalogo interno (UNIFIED_AUDIT_TRAIL), de forma mais dificil de burlar do
-- que uma tabela normal - nem o dono do schema apaga essas linhas com um
-- DELETE comum. Isso funciona em paralelo (nao no lugar) da nossa trilha
-- propria em KAWASHI_SECURITY_LOG (arquivos 03/04/05): a auditoria unificada
-- e o "cofre" mais dificil de adulterar, e a nossa tabela e o que alimenta
-- consultas rapidas e o pipeline do SIEM no dia a dia.
CREATE AUDIT POLICY KAWASHI_UNIFIED_AUDIT_POLICY
  ACTIONS CREATE USER, ALTER USER, DROP USER, GRANT, REVOKE, LOGON, LOGOFF;

-- Uma politica de auditoria so comeca a valer depois de "ativada" - o CREATE
-- acima so define as regras, o AUDIT POLICY abaixo e o que liga o monitoramento.
AUDIT POLICY KAWASHI_UNIFIED_AUDIT_POLICY;