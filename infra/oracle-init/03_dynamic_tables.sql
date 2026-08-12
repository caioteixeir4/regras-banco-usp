-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 3 - TABELAS DE CONTROLE DINÂMICO E COMPLIANCE COMMENTS
-- #########################################################
-- Por que "dinamico"? Essas duas tabelas existem pra o trigger de logon
-- (arquivo 05) NAO precisar de IPs/ferramentas hardcoded dentro do PL/SQL.
-- Se amanha um novo IP de escritorio precisar ser liberado, e so um INSERT
-- nesta tabela - ninguem precisa recompilar/alterar o trigger nem reiniciar
-- o banco. Trocar dado por um INSERT e sempre mais seguro e mais rapido do
-- que editar codigo PL/SQL em producao.
CREATE TABLE KAWASHI_ALLOWED_IPS (
    IP_ADDRESS VARCHAR2(100) PRIMARY KEY
);

COMMENT ON TABLE KAWASHI_ALLOWED_IPS IS 'Whitelist de IPs autorizados para conexao corporativa. Gerenciada pelo time de SecOps.';

INSERT INTO KAWASHI_ALLOWED_IPS VALUES ('192.168.0.10');
INSERT INTO KAWASHI_ALLOWED_IPS VALUES ('192.168.0.11');
INSERT INTO KAWASHI_ALLOWED_IPS VALUES ('10.0.0.5');

CREATE TABLE KAWASHI_FORBIDDEN_TOOLS (
    TOOL_PATTERN VARCHAR2(100) PRIMARY KEY
);

COMMENT ON TABLE KAWASHI_FORBIDDEN_TOOLS IS 'Blacklist dinamica de ferramentas e interpretadores proibidos no ecossistema.';

INSERT INTO KAWASHI_FORBIDDEN_TOOLS VALUES ('%PYTHON%');
INSERT INTO KAWASHI_FORBIDDEN_TOOLS VALUES ('%TOAD%');
INSERT INTO KAWASHI_FORBIDDEN_TOOLS VALUES ('%SQLMAP%');
INSERT INTO KAWASHI_FORBIDDEN_TOOLS VALUES ('%EXCEL%');
COMMIT;

-- #########################################################
-- PASSO 4 - TABELAS DE LOGS DO SIEM E FALLBACK DE EMERGÊNCIA
-- #########################################################
-- Duas tabelas com propositos bem diferentes:
--   KAWASHI_SECURITY_LOG          -> trilha "feliz", onde todo evento normal
--                                     (login, DDL, warning) e registrado.
--   KAWASHI_SECURITY_LOG_FALLBACK -> rede de seguranca: se por algum motivo o
--                                     INSERT na tabela principal falhar (ex:
--                                     tablespace cheio, tabela travada), o
--                                     erro em si e registrado aqui, numa
--                                     tabela separada e mais simples, que tem
--                                     bem menos motivo pra falhar tambem.
-- A ideia de ter uma "segunda rede" e nunca deixar um problema de logging
-- silenciosamente sumir sem deixar rastro nenhum (ver PRAGMA
-- AUTONOMOUS_TRANSACTION no arquivo 04, que e o que orquestra esse fallback).
CREATE TABLE KAWASHI_SECURITY_LOG (
    ID                NUMBER GENERATED ALWAYS AS IDENTITY,
    EVENT_DATE        TIMESTAMP DEFAULT SYSTIMESTAMP,
    DB_USER           VARCHAR2(100),
    OS_USER           VARCHAR2(100),
    IP_ADDRESS        VARCHAR2(100),
    CLIENT_PROGRAM    VARCHAR2(200),
    EVENT_TYPE        VARCHAR2(100),
    DETAILS           VARCHAR2(4000)
);

COMMENT ON TABLE KAWASHI_SECURITY_LOG IS 'Trilha principal de auditoria contextual integrada ao pipeline do SIEM. Retencao de 90 dias.';

CREATE TABLE KAWASHI_SECURITY_LOG_FALLBACK (
    ID                NUMBER GENERATED ALWAYS AS IDENTITY,
    EVENT_DATE        TIMESTAMP DEFAULT SYSTIMESTAMP,
    ERROR_MSG         VARCHAR2(4000)
);

COMMENT ON TABLE KAWASHI_SECURITY_LOG_FALLBACK IS 'Tabela de contingencia isolada para armazenar erros estruturais do mecanismo de logging.';

-- Indices pensados nas perguntas que o SIEM/o time de infra realmente vai
-- fazer com frequencia: "o que aconteceu num periodo?" (DATE), "quantos
-- eventos de tipo X tivemos?" (TYPE), "esse IP fez mais alguma coisa?" (IP).
-- Sem esses indices, cada uma dessas consultas faria um full table scan na
-- tabela de log inteira - que so tende a crescer.
CREATE INDEX IDX_KAWASHI_LOG_DATE ON KAWASHI_SECURITY_LOG(EVENT_DATE);
CREATE INDEX IDX_KAWASHI_LOG_TYPE ON KAWASHI_SECURITY_LOG(EVENT_TYPE);
CREATE INDEX IDX_KAWASHI_LOG_IP   ON KAWASHI_SECURITY_LOG(IP_ADDRESS);

