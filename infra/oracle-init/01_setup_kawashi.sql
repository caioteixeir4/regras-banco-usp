-- Garante que estamos mexendo no PDB (Pluggable Database) e não na raiz.
-- Todo container Oracle "Free"/23ai nasce com uma raiz (CDB$ROOT) e um PDB de
-- aplicacao (FREEPDB1). Se esquecermos esse ALTER SESSION, os comandos abaixo
-- rodariam contra a raiz do container inteiro, nao contra o banco da Kawashi -
-- por isso TODOS os arquivos deste diretorio comecam com esta mesma linha.
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- TABLESPACES - por que separar fisicamente dados de logs?
-- #########################################################
-- Tablespace e o "arquivo fisico" onde os dados de uma tabela realmente moram.
-- Duas tabelas podem estar no mesmo schema mas em tablespaces diferentes.
-- Separamos dados de negocio dos logs de auditoria de proposito, porque isso
-- abre portas para o futuro (nao implementado ainda, mas e o motivo da separacao):
--   - Poder aplicar TDE (criptografia em repouso) so no tablespace de dados,
--     sem precisar criptografar (e pagar o custo de performance) os logs.
--   - Poder ter politica de backup/retencao diferente para log (90 dias, descartavel)
--     vs dados de negocio (retencao longa).
--   - Um log crescendo descontroladamente (ex: ataque gerando milhares de eventos)
--     nao compete por espaco/IO com as tabelas de negocio da aplicacao.

-- MAXSIZE - por que todo AUTOEXTEND ON deste projeto tem um teto? Sem MAXSIZE,
-- um datafile cresce sozinho ate esgotar o disco da maquina/VM inteira - nao
-- so trava o Oracle, derruba TODOS os containers Docker rodando ali junto
-- (o disco da VM do Docker Desktop e compartilhado). Um bug real (ex: log
-- crescendo sem parar por um ataque, ou um LOOP mal escrito) fica contido no
-- teto do proprio tablespace em vez de derrubar a maquina inteira.

-- 1. Espaco fisico onde os dados de negocio da aplicacao vao morar
CREATE TABLESPACE TS_KAWASHI_DATA
DATAFILE 'ts_kawashi_data.dbf' SIZE 50M AUTOEXTEND ON MAXSIZE 2G;

-- 2. Espaco fisico isolado exclusivamente para a trilha de auditoria (SIEM)
CREATE TABLESPACE TS_KAWASHI_SIEM_LOGS
DATAFILE 'ts_kawashi_siem.dbf' SIZE 50M AUTOEXTEND ON MAXSIZE 2G;

-- #########################################################
-- ROLES - por que usar roles em vez de dar GRANT direto pra cada usuario?
-- #########################################################
-- Uma role e um "pacote" de privilegios com nome. Em vez de repetir os mesmos
-- tres GRANTs toda vez que um novo desenvolvedor entra, concedemos a role
-- pronta pra ele. Beneficio pratico: se amanha decidirmos que todo developer
-- tambem precisa de CREATE SEQUENCE, mudamos em UM lugar (a role) e todo mundo
-- que ja tem essa role ganha o privilegio automaticamente - sem re-rodar script
-- por usuario. E tambem fica auditavel: "quem tem ROLE_KAWASHI_INFRA" e uma
-- pergunta facil de responder; "quem tem esse conjunto especifico de 6 grants
-- soltos" nao seria.

-- Role para quem escreve codigo de aplicacao/schema (times de desenvolvimento)
CREATE ROLE ROLE_KAWASHI_DEVELOPER;
GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW TO ROLE_KAWASHI_DEVELOPER;

-- Role para quem administra a infraestrutura do banco (nao o schema de negocio).
-- SELECT ANY DICTIONARY permite consultar metadados do banco inteiro (DBA_*,
-- ALL_*) para diagnostico/monitoramento, sem dar acesso aos DADOS de negocio
-- em si - e leitura de "estrutura", nao de "conteudo".
CREATE ROLE ROLE_KAWASHI_INFRA;
GRANT CREATE SESSION, SELECT ANY DICTIONARY TO ROLE_KAWASHI_INFRA;