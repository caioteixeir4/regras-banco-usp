# Hardening de rede (criptografia em trânsito + listener) — aplicar manualmente

Diferente dos scripts em `oracle-init/`, isto **não roda automaticamente** no boot do
container. Motivo: são arquivos de configuração de rede do Oracle (`sqlnet.ora`,
`listener.ora`), não comandos SQL — e mexer neles errado pode fazer o listener não subir
mais, derrubando o acesso ao banco inteiro (um risco bem maior que um trigger com bug).
Por isso, aplique isto **só depois que o ambiente já tiver subido limpo pelo menos uma vez**
com `verify-environment.ps1` confirmando que está tudo certo — assim, se algo quebrar depois
disso, você sabe que foi essa mudança específica, não outra coisa.

## O que isso resolve

- **`sqlnet.ora.append`**: exige que toda conexão cliente↔banco seja criptografada
  (`SQLNET.ENCRYPTION_SERVER = REQUIRED`) e verificada contra adulteração em trânsito. Hoje,
  numa rede Docker local isso é baixo risco (tráfego não sai da sua máquina); passa a importar
  de verdade quando o banco for hospedado remotamente (AWS).
- **`listener.ora.append`**: impede que alguém reconfigure o listener remotamente via
  comandos de protocolo (`ADMIN_RESTRICTIONS_LISTENER = ON`) — só quem tem acesso ao sistema
  operacional do container consegue administrar o listener depois disso.

## Como aplicar

1. Confirme que o ambiente já subiu com sucesso e `verify-environment.ps1` não acusou erro.
2. Descubra o caminho real do `ORACLE_HOME` dentro do container (varia por versão da imagem):
   ```powershell
   docker exec kawashi-oracle bash -c 'echo $ORACLE_HOME'
   ```
3. Copie o conteúdo de `sqlnet.ora.append` para dentro do `sqlnet.ora` existente em
   `$ORACLE_HOME/network/admin/sqlnet.ora` — **adicione as linhas, não substitua o arquivo**
   (ele já vem com outras diretivas da própria imagem):
   ```powershell
   docker exec kawashi-oracle bash -c 'cat >> $ORACLE_HOME/network/admin/sqlnet.ora' < infra/oracle-network-config/sqlnet.ora.append
   ```
4. Confirme o nome real do listener (geralmente `LISTENER`) e faça o mesmo para o
   `listener.ora`:
   ```powershell
   docker exec kawashi-oracle lsnrctl status
   docker exec kawashi-oracle bash -c 'cat >> $ORACLE_HOME/network/admin/listener.ora' < infra/oracle-network-config/listener.ora.append
   ```
5. Reinicie o listener (não precisa derrubar o banco inteiro):
   ```powershell
   docker exec kawashi-oracle lsnrctl stop
   docker exec kawashi-oracle lsnrctl start
   ```
6. Teste a conexão normalmente (SQL Developer, `create-team-member.ps1`, etc.). Se algo
   parar de conectar, reverta removendo as linhas adicionadas nos dois arquivos e repita o
   passo 5.

## Por que isto não está no `docker-compose.yml`/`oracle-init` desde já

Os arquivos `.append` aqui são **conteúdo de referência**, não uma automação testada contra
este ambiente. Um bind-mount direto sobrescrevendo `sqlnet.ora`/`listener.ora` no
`docker-compose.yml` poderia apagar outras diretivas que a própria imagem `gvenzl/oracle-free`
já coloca lá por padrão — sem saber o conteúdo original desses arquivos nesta versão
específica da imagem, o caminho manual e incremental (passo a passo acima) é o seguro. Depois
de validar que funciona bem no seu ambiente, isso pode virar um script/volume automatizado.
