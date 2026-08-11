# Kawashi Sistemas - Infrastructure & SIEM Fortress 🏯

Este repositório contém a infraestrutura de segurança e o sistema de monitoramento (SIEM) 
focado em banco de dados para a Kawashi Sistemas.

## 🚀 Arquitetura Geral
O projeto utiliza um modelo de defesa em camadas (Defense in Depth) para proteger 
ativos de dados críticos.

## 📋 Master Blueprint (To-Do List)

1. Camada de Infraestrutura e Banco de Dados (O Bunker)
[ ] Setup de 5 Bases: Criar e isolar os ambientes (Teste, Desenvolvimento, Infra, Homologação e Produção).
[ ] TDE (Transparent Data Encryption): Configurar criptografia em repouso no nível de Tablespace para o "balde" do Java.
[ ] Data Redaction: Configurar máscaras em tempo real (ex: ocultar dígitos de CPF/Cartão) baseadas na Role do usuário.
[ ] VPD (Virtual Private Database): Criar políticas para que a equipe de infra nunca veja linhas de dados de documentos de negócio.
[ ] Confidential Computing: Pesquisar o uso de Enclaves (Intel SGX) para processar dados na RAM de forma isolada.

2. Camada de Identidade e Acesso (As Chaves)
[ ] Secret Management (Vault): Integrar com HashiCorp Vault. Nenhuma senha fica no application.properties.
[ ] Dynamic Credentials: Configurar o Vault para gerar senhas que expiram em curto prazo para o microserviço.
[ ] Zero Trust & MFA: Exigir segundo fator de autenticação para qualquer humano que tente acessar a base de Produção.
[ ] RBAC (Role-Based Access Control): Definir perfis estritos (App_Bot, Dev_User, Infra_Admin).

3. Camada de Processo e Governança (O Gatekeeper)
[ ] Main Protection: Bloquear a branch main. Apenas o Engenheiro de Software faz o merge.
[ ] SQL Linter no CI/CD: Script que valida se o .sql dos desenvolvedores usa o Tablespace correto e não tem comandos proibidos.
[ ] Deploy Automatizado: O robô de CI/CD é o único com permissão de escrita estrutural (DDL) em Produção.

4. Camada de Monitoramento e Inteligência (O SIEM)
[ ] Honeytables (Armadilhas): Criar tabelas isca (ex: ADMIN_SALARIES) e monitorar qualquer SELECT neles.
[ ] Audit de DDL: Alerta crítico se um humano rodar CREATE/ALTER/DROP manualmente.
[ ] UBA (User Behavior Analytics): Criar log de comportamento para detectar acessos em horários ou locais anômalos.
[ ] SQL Watermarking: Inserir "marcas d'água" digitais nos dados exportados para rastrear a origem de possíveis vazamentos.
[ ] WORM Logs (Imutabilidade): Enviar logs de auditoria para um storage externo onde ninguém (nem o DBA) possa apagar.

5. Camada de Resposta e Resiliência (O Escudo Ativo)
[ ] Database Firewall: Interceptar queries no Spring para bloquear padrões de SQL Injection em tempo real.
[ ] Rate Limiting: Bloquear usuários que tentem baixar um volume de dados desproporcional (Anti-Scraping).
[ ] SOAR (Auto-Ban): Programar o SIEM para revogar o acesso de usuários que tocarem nas Honeytables.
[ ] Kill Switch: Criar um comando de emergência para isolar o banco de dados em caso de ataque massivo detectado.
[ ] Backup Health Check: Monitorar se os backups off-site estão sendo feitos e se o PITR (Point-in-Time Recovery) está funcional.

6. Camada Avançada (The Future)
[ ] Homomorphic Encryption: Estudar a implementação de cálculos matemáticos em campos criptografados sem abrir os dados.

Technical Debts
No ambiente de dev, o mlock do Vault foi desativado por limitações do Docker Desktop. Reativar em ambiente Linux de produção.

## ⚠️ Observações de Infraestrutura

### Vault — versão fixada em 1.15.6
Versões mais recentes do Vault (1.16+) utilizam `CAP_SETFCAP` no entrypoint,
uma Linux capability bloqueada pelo Docker Desktop no Windows/WSL2.
Isso causa crash silencioso do container sem mensagem de erro clara.

**Não alterar para `latest`** até confirmar compatibilidade com o ambiente de desenvolvimento.
Para atualizar, testar localmente e fixar numa versão específica (ex: `1.19.2`), nunca `latest`.
