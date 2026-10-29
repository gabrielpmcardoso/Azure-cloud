# Comandos de implantação na Azure

## Estado confirmado

O usuário executou o registro dos provedores Microsoft.Web, Microsoft.Storage, Microsoft.Sql, Microsoft.CognitiveServices, Microsoft.Insights e Microsoft.OperationalInsights e criou o grupo `rg-sentimentos-17932334314106` em `eastus`. A criação do Storage foi bloqueada por `RequestDisallowedByAzure`; os passos seguintes não foram executados nessa tentativa. O registro original permanece em `deploy-output/EXECUCAO_AZURE.md` no Cloud Shell.

A política retornada pela assinatura permite: northcentralus, chilecentral, francecentral, belgiumcentral e southafricanorth.

## Retomada preparada (ainda não confirmada)

```bash
git pull --ff-only
LOCATION=francecentral RESUME_SUFFIX=17932334314106 bash scripts/deploy.sh
```

O modo RESUME_SUFFIX só retoma quando o grupo existe e está vazio. Preserva o histórico, pula o registro dos provedores e a criação do grupo, e cria os recursos na região informada. A localização do grupo não precisa ser alterada. Se já houver recursos dentro dele, o script para para evitar repetir etapas sem diagnóstico. Quotas e disponibilidade dos serviços ainda são verificadas pela Azure durante a criação.

## Script completo

Os comandos abaixo são o roteiro; a presença aqui não indica execução bem-sucedida. Após concluir a publicação, copie o registro sanitizado para `COMANDOS_EXECUTADOS.md` e atualize o endpoint no README.

```bash
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
  if [[ "$RESOURCE_COUNT" != "0" ]]; then
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

```
