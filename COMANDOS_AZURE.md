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
func azure functionapp publish "$APP" --javascript
printf -- '- Executado: `func azure functionapp publish %s`.\n' "$APP" >> "$LOG"
HOSTNAME=$(az functionapp show --name "$APP" --resource-group "$RG" --query defaultHostName -o tsv)
URL="https://$HOSTNAME/api/sentimentos/totais"
printf '\nEndpoint publicado (validar com curl): %s\nGrupo de recursos: %s\n' "$URL" "$RG" | tee deploy-output/ENTREGA.txt
printf '\nEndpoint: %s\n' "$URL" >> "$LOG"
curl --fail --show-error "$URL"
printf '\nCopie o registro sanitizado para COMANDOS_EXECUTADOS.md e preencha os links no README.\n'

```

## Retomada após senha SQL recusada

Na tentativa em francecentral, o usuário confirmou por captura de tela a criação de Storage, fila e Language. O servidor SQL foi recusado com PasswordNotComplex. A etapa seguinte preparada (ainda depende de execução) é:

```bash
git pull --ff-only
LOCATION=francecentral RESUME_SUFFIX=17932334314106 RESUME_FROM=sql bash scripts/deploy.sh
```

Nesse modo o script verifica os dois recursos esperados, não recria Storage/Language, recupera a configuração Language e continua pela criação do SQL. Para caso sem RESUME_FROM, a retomada continua exigindo grupo vazio. A senha passa por validação básica local, e a Azure aplica a política definitiva. Não publique a senha nem as chaves.

## Retomada somente da publicação

O usuário confirmou criação do SQL, tabela, regras de firewall e Function App. A chamada do Core Tools parou por não detectar a linguagem. A correção é informar `--javascript`; não executar novamente o provisionamento.

```bash
git pull --ff-only
func azure functionapp publish func-sentimentos-17932334314106 --javascript
```

O npm audit também reportou duas vulnerabilidades altas em dependências transitivas de autenticação MSAL. A tentativa local de `npm audit fix` não eliminou os alertas; a correção das dependências permanece pendente. O fluxo atual da aplicação usa senha SQL e chave Language, não o fluxo de código de autorização MSAL citado pelo alerta.
