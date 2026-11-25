# Termos de uso e política de privacidade

Os textos que o sistema mostra antes de qualquer tela (LGPD). A versão 1, que nasce com o banco
(`15_aceite_de_termos.sql`), é só um rascunho. A versão 2 está nesta pasta:

- `termos-de-uso-v2.txt`
- `politica-de-privacidade-v2.txt`

Foram escritos a partir do que a LGPD exige (Lei 13.709/2018: art. 6º, princípios; art. 7º, bases
legais; art. 9º, o que o titular precisa saber; art. 16, guarda; art. 18, direitos; art. 41,
encarregado; arts. 46 e 48, segurança e incidentes) e do que o sistema faz de verdade (o que guarda,
por quanto tempo, como protege). Não reproduzem texto de terceiros.

**Campos do modelo**, entre chaves, para quem for usar os textos achar e trocar (Ctrl+F por `{ `):
`{ Nome da empresa }`, `{ CNPJ da empresa }`, `{ Endereço da empresa }`, `{ Nome do encarregado de dados }`,
`{ E-mail do encarregado de dados }`, `{ E-mail de atendimento }` e `{ Cidade/UF do foro }`. O
`publicar-termo.ps1` publica e avisa quais campos ainda estão em aberto. Com os dados reais, troque os
campos e publique como versão nova (3, por exemplo): termo publicado não muda.

Para publicar num ambiente:

```powershell
.\infra\scripts\publicar-termo.ps1 -Ambiente TESTE_DEV -Documento TERMOS_DE_USO -Versao 2 -Arquivo .\infra\termos\termos-de-uso-v2.txt
.\infra\scripts\publicar-termo.ps1 -Ambiente TESTE_DEV -Documento POLITICA_DE_PRIVACIDADE -Versao 2 -Arquivo .\infra\termos\politica-de-privacidade-v2.txt
```

A partir daí, todo usuário vê os textos novos e só continua depois de aceitar. Recomenda-se que um
profissional de direito revise os textos antes de valerem para clientes reais.
