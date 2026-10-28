const { randomUUID } = require('node:crypto');
const { extractComment, validateMessage } = require('./domain');
function createHandlers({ analyze, insert, totals, fetchComment }) {
  return {
    async collect() {
      const payload = await fetchComment();
      const text = extractComment(payload);
      const collectedAt = new Date().toISOString();
      const analysis = await analyze(text);
      return { id: randomUUID(), text, collectedAt, ...analysis };
    },
    async consume(message) { await insert(validateMessage(message)); },
    async list(_request, context) {
      try { return { status: 200, jsonBody: await totals(), headers: { 'Cache-Control': 'no-store' } }; }
      catch { context.error('Falha ao consultar os totais no SQL'); return { status: 503, jsonBody: { error: 'Banco indisponível' } }; }
    }
  };
}
module.exports = { createHandlers };
