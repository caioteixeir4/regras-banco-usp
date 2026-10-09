-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 21 - EXEMPLO ILUSTRATIVO DO PADRAO "TABELAS PADRAO + SCHEMA DE SERVICO"
-- #########################################################
-- ATENCAO: isto NAO e o schema de negocio final da Kawashi - e um exemplo
-- minimo, concreto e testavel (infra/tests/caixa-preta/Test-SegmentacaoPorServico.ps1)
-- pra provar que o padrao de segmentacao descrito em 09_environments.sql
-- (secao 2.1) funciona de verdade: tabelas PADRAO (compartilhadas, visiveis a
-- qualquer pessoa com acesso ao ambiente) e tabelas de SERVICO (especificas
-- de um dominio fiscal, com FK de volta pro padrao, visiveis so a quem tem
-- liberacao extra pra aquele servico). O desenho de verdade do dominio de
-- negocio sera feito quando o microsservico real for construido.
--
-- Por que so em TESTE_DEV e DEV, nao nos outros 4 ambientes (TESTE_INFRA,
-- INFRA, HOMOLOG, PROD)? Porque uma tabela nova nasce no ambiente de trabalho
-- de quem a criou e se propaga pelos outros ambientes CONFORME E PROMOVIDA -
-- esse mecanismo de propagacao/sincronizacao de estrutura entre ambientes e
-- um problema a parte (migracao de schema, tipo Flyway/Liquibase), fora do
-- escopo desta rodada por decisao explicita. Pre-popular HOMOLOG/PROD com a
-- mesma tabela de exemplo hoje contradiria esse fluxo futuro - os schemas de
-- servico desses ambientes ja existem (criados em 09_environments.sql),
-- vazios, prontos para quando alguem promover algo pra la.
--
-- Tabelas padrao (dados cadastrais basicos, usados por qualquer servico):
--   CLIENTE  -> identificado por CNPJ, e a tabela central que os servicos referenciam
--   ENDERECO -> 1 cliente pode ter varios enderecos
--   CONTATO  -> 1 cliente pode ter varios contatos
--   EMPRESA  -> uma empresa do cliente (um cliente pode ter mais de uma empresa)
--   FILIAL   -> filiais de uma empresa
--   SOCIO    -> socios de uma empresa
DECLARE
    PROCEDURE criar_tabelas_padrao(p_schema VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'CREATE TABLE ' || p_schema || '.CLIENTE (
            ID              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            CNPJ            VARCHAR2(14) NOT NULL UNIQUE,
            RAZAO_SOCIAL    VARCHAR2(200) NOT NULL
        )';

        EXECUTE IMMEDIATE 'CREATE TABLE ' || p_schema || '.ENDERECO (
            ID              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            CLIENTE_ID      NUMBER NOT NULL REFERENCES ' || p_schema || '.CLIENTE(ID),
            LOGRADOURO      VARCHAR2(200),
            CIDADE          VARCHAR2(100),
            UF              CHAR(2),
            CEP             VARCHAR2(8)
        )';

        EXECUTE IMMEDIATE 'CREATE TABLE ' || p_schema || '.CONTATO (
            ID              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            CLIENTE_ID      NUMBER NOT NULL REFERENCES ' || p_schema || '.CLIENTE(ID),
            NOME            VARCHAR2(150),
            EMAIL           VARCHAR2(150),
            TELEFONE        VARCHAR2(20)
        )';

        EXECUTE IMMEDIATE 'CREATE TABLE ' || p_schema || '.EMPRESA (
            ID              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            CLIENTE_ID      NUMBER NOT NULL REFERENCES ' || p_schema || '.CLIENTE(ID),
            CNPJ            VARCHAR2(14) NOT NULL UNIQUE,
            RAZAO_SOCIAL    VARCHAR2(200) NOT NULL
        )';

        EXECUTE IMMEDIATE 'CREATE TABLE ' || p_schema || '.FILIAL (
            ID              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            EMPRESA_ID      NUMBER NOT NULL REFERENCES ' || p_schema || '.EMPRESA(ID),
            CNPJ            VARCHAR2(14) NOT NULL UNIQUE,
            NOME            VARCHAR2(150) NOT NULL
        )';

        EXECUTE IMMEDIATE 'CREATE TABLE ' || p_schema || '.SOCIO (
            ID              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            EMPRESA_ID      NUMBER NOT NULL REFERENCES ' || p_schema || '.EMPRESA(ID),
            NOME            VARCHAR2(150) NOT NULL,
            CPF             VARCHAR2(11) NOT NULL
        )';
    END;
BEGIN
    criar_tabelas_padrao('KAWASHI_ENV_TESTE_DEV');
    criar_tabelas_padrao('KAWASHI_ENV_DEV');
END;
/

-- #########################################################
-- GRANT REFERENCES + SELECT - habilita os schemas de SERVICO a terem FK pro
-- padrao E a de fato LEREM as tabelas padrao (ex: fazer JOIN)
-- #########################################################
-- So pode ser concedido agora que as tabelas padrao existem de verdade (ver
-- nota em 09_environments.sql, secao 2.1). Sem REFERENCES, o CREATE TABLE
-- com "REFERENCES KAWASHI_ENV_DEV.CLIENTE" abaixo falharia com ORA-01031.
--
-- CORRIGIDO (achado testando ao vivo logo apos a primeira subida deste
-- esquema): REFERENCES so habilita CRIAR a constraint de FK - NAO da
-- privilegio de LEITURA nenhum. Um Desenvolvedor proxyado em
-- KAWASHI_ENV_DEV_SEFAZ conseguia criar CONFIGURACAO_FISCAL com a FK, mas
-- um SELECT (inclusive o JOIN que e o proprio motivo da FK existir) contra
-- KAWASHI_ENV_DEV.CLIENTE falhava com "ORA-41900: missing READ privilege" -
-- exatamente o padrao padrao+servico descrito pelo usuario (servico
-- referenciando E lendo a tabela padrao) nao funcionava sem este GRANT
-- SELECT adicional, independente do REFERENCES. Concedido em TODAS as
-- tabelas padrao do ambiente (nao so CLIENTE) - a ideia e que servico
-- enxergue o padrao inteiro, mesmo sem FK direta em todas elas.
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
-- Tabela de SERVICO de exemplo (SEFAZ) - FK de volta pro padrao
-- #########################################################
-- Ilustra exatamente o padrao descrito pelo usuario: "sefaz.configuracao_fiscal"
-- com chave estrangeira pra tabela padrao de cliente. So quem tiver a
-- liberacao de servico SEFAZ (ver create-team-member.ps1 -Servicos) enxerga
-- esta tabela - mesmo estando "dentro" do mesmo ambiente que todo mundo ja
-- acessa.
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
