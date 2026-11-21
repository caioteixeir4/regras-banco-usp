# Criptografia da conexão com o banco e trava do listener

**Estado: aplicado** (18/11/2026), por [`scripts/apply-network-hardening.ps1`](../scripts/apply-network-hardening.ps1),
e testado em [`Test-ConexaoCifrada.ps1`](../tests/caixa-preta/Test-ConexaoCifrada.ps1) e, do lado da
API, no `ConexaoCifradaTest` do repositório `tabelas-api-banco-usp`.

## O que isso resolve

Sem isto, o que trafega entre o computador de quem usa o banco (ou a API) e o Oracle vai em texto
puro: o resultado de cada consulta pode ser lido por quem estiver no caminho. A senha do login já é
protegida pelo próprio protocolo do Oracle; os dados, não.

| Arquivo | Linha | Efeito |
|---|---|---|
| `sqlnet.ora` | `SQLNET.ENCRYPTION_SERVER = REQUIRED`, `SQLNET.ENCRYPTION_TYPES_SERVER = (AES256)` | Toda conexão pela rede é cifrada com AES-256. `REQUIRED` **recusa** quem não cifra (não é "aceita se o cliente pedir"). |
| `sqlnet.ora` | `SQLNET.CRYPTO_CHECKSUM_SERVER = REQUIRED`, `SQLNET.CRYPTO_CHECKSUM_TYPES_SERVER = (SHA256)` | Cada pacote é conferido: alteração no caminho é detectada. |
| `listener.ora` | `ADMIN_RESTRICTIONS_LISTENER = ON` | Ninguém reconfigura o listener em tempo de execução (`SET`, `STOP`...): só editando o arquivo, de dentro do container. |

O cliente **não precisa de configuração**: o driver JDBC da API e o `sqlplus` negociam a cifra
sozinhos quando o servidor exige. As conexões locais como SYSDBA (dentro do container, sem rede)
não mudam.

## Como aplicar e desfazer

```powershell
./apply-network-hardening.ps1            # aplica e confere numa conexão de verdade
./apply-network-hardening.ps1 -Desfazer  # volta os arquivos originais
```

O script:

1. guarda uma cópia dos arquivos originais (`.kawashi-original`), só na primeira vez;
2. escreve o bloco entre os marcadores `# >>> KAWASHI` e `# <<< KAWASHI` (rodar de novo substitui
   o bloco, não duplica; as linhas que a imagem já traz ficam intactas);
3. relê o listener (`lsnrctl reload`), sem derrubar o banco, e **manda o banco se registrar de novo**
   nele (`ALTER SYSTEM REGISTER`): o reload faz o listener esquecer o registro, e por alguns segundos
   toda conexão pela rede falharia com `ORA-12514` (item 30 de [`bugs-primeiro-teste.md`](bugs-primeiro-teste.md));
4. abre uma conexão de verdade pela rede e confere, no dicionário, que ela negociou AES256 e SHA256;
5. se a conexão falhar, **volta os arquivos originais sozinho** e avisa.

## Como se prova

- Uma sessão pela rede mostra `AES256 Encryption service adapter` e `SHA256 Crypto-checksumming
  service adapter` em `V$SESSION_CONNECT_INFO`.
- Um cliente configurado para **recusar** cifra (ou a conferência de integridade) é barrado com
  `ORA-12660`, tanto pelo `sqlplus` quanto pelo driver JDBC da API.
- `lsnrctl set ...` é recusado com `TNS-12508`.
- **Controle:** o teste desfaz a configuração, confirma que o mesmo cliente teimoso entra (sem
  AES256) e aplica de novo. Isso prova que é a configuração que barra, e não outra coisa.

## Limite

Os arquivos de rede ficam dentro do container (em `/opt/oracle/oradata/dbconfig/FREE/`), como o
resto do banco, que não tem volume de dados. Se o container for recriado, rode o script de novo.
