-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 21 - FIXTURE MINIMA DO PADRAO "TABELA PADRAO + SCHEMA DE SERVICO"
-- #########################################################
-- ATENCAO: isto NAO e dominio de negocio. Este repositorio guarda as REGRAS
-- do banco (hardening, ambientes, RBAC, auditoria, onboarding); as tabelas de
-- negocio e a API do banco vivem em um repositorio separado. O que sobra aqui
-- e a menor fixture possivel pra os testes de CONTRATO deste repositorio terem
-- o que exercitar - duas tabelas, nada alem disso:
--
--   KAWASHI_ENV_<AMB>.CLIENTE                       -> tabela PADRAO (visivel a
--                                                      qualquer pessoa com acesso ao ambiente)
--   KAWASHI_ENV_<AMB>_SEFAZ.CONFIGURACAO_FISCAL     -> tabela de SERVICO, com FK de volta
--                                                      pro padrao (visivel so a quem tem
--                                                      liberacao pra SEFAZ)
--
-- Quem usa esta fixture:
--   infra/tests/caixa-preta/Test-SegmentacaoPorServico.ps1
--   infra/tests/caixa-preta/Test-ConcessaoServicoUsuarioExistente.ps1
--   infra/tests/caixa-branca/Test-InvarianteFkPadraoNuncaReferenciaServico.ps1
--
-- O que NAO esta mais aqui (ENDERECO, CONTATO, EMPRESA, FILIAL, SOCIO e os
-- schemas ORGANIZACOES / LOGIN / ADMINISTRACAO): saiu na separacao entre
-- repositorio de regras e repositorio de tabelas. A versao completa de antes
-- da separacao (11_exemplo_dominio_negocio.sql + 12_exemplo_dominio_kawashi_core.sql)
-- esta preservada na tag git "dominio-completo-pre-separacao" - nada foi
-- perdido, so mudou de lugar. Ver README.md, secao "Escopo deste repositorio".
--
-- Por que so em TESTE_DEV e DEV, nao nos outros 4 ambientes (TESTE_INFRA,
-- INFRA, HOMOLOG, PROD)? Porque uma tabela nova nasce no ambiente de trabalho
-- de quem a criou e se propaga pelos outros ambientes CONFORME E PROMOVIDA -
-- esse mecanismo de propagacao/sincronizacao de estrutura entre ambientes e
-- um problema a parte (migracao de schema, tipo Flyway/Liquibase), fora do
-- escopo por decisao explicita. Os schemas de servico dos outros ambientes ja
-- existem (criados em 09_environments.sql), vazios, prontos pra quando alguem
-- promover algo pra la.
DECLARE
    PROCEDURE criar_tabela_padrao_cliente(p_schema VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'CREATE TABLE ' || p_schema || '.CLIENTE (
            ID              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            CNPJ            VARCHAR2(14) NOT NULL UNIQUE,
            RAZAO_SOCIAL    VARCHAR2(200) NOT NULL
        )';
    END;
BEGIN
    criar_tabela_padrao_cliente('KAWASHI_ENV_TESTE_DEV');
    criar_tabela_padrao_cliente('KAWASHI_ENV_DEV');
END;
/

-- #########################################################
-- GRANT REFERENCES + SELECT - habilita os schemas de SERVICO a terem FK pro
-- padrao E a de fato LEREM as tabelas padrao (ex: fazer JOIN)
-- #########################################################
-- So pode ser concedido agora que a tabela padrao existe de verdade (ver
-- nota em 09_environments.sql, secao 2.1). Sem REFERENCES, o CREATE TABLE
-- com "REFERENCES KAWASHI_ENV_DEV.CLIENTE" abaixo falharia com ORA-01031.
--
-- CORRIGIDO (achado testando ao vivo logo apos a primeira subida deste
-- esquema, item 17 de infra/docs/bugs-primeiro-teste.md): REFERENCES so
-- habilita CRIAR a constraint de FK - NAO da privilegio de LEITURA nenhum.
-- Um Desenvolvedor proxyado em KAWASHI_ENV_DEV_SEFAZ conseguia criar
-- CONFIGURACAO_FISCAL com a FK, mas um SELECT (inclusive o JOIN que e o
-- proprio motivo da FK existir) contra KAWASHI_ENV_DEV.CLIENTE falhava com
-- "ORA-41900: missing READ privilege" - o padrao "servico referenciando E
-- lendo a tabela padrao" nao funcionava sem este GRANT SELECT adicional,
-- independente do REFERENCES. Concedido em TODAS as tabelas padrao do
-- ambiente (nao so CLIENTE) - a regra e que servico enxerga o padrao inteiro,
-- mesmo sem FK direta em todas elas.
--
-- ATENCAO (ponto em aberto da separacao): este bloco roda UMA vez, no 1o
-- boot. Tabelas padrao criadas DEPOIS dele (pelo repositorio de tabelas) nao
-- recebem GRANT SELECT automaticamente - quem aplicar o repositorio de tabelas
-- precisa reaplicar esta regra apos criar tabelas padrao novas. Onde essa
-- regra vai morar (aqui, exposta como procedure, ou la) ainda nao foi decidido.
GRANT REFERENCES ON KAWASHI_ENV_TESTE_DEV.CLIENTE TO KAWASHI_ENV_TESTE_DEV_SEFAZ;
GRANT REFERENCES ON KAWASHI_ENV_DEV.CLIENTE       TO KAWASHI_ENV_DEV_SEFAZ;

BEGIN
    FOR t IN (SELECT table_name FROM dba_tables WHERE owner = 'KAWASHI_ENV_TESTE_DEV') LOOP
        EXECUTE IMMEDIATE 'GRANT SELECT ON KAWASHI_ENV_TESTE_DEV.' || t.table_name || ' TO KAWASHI_ENV_TESTE_DEV_SEFAZ';
    END LOOP;
    FOR t IN (SELECT table_name FROM dba_tables WHERE owner = 'KAWASHI_ENV_DEV') LOOP
        EXECUTE IMMEDIATE 'GRANT SELECT ON KAWASHI_ENV_DEV.' || t.table_name || ' TO KAWASHI_ENV_DEV_SEFAZ';
    END LOOP;
END;
/

-- #########################################################
-- Tabela de SERVICO da fixture (SEFAZ) - FK de volta pro padrao
-- #########################################################
-- Ilustra o padrao "sefaz.configuracao_fiscal" com chave estrangeira pra
-- tabela padrao de cliente. So quem tiver a liberacao de servico SEFAZ (ver
-- create-team-member.ps1 -Servicos / grant-service-access.ps1) enxerga esta
-- tabela - mesmo estando "dentro" do mesmo ambiente que todo mundo ja acessa.
DECLARE
    PROCEDURE criar_tabela_servico_sefaz(p_schema_padrao VARCHAR2, p_schema_sefaz VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'CREATE TABLE ' || p_schema_sefaz || '.CONFIGURACAO_FISCAL (
            ID                   NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            CLIENTE_ID           NUMBER NOT NULL REFERENCES ' || p_schema_padrao || '.CLIENTE(ID),
            REGIME_TRIBUTARIO    VARCHAR2(50) NOT NULL,
            INSCRICAO_ESTADUAL   VARCHAR2(20)
        )';
    END;
BEGIN
    criar_tabela_servico_sefaz('KAWASHI_ENV_TESTE_DEV', 'KAWASHI_ENV_TESTE_DEV_SEFAZ');
    criar_tabela_servico_sefaz('KAWASHI_ENV_DEV', 'KAWASHI_ENV_DEV_SEFAZ');
END;
/
