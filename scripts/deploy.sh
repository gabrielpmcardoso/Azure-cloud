#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for tool in az node npm func python3; do command -v "$tool" >/dev/null || { echo "Instale: $tool"; exit 1; }; done
az account show >/dev/null 2>&1 || az login --output none
read -rp 'ID da assinatura Azure: ' SUBSCRIPTION
az account set --subscription "$SUBSCRIPTION"
read -rp 'Seu IPv4 público (para criar a tabela SQL): ' CLIENT_IP
read -rsp 'Senha forte para o administrador SQL: ' SQL_PASSWORD
printf '\n'
export SQL_PASSWORD
SUFFIX="$(date +%s)${RANDOM}"
RG="rg-sentimentos-$SUFFIX"
LOCATION="${LOCATION:-eastus}"
STORAGE="stsent$SUFFIX"
APP="func-sentimentos-$SUFFIX"
LANGUAGE="lang-sentimentos-$SUFFIX"
SQL_NAME="sql-sentimentos-$SUFFIX"
export SQL_SERVER="$SQL_NAME.database.windows.net" SQL_DATABASE=sentimentos SQL_USER=sqladmin
mkdir -p deploy-output
LOG=deploy-output/EXECUCAO_AZURE.md
printf '# Registro de execução\n\nIniciado em %s (UTC).\n\n' "$(date -u +%FT%TZ)" > "$LOG"
# Registra somente comandos sem segredos, depois que terminam com sucesso.
run() { "$@"; printf -- '- Executado: `%s`\n' "$*" >> "$LOG"; }
for provider in Microsoft.Web Microsoft.Storage Microsoft.Sql Microsoft.CognitiveServices Microsoft.Insights Microsoft.OperationalInsights; do
  run az provider register --namespace "$provider" --wait --output none
done
run az group create --name "$RG" --location "$LOCATION" --output none
run az storage account create --name "$STORAGE" --resource-group "$RG" --location "$LOCATION" --sku Standard_LRS --kind StorageV2 --output none
STORAGE_CONNECTION=$(az storage account show-connection-string --name "$STORAGE" --resource-group "$RG" --query connectionString -o tsv)
az storage queue create --name sentimentos --connection-string "$STORAGE_CONNECTION" --output none
printf -- '- Executado: `az storage account show-connection-string` e `az storage queue create` (segredo omitido).\n' >> "$LOG"
run az cognitiveservices account create --name "$LANGUAGE" --resource-group "$RG" --location "$LOCATION" --kind TextAnalytics --sku S --yes --output none
LANGUAGE_ENDPOINT=$(az cognitiveservices account show --name "$LANGUAGE" --resource-group "$RG" --query properties.endpoint -o tsv)
LANGUAGE_KEY=$(az cognitiveservices account keys list --name "$LANGUAGE" --resource-group "$RG" --query key1 -o tsv)
az sql server create --name "$SQL_NAME" --resource-group "$RG" --location "$LOCATION" --admin-user "$SQL_USER" --admin-password "$SQL_PASSWORD" --output none
printf -- '- Executado: `az sql server create` (senha omitida).\n' >> "$LOG"
run az sql db create --name "$SQL_DATABASE" --server "$SQL_NAME" --resource-group "$RG" --service-objective Basic --output none
run az sql server firewall-rule create --resource-group "$RG" --server "$SQL_NAME" --name AzureServices --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 --output none
run az sql server firewall-rule create --resource-group "$RG" --server "$SQL_NAME" --name SetupClient --start-ip-address "$CLIENT_IP" --end-ip-address "$CLIENT_IP" --output none
npm ci
npm test
npm run db:init
printf -- '- Executado: `npm ci`, `npm test`, `npm run db:init`.\n' >> "$LOG"
run az sql server firewall-rule delete --resource-group "$RG" --server "$SQL_NAME" --name SetupClient --output none
run az functionapp create --name "$APP" --resource-group "$RG" --storage-account "$STORAGE" --flexconsumption-location "$LOCATION" --runtime node --runtime-version 22 --functions-version 4 --output none
export LANGUAGE_ENDPOINT LANGUAGE_KEY
SETTINGS=$(mktemp)
chmod 600 "$SETTINGS"
trap 'rm -f "$SETTINGS"' EXIT
python3 - "$SETTINGS" <<'PY'
import json, os, sys
names = ['SQL_SERVER', 'SQL_DATABASE', 'SQL_USER', 'SQL_PASSWORD', 'LANGUAGE_ENDPOINT', 'LANGUAGE_KEY']
with open(sys.argv[1], 'w') as f:
    json.dump({name: os.environ[name] for name in names}, f)
PY
az functionapp config appsettings set --name "$APP" --resource-group "$RG" --settings "@$SETTINGS" --output none
printf -- '- Executado: `az functionapp config appsettings set --settings @arquivo-temporario` (segredos omitidos).\n' >> "$LOG"
rm -f "$SETTINGS"
func azure functionapp publish "$APP"
printf -- '- Executado: `func azure functionapp publish %s`.\n' "$APP" >> "$LOG"
HOSTNAME=$(az functionapp show --name "$APP" --resource-group "$RG" --query defaultHostName -o tsv)
URL="https://$HOSTNAME/api/sentimentos/totais"
printf '\nEndpoint publicado (validar com curl): %s\nGrupo de recursos: %s\n' "$URL" "$RG" | tee deploy-output/ENTREGA.txt
printf '\nEndpoint: %s\n' "$URL" >> "$LOG"
curl --fail --show-error "$URL"
printf '\nCopie o registro sanitizado para COMANDOS_EXECUTADOS.md e preencha os links no README.\n'
