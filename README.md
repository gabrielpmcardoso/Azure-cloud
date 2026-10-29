# Análise de sentimentos com Azure Functions

Aplicação JavaScript (Node.js 22, Azure Functions v4) para coletar comentários, analisar sentimentos e consultar totais no Azure SQL.

## Situação da entrega

Aplicação publicada na Azure em 28/10/2026 (horário de Brasília). As três funções foram reconhecidas, o host está em execução e o endpoint foi consultado com sucesso. Os seis testes locais passaram. Veja [COMANDOS_EXECUTADOS.md](COMANDOS_EXECUTADOS.md) para o registro da implantação.

- Repositório Git: https://github.com/gabrielpmcardoso/Azure-cloud
- Endpoint HTTP: https://func-sentimentos-17932334314106.azurewebsites.net/api/sentimentos/totais

Consulta após a publicação: `{"positive":3,"neutral":1,"negative":5}`. Os totais mudam conforme novas coletas são processadas.

## Fluxo

1. `coletarComentario`: timer com NCRONTAB `*/10 * * * * *`, consulta `https://backend-n75y.onrender.com/comentarios` e envia o texto ao Azure AI Language (Cognitive Service).
2. A saída do timer publica o resultado na fila Azure Storage `sentimentos`.
3. `salvarSentimento`: queue trigger recebe a mensagem e insere em `dbo.Sentimentos`, no Azure SQL Database.
4. `totaisSentimentos`: GET `/api/sentimentos/totais` consulta o banco e retorna os totais.

```json
{"positive":0,"neutral":0,"negative":1}
```

O JSON acima é um exemplo, não um resultado obtido de uma implantação. Banco vazio retorna as três categorias com zero. Falha no banco retorna HTTP 503, sem inventar contagens.

## Organização

- `src/functions.js`: registro das três funções e vínculos da fila.
- `src/handlers.js`: fluxo das funções.
- `src/services.js`: chamada REST ao Cognitive Service e consultas SQL parametrizadas.
- `src/domain.js`: validação e regra de classificação.
- `sql/schema.sql`: criação da tabela e índice.
- `scripts/deploy.sh`: criação dos recursos, configuração e publicação.
- `COMANDOS_AZURE.md`: todos os comandos do roteiro Azure.
- `test/app.test.js`: testes locais com serviços simulados.

## Regras e comportamento

O formato observado no endpoint foi `{"id":10,"comentario":"Compra fácil, entrega rápida e produto excelente."}`. O campo usado é `comentario`.

O serviço Azure pode retornar `mixed`. Para cumprir as três categorias solicitadas, esse caso vira `positive` se a confiança positiva for maior, `negative` se a negativa for maior e `neutral` no empate. O valor original fica salvo em `SentimentoOriginal`. É uma regra da aplicação, não uma classificação de três rótulos garantida pela Azure.

Cada coleta recebe um UUID. A chave primária impede a duplicação da mesma mensagem em reentregas da fila. O endpoint é aleatório: o mesmo comentário recebido em coletas diferentes conta novamente, pois os totais representam coletas processadas. Não há deduplicação por texto ou pelo ID da origem.

O timer agenda a cada 10 segundos, mas atrasos, inicialização a frio e duração das chamadas externas podem impedir essa precisão. Uma execução do timer não se sobrepõe à anterior. Uma falha na coleta/análise é registrada pelo host e a coleta seguinte ocorre no próximo horário; não há garantia de recuperar a amostra perdida. A fila tenta novamente em falhas SQL e, após cinco tentativas, move para `sentimentos-poison` (inspecionar pelo Azure Storage Explorer). Comentários completos e chaves não são gravados nos logs da aplicação.

## Publicar na Azure

Use Bash no Linux/WSL ou um ambiente com Azure CLI, Node.js 22, npm, Python 3 e Azure Functions Core Tools v4 instalados. É necessária uma assinatura Azure com permissão para criar recursos. Confira a disponibilidade do Flex Consumption na região escolhida e as restrições de sua assinatura.

```bash
npm ci
npm test
az login
bash scripts/deploy.sh
```

O script solicita assinatura, IPv4 público do computador e senha forte para SQL. Ele cria Storage, fila, Language, Azure SQL e Function App; cria a tabela; publica o código; obtém o hostname real e chama o endpoint. O arquivo `COMANDOS_AZURE.md` contém todos os comandos e detalhes. A região padrão é `eastus`; para alterar: `LOCATION=brazilsouth bash scripts/deploy.sh` (verifique suporte e quota antes).

Os recursos **podem gerar cobrança**. Language usa SKU S para não depender da pequena quota gratuita com coleta contínua; SQL usa Basic. O timer a cada 10 segundos gera aproximadamente 8.640 análises/dia. Interrompa a Function App depois da avaliação se não quiser manter as coletas.

O firewall SQL permite serviços Azure pela regra `0.0.0.0`, para simplificar a atividade acadêmica; isso permite origem de outras assinaturas Azure, mas ainda exige autenticação. Para produção, use rede privada/identidade gerenciada e permissões mínimas. A senha SQL e a chave Language ficam em app settings, nunca no Git. O usuário administrador é usado para simplificar a atividade.

## Execução local

Execute Azurite para Storage local; mantenha Language e Azure SQL reais. Libere temporariamente seu IP no firewall SQL.

```bash
npm ci
cp local.settings.example.json local.settings.json
# Edite os valores reais no arquivo local.settings.json, ignorado pelo Git.
npm test
npm start
curl http://localhost:7071/api/sentimentos/totais
```

`func start` lê `local.settings.json`. Já `npm run db:init` lê variáveis de ambiente (`SQL_SERVER`, `SQL_DATABASE`, `SQL_USER`, `SQL_PASSWORD`), que o script de publicação exporta automaticamente.

## Entrega no GitHub

Repositório: https://github.com/gabrielpmcardoso/Azure-cloud

Para baixar e trabalhar no projeto:

```bash
git clone https://github.com/gabrielpmcardoso/Azure-cloud.git
cd Azure-cloud
```

Depois da implantação bem-sucedida:

```bash
cp deploy-output/EXECUCAO_AZURE.md COMANDOS_EXECUTADOS.md
# Preencha os links reais neste README usando o resultado da publicação.
git add README.md COMANDOS_EXECUTADOS.md
git commit -m "Registra implantação e links da entrega"
git push
```

Não envie `local.settings.json`, arquivos `.env`, senhas, chaves ou saídas brutas contendo segredos. `deploy-output/` é ignorado pelo Git. O registro gerado é sanitizado; revise antes de adicioná-lo.

## Validação na nuvem

1. Consulte o endpoint e confira HTTP 200 com as três categorias numéricas.
2. Aguarde algumas coletas e consulte novamente: a soma deve aumentar quando as chamadas externas e o banco estão saudáveis.
3. Consulte `SELECT Sentimento, COUNT(*) FROM dbo.Sentimentos GROUP BY Sentimento;` no Azure SQL e compare com o JSON.
4. Confira as execuções das três funções e a fila poison.

Os testes locais simulam os serviços externos; eles não comprovam implantação, configuração de bindings, credenciais ou conectividade reais.

## Referências oficiais

- https://learn.microsoft.com/azure/azure-functions/functions-reference-node
- https://learn.microsoft.com/azure/azure-functions/functions-bindings-timer
- https://learn.microsoft.com/azure/azure-functions/functions-bindings-storage-queue-trigger
- https://learn.microsoft.com/azure/azure-functions/flex-consumption-how-to
- https://learn.microsoft.com/azure/ai-services/language-service/sentiment-opinion-mining/quickstart
