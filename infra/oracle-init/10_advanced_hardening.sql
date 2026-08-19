-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 18 - PROTECAO CONTRA FORCA BRUTA NA CAMADA DE PROTOCOLO
-- #########################################################
-- Diferente do FAILED_LOGIN_ATTEMPTS do KAWASHI_SECURE_PROFILE (que tranca a
-- CONTA apos N tentativas, mas cada tentativa pode vir de uma conexao TCP
-- nova), SEC_MAX_FAILED_LOGIN_ATTEMPTS derruba a PROPRIA CONEXAO/protocolo
-- apos N senhas erradas dentro da mesma sessao de rede aberta. Isso contem um
-- script tentando varias senhas seguidas numa unica conexao, antes mesmo de
-- qualquer logica de profile entrar em jogo - uma camada a mais, nao uma
-- substituta da que ja existe.
--
-- SCOPE=SPFILE (nao BOTH): este parametro tem comportamento que varia por
-- versao do Oracle quanto a poder ser alterado em memoria; SPFILE e o modo
-- seguro (grava na configuracao persistente, exige um restart do banco pra
-- valer - o que ja acontece naturalmente quando o container for recriado).
--
-- CORRIGIDO (achado testando ao vivo): este parametro e de escopo do CDB
-- inteiro, nao do PDB - tentar setar de dentro do FREEPDB1 (todo arquivo
-- deste projeto comeca com ALTER SESSION SET CONTAINER = FREEPDB1) falha com
-- ORA-65040 ("Operation is not allowed from within a pluggable database").
-- Por isso trocamos pro CDB$ROOT so para este comando, e voltamos pro PDB
-- logo em seguida (o resto deste arquivo continua operando no FREEPDB1).
ALTER SESSION SET CONTAINER = CDB$ROOT;
ALTER SYSTEM SET SEC_MAX_FAILED_LOGIN_ATTEMPTS = 3 SCOPE = SPFILE;
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 19 - PURGA AUTOMATICA DO UNIFIED AUDIT TRAIL
-- #########################################################
-- A politica de auditoria nativa criada no 02_global_hardening.sql
-- (KAWASHI_UNIFIED_AUDIT_POLICY) grava eventos no catalogo interno do Oracle
-- (UNIFIED_AUDIT_TRAIL, fisicamente dentro do tablespace SYSAUX) - mas sem
-- configurar isto, ela NUNCA purga sozinha. Diferente da nossa
-- KAWASHI_SECURITY_LOG (que ja tem purge de 90 dias no 07_maintenance_jobs.sql),
-- a trilha nativa do Oracle cresceria pra sempre dentro de um tablespace de
-- sistema - o mesmo problema de "disco cheio derruba tudo" que resolvemos
-- com MAXSIZE nas nossas proprias tablespaces, so que aqui dentro do SYSAUX.
--
-- Isto usa o pacote DBMS_AUDIT_MGMT, que e sensivel a versao/edicao do Oracle
-- e nunca foi executado contra este ambiente ainda - por isso cada etapa esta
-- protegida com WHEN OTHERS que REGISTRA o erro (via KAWASHI_WRITE_SECURITY_LOG,
-- ja disponivel a esta altura do bootstrap) em vez de abortar o restante do
-- script. Se algo aqui falhar, verifique KAWASHI_SECURITY_LOG pelo evento
-- 'AUDIT_MGMT_SETUP_ERROR' e ajuste manualmente - a trilha de auditoria em si
-- continua funcionando normalmente mesmo se a purga automatica nao configurar.

-- 19.1 - Inicializa o gerenciamento de purga para o Unified Audit Trail
BEGIN
    DBMS_AUDIT_MGMT.INIT_CLEANUP(
        audit_trail_type         => DBMS_AUDIT_MGMT.AUDIT_TRAIL_UNIFIED,
        default_cleanup_interval => 24  -- horas entre cada purga automatica
    );
EXCEPTION
    WHEN OTHERS THEN
        KAWASHI_WRITE_SECURITY_LOG(
            'AUDIT_MGMT_SETUP_ERROR',
            'Falha ao inicializar DBMS_AUDIT_MGMT.INIT_CLEANUP (pode ja estar inicializado, ou incompativel com esta edicao/versao). Erro: ' || SQLERRM
        );
END;
/

-- 19.2 - Define a janela de retencao: tudo com mais de 90 dias vira elegivel
-- pra purga (mesma politica de retencao da KAWASHI_SECURITY_LOG, por consistencia).
BEGIN
    DBMS_AUDIT_MGMT.SET_LAST_ARCHIVE_TIMESTAMP(
        audit_trail_type  => DBMS_AUDIT_MGMT.AUDIT_TRAIL_UNIFIED,
        last_archive_time => SYSTIMESTAMP - INTERVAL '90' DAY
    );
EXCEPTION
    WHEN OTHERS THEN
        KAWASHI_WRITE_SECURITY_LOG(
            'AUDIT_MGMT_SETUP_ERROR',
            'Falha ao definir SET_LAST_ARCHIVE_TIMESTAMP para o Unified Audit Trail. Erro: ' || SQLERRM
        );
END;
/

-- 19.3 - Cria o job que efetivamente purga, rodando 1x por dia
BEGIN
    DBMS_AUDIT_MGMT.CREATE_PURGE_JOB(
        audit_trail_type           => DBMS_AUDIT_MGMT.AUDIT_TRAIL_UNIFIED,
        audit_trail_purge_interval => 24,
        audit_trail_purge_name     => 'KAWASHI_UNIFIED_AUDIT_PURGE_JOB',
        use_last_arch_timestamp    => TRUE
    );
EXCEPTION
    WHEN OTHERS THEN
        KAWASHI_WRITE_SECURITY_LOG(
            'AUDIT_MGMT_SETUP_ERROR',
            'Falha ao criar o job de purga do Unified Audit Trail (pode ja existir). Erro: ' || SQLERRM
        );
END;
/

-- #########################################################
-- PASSO 20 - REVOGAR PACOTES PERIGOSOS DE PUBLIC
-- #########################################################
-- O Oracle, de fabrica, concede EXECUTE em varios pacotes de rede/arquivo/Java
-- pra role PUBLIC (ou seja, TODO usuario do banco, sem excecao, ja pode usar
-- eles por padrao). Historicamente, esses sao os pacotes mais usados em
-- ataques de escalonamento de privilegio e exfiltracao via SQL Injection em
-- Oracle: UTL_HTTP/UTL_TCP fazem o banco abrir conexoes de rede pra fora
-- (SSRF - um atacante que so consegue injetar SQL pode usar isso pra escanear
-- a rede interna ou vazar dado via requisicao HTTP), UTL_SMTP manda e-mail
-- arbitrario a partir do servidor de banco, UTL_INADDR resolve DNS (outro
-- canal de exfiltracao), UTL_FILE le/escreve arquivo no disco do servidor se
-- um DIRECTORY object estiver mal configurado, e DBMS_JAVA permite rodar
-- codigo Java dentro do banco.
--
-- Nada do que construimos ate agora (nenhuma role, nenhum ambiente) depende
-- de nenhum desses pacotes - por isso e seguro revogar de PUBLIC agora. Se
-- algum dia uma feature de verdade precisar de um deles (ex: enviar e-mail
-- via UTL_SMTP), o certo e conceder EXECUTE pra uma ROLE especifica (ex:
-- KAWASHI_READWRITE), nunca de volta pra PUBLIC.
--
-- Protegido com WHEN OTHERS porque nem todo pacote existe em toda instalacao
-- (depende de quais componentes Oracle vieram habilitados na imagem) - um
-- REVOKE de algo que nao existe (ORA-04043) so e registrado, nao trava o boot.
DECLARE
    PROCEDURE revoke_public_execute(p_package VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'REVOKE EXECUTE ON ' || p_package || ' FROM PUBLIC';
    EXCEPTION
        WHEN OTHERS THEN
            KAWASHI_WRITE_SECURITY_LOG(
                'PUBLIC_REVOKE_SKIPPED',
                'Nao foi possivel revogar EXECUTE ON ' || p_package || ' FROM PUBLIC (provavelmente o pacote nao existe nesta instalacao). Erro: ' || SQLERRM
            );
    END;
BEGIN
    revoke_public_execute('UTL_HTTP');
    revoke_public_execute('UTL_TCP');
    revoke_public_execute('UTL_SMTP');
    revoke_public_execute('UTL_INADDR');
    revoke_public_execute('UTL_FILE');
    revoke_public_execute('DBMS_JAVA');
    revoke_public_execute('DBMS_JAVA_TEST');
END;
/
