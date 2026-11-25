# Pesquisa: VPD, enclaves, criptografia homomórfica e marca d'água nos dados

Pesquisa de 24/11/2026 sobre os quatro itens de "pesquisa" do roadmap (README, seções 2 e 6), olhando
para o cenário do projeto: **tudo roda localmente, em Docker**, num computador comum, com Oracle Free
(`gvenzl/oracle-free`, versão 23.26.1 no contêiner), Vault, a API e o BFF em Java. Para cada tema: o
que é, o que resolveria aqui, se dá para fazer nesse cenário e a recomendação.

| Tema | Funciona aqui? | Recomendação |
|---|---|---|
| VPD (segurança por linha no Oracle) | **Sim, testado** no contêiner | Implementar: segunda barreira do isolamento entre empresas e "infra não vê linha de negócio" |
| Enclaves (computação confidencial) | Não num computador comum | Trabalho futuro; registrar o porquê no TCC |
| Criptografia homomórfica | Só como demonstração separada | Demonstração pequena, fora do caminho principal |
| Marca d'água nos dados | Sim, na aplicação | Implementar junto com a exportação de dados e com as tabelas isca |

---

## 1. VPD (Virtual Private Database)

**O que é.** O Oracle acrescenta sozinho um filtro (`WHERE`) a toda consulta numa tabela protegida. O
filtro vem de uma função de política, registrada com o pacote `DBMS_RLS`; quem consulta não consegue
tirar o filtro, nem com `SELECT *`. Exige o privilégio `EXECUTE` no `DBMS_RLS` para criar a política.

**Teste feito no nosso banco (24/11/2026).** Com usuários e tabela descartáveis: tabela com uma linha
da empresa 1 e uma da empresa 2, política que devolve `EMPRESA_ID = 1` para o usuário leitor.
Resultado: `v$option` mostra "Fine-grained access control" = `TRUE`; `DBMS_RLS.ADD_POLICY` funcionou; o
leitor viu **1 linha** ("da empresa 1") consultando a tabela inteira, enquanto o SYS viu 2. Tudo
apagado no fim. A documentação não deixava claro se a edição Free tem o recurso; o teste deixa.

**O que resolveria aqui.**
- **Segunda barreira do isolamento entre empresas.** Hoje quem garante que uma empresa não vê a outra
  é a API (`Autorizacao.conferirEmpresa`, 404). Com VPD, mesmo que a API esqueça a conferência num
  caminho novo, o banco só devolve as linhas da empresa da sessão. A API passaria a empresa ao banco
  a cada pedido, num contexto de aplicação (`DBMS_SESSION.SET_CONTEXT`) que só um pacote confiável
  pode gravar; a política leria esse contexto. Cuidado: com pool de conexões, o contexto tem de ser
  gravado no começo e limpo no fim de todo pedido, senão um pedido herda a empresa do anterior.
- **"A equipe de infra nunca vê linha de negócio"** (item do roadmap): a política devolve `1 = 0`
  para os perfis de infra (`EstagiarioInfra`, `Infra`) nas tabelas de cadastro. Eles continuam vendo
  a estrutura, as estatísticas e os logs técnicos.

**Limites.** O `SYS` e quem tem `EXEMPT ACCESS POLICY` não passam pelo filtro (por isso o teste viu 2
linhas como SYS). A política custa um pouco em cada consulta (o filtro entra no plano). Os dados
cifrados pela API continuam cifrados: o VPD decide **quais linhas**, a cifra decide **o que dá para
ler** nelas.

**Recomendação:** implementar. É a defesa mais concreta das quatro, roda no ambiente atual, e encaixa
no TCC como "defesa em profundidade" (a mesma regra na aplicação e no banco).

## 2. Enclaves (computação confidencial)

**O que é.** O processador cria uma área de memória cifrada (enclave ou máquina virtual confidencial)
que nem o sistema operacional, nem o hipervisor, nem o administrador da máquina conseguem ler. Os dados
ficam protegidos **durante o uso**, não só guardados e em trânsito. As tecnologias atuais:
- **Intel SGX**: enclaves dentro de um processo. Foi descontinuado nos processadores de computador
  pessoal em 2021 e continua só nos Xeon de servidor; a Intel concentrou o roteiro no TDX, e a geração
  Diamond Rapids será a última com SGX.
- **Intel TDX e AMD SEV-SNP**: a máquina virtual inteira é confidencial. Exigem processadores de servidor
  e suporte do hipervisor; são o que os provedores de nuvem oferecem (o Google Cloud e a AWS usam o
  SEV-SNP).
- **Contêineres confidenciais** (projeto Confidential Containers): rodam contêineres dentro dessas
  máquinas virtuais; o suporte ainda é desigual entre as tecnologias.

**Dá para fazer aqui?** Não. Num computador comum com Docker Desktop não há SGX nem TDX/SEV-SNP
disponíveis, e o Oracle não roda dentro de um enclave. Só numa nuvem com máquinas virtuais
confidenciais, o que foge da decisão de rodar tudo localmente.

**Recomendação:** trabalho futuro. Vale registrar no TCC a ameaça que isso cobriria (alguém com acesso
total à máquina lendo a memória do banco ou da API) e que, no projeto, ela é mitigada em parte pela
cifra na aplicação: o banco nunca vê CPF, e-mail e telefone em claro, e as chaves ficam fora dele.

## 3. Criptografia homomórfica

**O que é.** Permite fazer contas **sobre dados cifrados** sem decifrar: o servidor soma ou multiplica
os valores cifrados e só quem tem a chave vê o resultado. Os esquemas mais usados são o BFV/BGV (números
inteiros) e o CKKS (números aproximados). As bibliotecas principais são a OpenFHE (C++, versão estável
1.3.1 de julho de 2025) e a Microsoft SEAL (C++). Em comparações de 2025 e 2026, a OpenFHE foi mais
rápida e gastou menos memória; mesmo assim, uma operação leva milissegundos a segundos, contra
nanossegundos em claro, e cada valor cifrado ocupa kilobytes.

**O que resolveria aqui.** Pouca coisa do sistema precisa de conta sobre dado pessoal: o caso mais
próximo é somar a participação dos sócios (a regra "até 100%") sem o servidor ver cada participação.
Consultas por igualdade (achar o e-mail, a unicidade do CPF) o projeto já resolve com a impressão
digital (HMAC), que é muito mais barata.

**Dá para fazer aqui?** Só como demonstração: não há biblioteca madura em Java (as principais são C++,
com ligação para Python), e o Oracle não opera sobre esses valores, então a conta teria de ser feita
fora do banco.

**Recomendação:** não colocar no caminho principal. Se quiser no TCC, uma demonstração pequena e
separada (por exemplo, em Python com a OpenFHE, num contêiner próprio) somando participações cifradas,
com a medição do custo comparada à soma em claro.

## 4. Marca d'água nos dados (watermarking e fingerprinting)

**O que é.** Esconder nos dados uma marca que prova a origem. A técnica clássica para bancos relacionais
é de Agrawal e Kiernan (2002; artigo completo de Agrawal, Haas e Kiernan, VLDB Journal, 2003): altera
bits pouco significativos de alguns atributos de algumas linhas, escolhidos por uma chave secreta, de
um jeito que resiste a inserções, alterações e exclusões. Ela nasceu para provar propriedade; o
**fingerprinting** (Li, Swarup e Jajodia, 2005) põe uma marca **diferente em cada cópia** entregue,
para descobrir de qual cópia veio um vazamento, inclusive quando vários receptores se juntam para
apagar a marca.

**O que resolveria aqui.** Descobrir quem vazou uma lista de clientes. Mas a técnica clássica altera
valores numéricos, e os dados do sistema são, em boa parte, cifrados e textuais (nome, CPF, e-mail),
onde mudar um bit corrompe o dado. Duas variantes cabem melhor:
- **Registros-isca por empresa** (honeytokens): uma pessoa fictícia, diferente em cada empresa, com
  e-mail próprio. Se esse e-mail receber mensagem ou aparecer num vazamento, sabe-se de qual empresa
  saiu. Combina com o item "Honeytables" do roadmap: qualquer consulta à isca gera alerta.
- **Marca por exportação**: quando o sistema tiver exportação (CSV, relatório), cada arquivo leva uma
  marca do usuário e da hora: a ordem das linhas, espaços invisíveis ou linhas-isca escolhidas por uma
  chave secreta, e a exportação vai para o log de acesso.

**Dá para fazer aqui?** Sim, na aplicação, sem depender de infraestrutura.

**Recomendação:** implementar os registros-isca junto com as tabelas isca do roadmap, e a marca por
exportação quando houver exportação.

---

## Fontes

- VPD: Oracle, [Using Oracle Virtual Private Database to Control Data Access (23ai)](https://docs.oracle.com/en/database/oracle/oracle-database/23/dbseg/using-oracle-vpd-to-control-data-access.html);
  [Licensing Information (23ai)](https://docs.oracle.com/en/database/oracle/oracle-database/23/dblic/Licensing-Information.html);
  e o teste no contêiner do projeto descrito acima.
- Enclaves: Intel, [Confidential Computing: growing momentum, sharpened focus](https://intel.com/content/www/us/en/newsroom/opinion/confidential-computing-growing-momentum-sharpened-focus.html);
  [SoK sobre computação confidencial na nuvem (arXiv 2503.08256)](https://arxiv.org/html/2503.08256v1);
  Red Hat, [Confidential computing platform-specific details](https://redhat.com/pt-br/blog/confidential-computing-platform-specific-details);
  [TUM NET 2024-09-1](https://www.net.in.tum.de/fileadmin/TUM/NET/NET-2024-09-1/NET-2024-09-1_10.pdf).
- Criptografia homomórfica: [Cross-Platform Benchmarking of the FHE Libraries: SEAL and OpenFHE (arXiv 2503.11216)](https://arxiv.org/abs/2503.11216v1);
  [estudo de compiladores e hardware com SEAL, HElib e OpenFHE (Springer, 2026)](https://link.springer.com/article/10.1007/s11227-026-08464-y).
- Marca d'água: Agrawal, Haas e Kiernan, [Watermarking relational data: framework, algorithms and analysis](https://research.ibm.com/publications/watermarking-relational-data-framework-algorithms-and-analysis)
  ([DOI](https://www.doi.org/10.1007/S00778-003-0097-X)); Li, Swarup e Jajodia, [fingerprinting de dados relacionais](https://core.ac.uk/download/13247982.pdf);
  [levantamento de técnicas (arXiv 1801.08271)](https://arxiv.org/pdf/1801.08271); Halder e Cortesi, [levantamento no JUCS](https://www.jucs.org/jucs_16_21/watermarking_techniques_for_relational/jucs_16_21_3164_3190_halder.pdf).
