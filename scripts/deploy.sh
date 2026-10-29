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
python3 - <<'PY'
import os, re, sys
p = os.environ['SQL_PASSWORD']
groups = [r'[A-Z]', r'[a-z]', r'[0-9]', r'[^A-Za-z0-9]']
if not (8 <= len(p) <= 128) or sum(bool(re.search(g, p)) for g in groups) < 3 or 'sqladmin' in p.lower():
    print('Senha inválida: use 8 a 128 caracteres, pelo menos 3 categorias (maiúsculas, minúsculas, números, símbolos) e não inclua sqladmin.')
    sys.exit(1)
PY
if [[ "${RESUME_FROM:-}" != "" && "${RESUME_FROM:-}" != "sql" ]]; then
  echo "RESUME_FROM inválido; o único estágio disponível é sql."; exit 1
fi
if [[ "${RESUME_FROM:-}" == "sql" && -z "${RESUME_SUFFIX:-}" ]]; then
  echo "Informe RESUME_SUFFIX para retomar no SQL."; exit 1
fi
SUFFIX="${RESUME_SUFFIX:-$(date +%s)${RANDOM}}"
RG="rg-sentimentos-$SUFFIX"
LOCATION="${LOCATION:-eastus}"
STORAGE="stsent$SUFFIX"
APP="func-sentimentos-$SUFFIX"
LANGUAGE="lang-sentimentos-$SUFFIX"
SQL_NAME="sql-sentimentos-$SUFFIX"
export SQL_SERVER="$SQL_NAME.database.windows.net" SQL_DATABASE=sentimentos SQL_USER=sqladmin
mkdir -p deploy-output
LOG=deploy-output/EXECUCAO_AZURE.md
if [[ -n "${RESUME_SUFFIX:-}" ]]; then
  az group show --name "$RG" --output none
  RESOURCE_COUNT=$(az resource list --resource-group "$RG" --query 'length(@)' -o tsv)
  if [[ "${RESUME_FROM:-}" == "sql" ]]; then
    az storage account show --name "$STORAGE" --resource-group "$RG" --output none
    az cognitiveservices account show --name "$LANGUAGE" --resource-group "$RG" --output none
    if [[ "$RESOURCE_COUNT" != "2" ]]; then
      echo "Esperados somente Storage e Language. Há outros recursos; confira antes de continuar."
      exit 1
    fi
  elif [[ "$RESOURCE_COUNT" != "0" ]]; then
    echo "O grupo já contém recursos. Pare e confira o registro antes de retomar."
    exit 1
  fi
  printf '\n## Retomada em %s (UTC), região %s\n\n' "$(date -u +%FT%TZ)" "$LOCATION" >> "$LOG"
else
  printf '# Registro de execução\n\nIniciado em %s (UTC).\n\n' "$(date -u +%FT%TZ)" > "$LOG"
fi
# Registra somente comandos sem segredos, depois que terminam com sucesso.
run() { echo "Executando: $*"; "$@"; printf -- '- Executado: `%s`\n' "$*" >> "$LOG"; }
if [[ -z "${RESUME_SUFFIX:-}" ]]; then
for provider in Microsoft.Web Microsoft.Storage Microsoft.Sql Microsoft.CognitiveServices Microsoft.Insights Microsoft.OperationalInsights; do
  run az provider register --namespace "$provider" --wait --output none
done
run az group create --name "$RG" --location "$LOCATION" --output none
else
  echo "Reutilizando grupo existente: $RG; novos recursos em $LOCATION"
fi
if [[ "${RESUME_FROM:-}" != "sql" ]]; then
run az storage account create --name "$STORAGE" --resource-group "$RG" --location "$LOCATION" --sku Standard_LRS --kind StorageV2 --output none
STORAGE_CONNECTION=$(az storage account show-connection-string --name "$STORAGE" --resource-group "$RG" --query connectionString -o tsv)
az storage queue create --name sentimentos --connection-string "$STORAGE_CONNECTION" --output none
printf -- '- Executado: `az storage account show-connection-string` e `az storage queue create` (segredo omitido).\n' >> "$LOG"
run az cognitiveservices account create --name "$LANGUAGE" --resource-group "$RG" --location "$LOCATION" --kind TextAnalytics --sku S --yes --output none
else
  echo "Storage e Language existentes verificados. Retomando na criação do SQL."
fi
LANGUAGE_ENDPOINT=$(az cognitiveservices account show --name "$LANGUAGE" --resource-group "$RG" --query properties.endpoint -o tsv)
LANGUAGE_KEY=$(az cognitiveservices account keys list --name "$LANGUAGE" --resource-group "$RG" --query key1 -o tsv)
echo "Criando servidor SQL (senha oculta)..."
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
