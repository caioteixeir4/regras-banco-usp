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
-- PROFILE SEPARADO PARA CONTAS DE SERVIÇO/APLICAÇÃO (POOL DE CONEXÕES)
-- #########################################################
-- ACHADO TESTANDO AO VIVO (infra/tests/outros/Test-LimiteSessoesAplicacao.ps1,
-- ver item 14 de infra/docs/bugs-primeiro-teste.md): o SPRING_APP_USER usava
-- KAWASHI_SECURE_PROFILE - o mesmo profile pensado para uma PESSOA logando
-- interativamente. SESSIONS_PER_USER=3 faz sentido pra uma pessoa (ela abre
-- no maximo umas poucas conexoes ao mesmo tempo), mas e incompativel com um
-- POOL DE CONEXOES de verdade: o HikariCP (pool padrao do Spring Boot) abre
-- 10 conexoes por padrao - a aplicacao quebraria na propria inicializacao do
-- pool, nao em algum pico raro de carga.
--
-- Os limites de SESSAO de uma pessoa e de um POOL sao fundamentalmente
-- diferentes, entao a solucao nao e so "aumentar o numero" no mesmo profile -
-- e ter um profile proprio para esse tipo de conta:
--   SESSIONS_PER_USER  50        -> acomoda um pool de verdade (10) com folga
--                                   generosa (multiplas instancias da
--                                   aplicacao, picos), mas ainda um numero
--                                   FINITO - funciona como rede de seguranca
--                                   contra um bug de vazamento de conexao
--                                   crescendo sem limite nenhum.
--   IDLE_TIME          UNLIMITED -> uma conexao de POOL fica ociosa por
--                                   natureza entre requisicoes - isso e
--                                   esperado, nao um sinal de abandono como
--                                   seria numa sessao de pessoa. Reciclagem de
--                                   conexao e responsabilidade do PRÓPRIO
--                                   pool (ex: maxLifetime do HikariCP), nao do
--                                   Oracle derrubando no meio por tempo ocioso.
--   CONNECT_TIME       UNLIMITED -> pela mesma razao: uma conexao pooled pode
--                                   legitimamente viver dias - o Oracle
--                                   forcando reconexao a cada 12h (o valor do
--                                   profile de pessoa) so causaria erros
--                                   intermitentes que o pool teria que
--                                   absorver, sem ganho de seguranca real (a
--                                   credencial em si continua protegida pelo
--                                   Vault e pela politica de senha abaixo).
--   PASSWORD_LIFE_TIME UNLIMITED -> o MESMO motivo pelo qual PASSWORD EXPIRE
--                                   nunca foi aplicado nesta conta (ver item 4
--                                   de bugs-primeiro-teste.md): nao existe
--                                   humano pra responder a um prompt
--                                   interativo de troca de senha quando ela
--                                   expira sozinha aos 90 dias. A rotacao
--                                   desta credencial e responsabilidade de
--                                   quem administra o Vault, feita por
--                                   ALTER USER explicito, nao pelo relogio
--                                   automatico do profile.
-- FAILED_LOGIN_ATTEMPTS, PASSWORD_LOCK_TIME, PASSWORD_REUSE_* e
-- PASSWORD_VERIFY_FUNCTION continuam IGUAIS ao profile de pessoa - nada aqui
-- abre mao de forca de senha nem de protecao contra forca bruta, so ajusta os
-- limites que sao especificamente sobre o PADRAO DE USO (pessoa vs pool).
CREATE PROFILE KAWASHI_SERVICE_PROFILE LIMIT
    FAILED_LOGIN_ATTEMPTS      5
    PASSWORD_LOCK_TIME         1/24
    PASSWORD_LIFE_TIME         UNLIMITED
    PASSWORD_GRACE_TIME        UNLIMITED
    PASSWORD_REUSE_TIME        365
    PASSWORD_REUSE_MAX         10
    SESSIONS_PER_USER          50
    IDLE_TIME                  UNLIMITED
    CONNECT_TIME               UNLIMITED
    PASSWORD_VERIFY_FUNCTION   KAWASHI_PASSWORD_VERIFY;

-- #########################################################
-- CORREÇÃO CRÍTICA - RESOURCE_LIMIT (sem isto, 3 dos limites acima NÃO FAZEM NADA)
-- #########################################################
-- Pegadinha real do Oracle: os limites de SENHA (FAILED_LOGIN_ATTEMPTS,
-- PASSWORD_LIFE_TIME, PASSWORD_LOCK_TIME, PASSWORD_GRACE_TIME, PASSWORD_REUSE_*,
-- PASSWORD_VERIFY_FUNCTION) SEMPRE valem, nao importa nada. Mas os limites de
-- "RECURSO DE SESSAO" (SESSIONS_PER_USER, IDLE_TIME, CONNECT_TIME) so entram
-- em vigor se o parametro de sistema RESOURCE_LIMIT estiver TRUE - e o padrao
-- de fabrica do Oracle e FALSE. Ou seja: sem a linha abaixo, estivemos
-- "protegidos" contra senha fraca e forca bruta, mas SESSIONS_PER_USER=3,
-- IDLE_TIME=30 e CONNECT_TIME=720 do KAWASHI_SECURE_PROFILE estavam sendo
-- silenciosamente ignorados - nenhum erro, nenhum aviso, simplesmente nao
-- fariam efeito nenhum. E dinamico (nao precisa reiniciar o banco).
ALTER SYSTEM SET RESOURCE_LIMIT = TRUE;

-- #########################################################
-- REDE DE SEGURANÇA - hardening minimo tambem no profile DEFAULT
-- #########################################################
-- Todo usuario criado SEM especificar "PROFILE X" cai automaticamente no
-- profile "DEFAULT", que de fabrica e essencialmente sem limite nenhum. Se um
-- dia alguem (ou um script futuro) esquecer de escrever "PROFILE
-- KAWASHI_SECURE_PROFILE" na hora de criar um usuario, essa conta nasceria
-- SEM politica de senha e SEM bloqueio por tentativa - um jeito facil de
-- reintroduzir uma conta fraca sem querer. Aplicar o minimo tambem no
-- DEFAULT e uma segunda camada pra esse erro humano nao passar despercebido.
ALTER PROFILE DEFAULT LIMIT
    FAILED_LOGIN_ATTEMPTS      5
    PASSWORD_LOCK_TIME         1/24
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