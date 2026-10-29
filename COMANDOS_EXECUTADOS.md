# Comandos executados na implantação

Registro reconstruído a partir das saídas do Cloud Shell enviadas pelo responsável e do script executado. Credenciais não são reproduzidas. Não executar este histórico inteiro novamente: os recursos já existem.

## Resultado

- Publicação concluída em 29/10/2026 às 00:51:25 UTC (28/10/2026 às 21:51:25 em Brasília).
- Host: Running.
- Funções reconhecidas: coletarComentario (timer), salvarSentimento (queue), totaisSentimentos (HTTP).
- Endpoint: https://func-sentimentos-17932334314106.azurewebsites.net/api/sentimentos/totais
- Consulta real após publicação: `{"positive":3,"neutral":1,"negative":5}`.
- Seis testes locais aprovados e tabela SQL criada/verificada.
- Grupo: rg-sentimentos-17932334314106 (metadados em eastus).
- Storage, Language, SQL e Function App: francecentral.

## Preparação e diagnóstico

```bash
git clone https://github.com/gabrielpmcardoso/Azure-cloud.git
cd Azure-cloud
az account show --query "{assinatura:name,status:state}" -o table
node --version
func --version
az account show --query id -o tsv
curl -4 -s https://api.ipify.org
echo
bash scripts/deploy.sh
az policy assignment list --query "[].{nome:displayName,parametros:parameters}" -o json
cat deploy-output/EXECUCAO_AZURE.md
```

A primeira execução registrou os provedores e criou o grupo, mas a criação de Storage em eastus falhou com RequestDisallowedByAzure. A política da assinatura permitia northcentralus, chilecentral, francecentral, belgiumcentral e southafricanorth.

## Comandos de criação e configuração executados pelo script

As variáveis abaixo representam os nomes utilizados. SUBSCRIPTION, CLIENT_IP, SQL_PASSWORD, LANGUAGE_KEY e STORAGE_CONNECTION foram obtidos/fornecidos na sessão; os valores sensíveis não estão neste arquivo.

```bash
RG="rg-sentimentos-17932334314106"
LOCATION="francecentral"
STORAGE="stsent17932334314106"
APP="func-sentimentos-17932334314106"
LANGUAGE="lang-sentimentos-17932334314106"
SQL_NAME="sql-sentimentos-17932334314106"
SQL_SERVER="$SQL_NAME.database.windows.net"
SQL_DATABASE="sentimentos"
SQL_USER="sqladmin"

az account set --subscription "$SUBSCRIPTION"
az provider register --namespace Microsoft.Web --wait --output none
az provider register --namespace Microsoft.Storage --wait --output none
az provider register --namespace Microsoft.Sql --wait --output none
az provider register --namespace Microsoft.CognitiveServices --wait --output none
az provider register --namespace Microsoft.Insights --wait --output none
az provider register --namespace Microsoft.OperationalInsights --wait --output none
az group create --name "$RG" --location eastus --output none

# A tentativa original em eastus falhou. Esta criação em francecentral teve sucesso:
az storage account create --name "$STORAGE" --resource-group "$RG" --location "$LOCATION" --sku Standard_LRS --kind StorageV2 --output none
STORAGE_CONNECTION=$(az storage account show-connection-string --name "$STORAGE" --resource-group "$RG" --query connectionString -o tsv)
az storage queue create --name sentimentos --connection-string "$STORAGE_CONNECTION" --output none
az cognitiveservices account create --name "$LANGUAGE" --resource-group "$RG" --location "$LOCATION" --kind TextAnalytics --sku S --yes --output none
LANGUAGE_ENDPOINT=$(az cognitiveservices account show --name "$LANGUAGE" --resource-group "$RG" --query properties.endpoint -o tsv)
LANGUAGE_KEY=$(az cognitiveservices account keys list --name "$LANGUAGE" --resource-group "$RG" --query key1 -o tsv)

# A primeira senha foi recusada (PasswordNotComplex); esta etapa foi retomada com outra senha:
az sql server create --name "$SQL_NAME" --resource-group "$RG" --location "$LOCATION" --admin-user "$SQL_USER" --admin-password "$SQL_PASSWORD" --output none
az sql db create --name "$SQL_DATABASE" --server "$SQL_NAME" --resource-group "$RG" --service-objective Basic --output none
az sql server firewall-rule create --resource-group "$RG" --server "$SQL_NAME" --name AzureServices --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 --output none
az sql server firewall-rule create --resource-group "$RG" --server "$SQL_NAME" --name SetupClient --start-ip-address "$CLIENT_IP" --end-ip-address "$CLIENT_IP" --output none

npm ci
npm test
npm run db:init

az sql server firewall-rule delete --resource-group "$RG" --server "$SQL_NAME" --name SetupClient --output none
az functionapp create --name "$APP" --resource-group "$RG" --storage-account "$STORAGE" --flexconsumption-location "$LOCATION" --runtime node --runtime-version 22 --functions-version 4 --output none

# SETTINGS era um arquivo temporário com permissão 600, removido depois.
# Chaves: SQL_SERVER, SQL_DATABASE, SQL_USER, SQL_PASSWORD, LANGUAGE_ENDPOINT, LANGUAGE_KEY.
az functionapp config appsettings set --name "$APP" --resource-group "$RG" --settings "@$SETTINGS" --output none
```

O comando de criação da Function App também criou Application Insights e o contêiner de pacotes de implantação. O conteúdo completo do script, inclusive criação e remoção do arquivo temporário, está em [scripts/deploy.sh](scripts/deploy.sh).

## Retomadas efetivamente executadas

```bash
git pull --ff-only
LOCATION=francecentral RESUME_SUFFIX=17932334314106 bash scripts/deploy.sh

git pull --ff-only
LOCATION=francecentral RESUME_SUFFIX=17932334314106 RESUME_FROM=sql bash scripts/deploy.sh
```

As retomadas fizeram consultas de verificação com `az group show`, `az resource list`, `az storage account show` e `az cognitiveservices account show`, conforme o script. A publicação sem especificar linguagem falhou com “Can't determine project language” e “Worker runtime cannot be 'None'”. Foi corrigida sem recriar os recursos:

```bash
git pull --ff-only
func azure functionapp publish func-sentimentos-17932334314106 --javascript
```

## Verificação HTTP

Consulta realizada após a publicação:

```bash
curl --fail --show-error --silent --max-time 40 https://func-sentimentos-17932334314106.azurewebsites.net/api/sentimentos/totais
```

## Pendência de dependências

O npm audit reportou duas vulnerabilidades altas em dependências transitivas MSAL. A tentativa local de npm audit fix não removeu os alertas. Isso não bloqueou a implantação e não é apresentado como resolvido.
