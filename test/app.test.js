const test = require('node:test');
const assert = require('node:assert/strict');
const { extractComment, normalizeSentiment, validateMessage } = require('../src/domain');
const { createHandlers } = require('../src/handlers');
test('extrai o formato real do endpoint', () => {
  assert.equal(extractComment({ id: 10, comentario: ' Compra fácil. ' }), 'Compra fácil.');
  assert.throws(() => extractComment({ id: 10 }));
  assert.throws(() => extractComment('   '));
});
test('preserva categorias e converte mixed pela confiança', () => {
  for (const sentiment of ['positive', 'neutral', 'negative']) assert.equal(normalizeSentiment({ sentiment }), sentiment);
  for (const [positive, negative, expected] of [[.7,.3,'positive'],[.2,.8,'negative'],[.5,.5,'neutral']]) {
    assert.equal(normalizeSentiment({ sentiment: 'mixed', confidenceScores: { positive, negative } }), expected);
  }
  assert.throws(() => normalizeSentiment({ sentiment: 'unknown' }));
});
test('fluxo coleta, análise, fila e totais com serviços simulados', async () => {
  const stored = new Map();
  const handlers = createHandlers({
    fetchComment: async () => ({ id: 1, comentario: 'Produto ruim' }),
    analyze: async text => { assert.equal(text, 'Produto ruim'); return { sentiment: 'negative', originalSentiment: 'negative' }; },
    insert: async message => stored.set(message.id, message),
    totals: async () => ({ positive: 0, neutral: 0, negative: stored.size })
  });
  const message = await handlers.collect();
  await handlers.consume(JSON.stringify(message));
  assert.equal(stored.size, 1);
  const result = await handlers.list({}, { error() {} });
  assert.equal(result.status, 200);
  assert.deepEqual(result.jsonBody, { positive: 0, neutral: 0, negative: 1 });
  assert.throws(() => validateMessage({ ...message, sentiment: 'mixed' }));
});
test('falha na coleta não produz mensagem', async () => {
  const handlers = createHandlers({ fetchComment: async () => { throw new Error('HTTP 503'); } });
  await assert.rejects(handlers.collect(), /503/);
});
test('falha no SQL propaga para a fila tentar novamente', async () => {
  const handlers = createHandlers({ insert: async () => { throw new Error('SQL'); } });
  await assert.rejects(handlers.consume({ id: '12345678-1234-1234-1234-123456789abc', text: 'Teste', sentiment: 'neutral', originalSentiment: 'neutral', collectedAt: new Date().toISOString() }), /SQL/);
});
test('HTTP responde 503 em falha do banco, sem expor erro interno', async () => {
  const handlers = createHandlers({ totals: async () => { throw new Error('segredo'); } });
  const response = await handlers.list({}, { error() {} });
  assert.equal(response.status, 503);
  assert.deepEqual(response.jsonBody, { error: 'Banco indisponível' });
});
