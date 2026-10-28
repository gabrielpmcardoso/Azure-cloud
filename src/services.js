const sql = require('mssql');
const { normalizeSentiment } = require('./domain');
let poolPromise;
function required(name) {
  if (!process.env[name]) throw new Error(`Configuração ausente: ${name}`);
  return process.env[name];
}
function getPool() {
  if (!poolPromise) {
    poolPromise = new sql.ConnectionPool({
      server: required('SQL_SERVER'), database: required('SQL_DATABASE'),
      user: required('SQL_USER'), password: required('SQL_PASSWORD'),
      options: { encrypt: true, trustServerCertificate: false },
      pool: { max: 5, min: 0, idleTimeoutMillis: 30000 },
      connectionTimeout: 30000, requestTimeout: 30000
    }).connect().catch(error => { poolPromise = undefined; throw error; });
  }
  return poolPromise;
}
async function analyze(text) {
  const endpoint = required('LANGUAGE_ENDPOINT').replace(/\/$/, '');
  const response = await fetch(`${endpoint}/language/:analyze-text?api-version=2023-04-01`, {
    method: 'POST', signal: AbortSignal.timeout(15000),
    headers: { 'Content-Type': 'application/json', 'Ocp-Apim-Subscription-Key': required('LANGUAGE_KEY') },
    body: JSON.stringify({ kind: 'SentimentAnalysis', parameters: { modelVersion: 'latest' },
      analysisInput: { documents: [{ id: '1', language: 'pt', text }] } })
  });
  if (!response.ok) throw new Error(`Azure Language HTTP ${response.status}`);
  const body = await response.json();
  if (body.results?.errors?.length) throw new Error('Azure Language rejeitou o documento');
  const document = body.results?.documents?.[0];
  return { sentiment: normalizeSentiment(document), originalSentiment: document.sentiment };
}
async function insert(message) {
  const pool = await getPool();
  try {
    await pool.request()
      .input('id', sql.UniqueIdentifier, message.id)
      .input('text', sql.NVarChar(sql.MAX), message.text)
      .input('sentiment', sql.VarChar(8), message.sentiment)
      .input('original', sql.VarChar(8), message.originalSentiment)
      .input('collected', sql.DateTime2, new Date(message.collectedAt))
      .query(`INSERT INTO dbo.Sentimentos (Id, Comentario, Sentimento, SentimentoOriginal, ColetadoEm)
              VALUES (@id, @text, @sentiment, @original, @collected)`);
  } catch (error) {
    // A mesma mensagem pode ser entregue novamente pela fila.
    if (![2601, 2627].includes(error.number)) throw error;
  }
}
async function totals() {
  const pool = await getPool();
  const { recordset } = await pool.request().query(`
    SELECT Sentimento, COUNT(*) AS Total FROM dbo.Sentimentos GROUP BY Sentimento`);
  const result = { positive: 0, neutral: 0, negative: 0 };
  for (const row of recordset) result[row.Sentimento] = row.Total;
  return result;
}
module.exports = { getPool, analyze, insert, totals };
