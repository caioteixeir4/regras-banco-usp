-- Garante que a execucao ocorra no Pluggable Database correto
ALTER SESSION SET CONTAINER = FREEPDB1;

-- #########################################################
-- PASSO 22 - MAIS EXEMPLOS ILUSTRATIVOS: ORGANIZACOES, LOGIN, ADMINISTRACAO
-- #########################################################
-- ATENCAO: igual ao 11_exemplo_dominio_negocio.sql, isto NAO e o schema de
-- negocio final da Kawashi - sao exemplos minimos e ilustrativos, criados so
-- para termos mais referencia e mais material de teste do padrao "padrao +
-- servico" (ver 09_environments.sql, secao 2.1), sem aprofundar o desenho de
-- nenhum deles (decisao explicita do usuario: "nao vamos nos aprofundar em
-- nenhum esquema, so por eles pra gente ir usando como exemplos e testes").
--
-- Ideia de cada schema novo:
--
--   KAWASHI_ENV_<AMBIENTE>_ORGANIZACOES -> as empresas QUE USAM o sistema
--     Kawashi (tenants) e as filiais delas. NAO confundir com EMPRESA/FILIAL
--     do schema padrao (11_exemplo_dominio_negocio.sql) - aquelas representam
--     uma empresa do CLIENTE fiscal (quem usa o servico SEFAZ/SIMPLES_NACIONAL).
--     Sao dois conceitos de "empresa" diferentes, em schemas diferentes, sem
--     relacao nenhuma entre si.
--
--   KAWASHI_ENV_<AMBIENTE>_LOGIN -> autenticacao de pessoas. Uma pessoa pode
--     pertencer a mais de uma organizacao, com um papel diferente em cada
--     uma (ex: estagiario na organizacao A, gerente na organizacao B) - por
--     isso USUARIO e ORGANIZACOES.EMPRESA se relacionam N:N via
--     USUARIO_EMPRESA, e a pessoa escolhe COM QUAL empresa quer logar depois
--     de autenticar com email+senha. FK de volta pra ORGANIZACOES.EMPRESA -
--     mesmo padrao servico->padrao ja usado por SEFAZ/SIMPLES_NACIONAL, so
--     que aqui o "padrao" referenciado e ORGANIZACOES, nao o schema de
--     ambiente em si.
--
--   KAWASHI_ENV_<AMBIENTE>_ADMINISTRACAO -> area administrativa do PROPRIO
--     site da Kawashi, onde os clientes da Kawashi (tabela padrao CLIENTE,
--     ja existente) tem faturas e pagamentos do servico que contrataram
--     registrados. FK de volta pra CLIENTE do schema padrao - mais uma prova
--     de que o padrao e reutilizavel por qualquer servico novo sem precisar
--     mudar nada nele (mesma garantia descrita em arquitetura.md, secao 2.1).
--
-- Seguranca de LOGIN (2FA, troca de senha a cada 3 meses, etc.) citada pelo
-- usuario: aqui so entram as TABELAS que guardam esse historico/estado
-- (LOG_LOGIN, LOG_TROCA_SENHA, USUARIO.MFA_HABILITADO) - a REGRA em si
-- (forcar troca a cada 90 dias, exigir o segundo fator no login) e logica de
-- aplicacao/job, fora do escopo de uma tabela de exemplo. SENHA_HASH e so a
-- COLUNA onde o hash moraria - nenhum segredo de verdade e gravado por este
-- script (mesma filosofia do projeto inteiro de nunca guardar segredo em
-- texto puro no banco, ver Vault).
--
-- Mesma decisao de escopo de ambientes do arquivo 11: os 3 schemas (e as
-- tabelas de exemplo dentro deles) so existem em TESTE_DEV e DEV. Diferente
-- de SEFAZ/SIMPLES_NACIONAL, que ja ganharam schema "vazio" reservado nos 6
-- ambientes desde 09_environments.sql, aqui nao faria sentido reservar os
-- outros 4 ainda: nao existe (nem esta planejado) nenhum -Profile/-Servicos
-- de create-team-member.ps1 que aponte pra eles.
--
-- FORA DE ESCOPO (decisao explicita, mesmo espirito dos itens ja registrados
-- em 09_environments.sql): quem pode de fato ACESSAR estes 3 schemas (via
-- proxy ou role) ainda nao foi desenhado - nenhum -Profile ou -Servicos
-- concede acesso a eles hoje. Por enquanto existem so como exemplo/material
-- de teste de arquitetura (ver
-- infra/tests/caixa-branca/Test-InvarianteFkPadraoNuncaReferenciaServico.ps1).

-- #########################################################
-- 1. SCHEMAS - mesmo padrao NO AUTHENTICATION dos schemas de servico
-- #########################################################
CREATE USER KAWASHI_ENV_TESTE_DEV_ORGANIZACOES  NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_TESTE_DEV QUOTA UNLIMITED ON TS_KAWASHI_ENV_TESTE_DEV;
CREATE USER KAWASHI_ENV_TESTE_DEV_LOGIN         NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_TESTE_DEV QUOTA UNLIMITED ON TS_KAWASHI_ENV_TESTE_DEV;
CREATE USER KAWASHI_ENV_TESTE_DEV_ADMINISTRACAO NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_TESTE_DEV QUOTA UNLIMITED ON TS_KAWASHI_ENV_TESTE_DEV;
CREATE USER KAWASHI_ENV_DEV_ORGANIZACOES        NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_DEV       QUOTA UNLIMITED ON TS_KAWASHI_ENV_DEV;
CREATE USER KAWASHI_ENV_DEV_LOGIN               NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_DEV       QUOTA UNLIMITED ON TS_KAWASHI_ENV_DEV;
CREATE USER KAWASHI_ENV_DEV_ADMINISTRACAO       NO AUTHENTICATION DEFAULT TABLESPACE TS_KAWASHI_ENV_DEV       QUOTA UNLIMITED ON TS_KAWASHI_ENV_DEV;

GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE SEQUENCE, CREATE PROCEDURE, CREATE TRIGGER TO
    KAWASHI_ENV_TESTE_DEV_ORGANIZACOES, KAWASHI_ENV_TESTE_DEV_LOGIN, KAWASHI_ENV_TESTE_DEV_ADMINISTRACAO,
    KAWASHI_ENV_DEV_ORGANIZACOES, KAWASHI_ENV_DEV_LOGIN, KAWASHI_ENV_DEV_ADMINISTRACAO;

-- #########################################################
-- 2. ORGANIZACOES - tenants do sistema Kawashi (EMPRESA/FILIAL) + log
-- #########################################################
DECLARE
    PROCEDURE criar_tabelas_organizacoes(p_schema VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'CREATE TABLE ' || p_schema || '.EMPRESA (
            ID              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            CNPJ            VARCHAR2(14) NOT NULL UNIQUE,
            RAZAO_SOCIAL    VARCHAR2(200) NOT NULL,
            ATIVA           CHAR(1) DEFAULT ''S'' NOT NULL
        )';

        EXECUTE IMMEDIATE 'CREATE TABLE ' || p_schema || '.FILIAL (
            ID              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            EMPRESA_ID      NUMBER NOT NULL REFERENCES ' || p_schema || '.EMPRESA(ID),
            CNPJ            VARCHAR2(14) NOT NULL UNIQUE,
            NOME            VARCHAR2(150) NOT NULL
        )';

        EXECUTE IMMEDIATE 'CREATE TABLE ' || p_schema || '.LOG_ALTERACAO (
            ID              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            TABELA_ORIGEM   VARCHAR2(30) NOT NULL,
            REGISTRO_ID     NUMBER NOT NULL,
            ACAO            VARCHAR2(20) NOT NULL,
            DATA_HORA       TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
        )';
    END;
BEGIN
    criar_tabelas_organizacoes('KAWASHI_ENV_TESTE_DEV_ORGANIZACOES');
    criar_tabelas_organizacoes('KAWASHI_ENV_DEV_ORGANIZACOES');
END;
/

-- #########################################################
-- 3. LOGIN - autenticacao, multi-empresa por usuario, trilha de seguranca
-- #########################################################
-- GRANT REFERENCES + SELECT (mesmo achado do item 17 de bugs-primeiro-teste.md:
-- REFERENCES sozinho so cria a FK, nao da leitura) para LOGIN enxergar e
-- referenciar ORGANIZACOES.EMPRESA.
GRANT REFERENCES ON KAWASHI_ENV_TESTE_DEV_ORGANIZACOES.EMPRESA TO KAWASHI_ENV_TESTE_DEV_LOGIN;
GRANT REFERENCES ON KAWASHI_ENV_DEV_ORGANIZACOES.EMPRESA       TO KAWASHI_ENV_DEV_LOGIN;
GRANT SELECT ON KAWASHI_ENV_TESTE_DEV_ORGANIZACOES.EMPRESA TO KAWASHI_ENV_TESTE_DEV_LOGIN;
GRANT SELECT ON KAWASHI_ENV_DEV_ORGANIZACOES.EMPRESA       TO KAWASHI_ENV_DEV_LOGIN;

DECLARE
    PROCEDURE criar_tabelas_login(p_schema_login VARCHAR2, p_schema_org VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'CREATE TABLE ' || p_schema_login || '.USUARIO (
            ID                  NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            EMAIL               VARCHAR2(150) NOT NULL UNIQUE,
            SENHA_HASH          VARCHAR2(200) NOT NULL,
            SENHA_ALTERADA_EM   TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
            MFA_HABILITADO      CHAR(1) DEFAULT ''N'' NOT NULL,
            ATIVO               CHAR(1) DEFAULT ''S'' NOT NULL
        )';

        -- N:N: uma pessoa pode estar em varias organizacoes, com um cargo
        -- diferente em cada uma (ex: estagiario na empresa A, gerente na B).
        -- No login, depois de validar email+senha, a pessoa escolhe COM QUAL
        -- EMPRESA_ID desta tabela ela quer entrar.
        EXECUTE IMMEDIATE 'CREATE TABLE ' || p_schema_login || '.USUARIO_EMPRESA (
            ID              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            USUARIO_ID      NUMBER NOT NULL REFERENCES ' || p_schema_login || '.USUARIO(ID),
            EMPRESA_ID      NUMBER NOT NULL REFERENCES ' || p_schema_org || '.EMPRESA(ID),
            CARGO           VARCHAR2(50) NOT NULL,
            CONSTRAINT UQ_USUARIO_EMPRESA UNIQUE (USUARIO_ID, EMPRESA_ID)
        )';

        EXECUTE IMMEDIATE 'CREATE TABLE ' || p_schema_login || '.LOG_LOGIN (
            ID                      NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            USUARIO_ID              NUMBER NOT NULL REFERENCES ' || p_schema_login || '.USUARIO(ID),
            EMPRESA_ESCOLHIDA_ID    NUMBER,
            DATA_HORA               TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
            IP_ORIGEM               VARCHAR2(45),
            SUCESSO                 CHAR(1) NOT NULL
        )';

        -- Historico de troca de senha: a regra "trocar a cada 3 meses" seria
        -- aplicada consultando MAX(DATA_HORA) por usuario - a regra em si
        -- (bloquear login/forcar troca) fica fora do escopo deste exemplo.
        EXECUTE IMMEDIATE 'CREATE TABLE ' || p_schema_login || '.LOG_TROCA_SENHA (
            ID              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            USUARIO_ID      NUMBER NOT NULL REFERENCES ' || p_schema_login || '.USUARIO(ID),
            DATA_HORA       TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
        )';
    END;
BEGIN
    criar_tabelas_login('KAWASHI_ENV_TESTE_DEV_LOGIN', 'KAWASHI_ENV_TESTE_DEV_ORGANIZACOES');
    criar_tabelas_login('KAWASHI_ENV_DEV_LOGIN', 'KAWASHI_ENV_DEV_ORGANIZACOES');
END;
/

-- #########################################################
-- 4. ADMINISTRACAO - faturamento dos clientes do sistema Kawashi
-- #########################################################
-- FK de volta pro CLIENTE do schema PADRAO (11_exemplo_dominio_negocio.sql) -
-- o mesmo CLIENTE que SEFAZ ja referencia. Prova que o padrao e reutilizavel
-- por qualquer servico novo (incluindo um que nao e fiscal) sem mudar nada
-- nele.
GRANT REFERENCES ON KAWASHI_ENV_TESTE_DEV.CLIENTE TO KAWASHI_ENV_TESTE_DEV_ADMINISTRACAO;
GRANT REFERENCES ON KAWASHI_ENV_DEV.CLIENTE       TO KAWASHI_ENV_DEV_ADMINISTRACAO;
GRANT SELECT ON KAWASHI_ENV_TESTE_DEV.CLIENTE TO KAWASHI_ENV_TESTE_DEV_ADMINISTRACAO;
GRANT SELECT ON KAWASHI_ENV_DEV.CLIENTE       TO KAWASHI_ENV_DEV_ADMINISTRACAO;

DECLARE
    PROCEDURE criar_tabelas_administracao(p_schema_adm VARCHAR2, p_schema_padrao VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'CREATE TABLE ' || p_schema_adm || '.FATURA (
            ID              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            CLIENTE_ID      NUMBER NOT NULL REFERENCES ' || p_schema_padrao || '.CLIENTE(ID),
            COMPETENCIA     DATE NOT NULL,
            VALOR           NUMBER(12,2) NOT NULL,
            STATUS          VARCHAR2(20) DEFAULT ''ABERTA'' NOT NULL
        )';

        EXECUTE IMMEDIATE 'CREATE TABLE ' || p_schema_adm || '.PAGAMENTO (
            ID                  NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            FATURA_ID           NUMBER NOT NULL REFERENCES ' || p_schema_adm || '.FATURA(ID),
            DATA_PAGAMENTO      DATE NOT NULL,
            VALOR_PAGO          NUMBER(12,2) NOT NULL,
            FORMA_PAGAMENTO     VARCHAR2(30) NOT NULL
        )';
    END;
BEGIN
    criar_tabelas_administracao('KAWASHI_ENV_TESTE_DEV_ADMINISTRACAO', 'KAWASHI_ENV_TESTE_DEV');
    criar_tabelas_administracao('KAWASHI_ENV_DEV_ADMINISTRACAO', 'KAWASHI_ENV_DEV');
END;
/

-- #########################################################
-- Mapa de FKs cruzadas resultante (todas SERVICO -> PADRAO, nunca o inverso -
-- ver infra/tests/caixa-branca/Test-InvarianteFkPadraoNuncaReferenciaServico.ps1):
--
--   LOGIN.USUARIO_EMPRESA.EMPRESA_ID -> ORGANIZACOES.EMPRESA.ID
--   ADMINISTRACAO.FATURA.CLIENTE_ID  -> <ambiente>.CLIENTE.ID  (schema padrao)
--   SEFAZ.CONFIGURACAO_FISCAL.CLIENTE_ID -> <ambiente>.CLIENTE.ID (ja existia)
-- #########################################################
