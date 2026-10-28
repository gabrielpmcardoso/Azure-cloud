const fs = require('node:fs');
const path = require('node:path');
const { getPool } = require('../src/services');
(async () => {
  let pool;
  try {
    pool = await getPool();
    await pool.request().batch(fs.readFileSync(path.join(__dirname, '../sql/schema.sql'), 'utf8'));
    console.log('Tabela criada/verificada.');
  } finally { if (pool) await pool.close(); }
})().catch(() => { console.error('Falha ao inicializar SQL. Verifique configurações e firewall.'); process.exitCode = 1; });
