const categories = ['positive', 'neutral', 'negative'];
function extractComment(payload) {
  const text = typeof payload === 'string' ? payload : payload?.comentario;
  if (typeof text !== 'string' || !text.trim()) throw new Error('Comentário ausente ou inválido');
  if ([...text].length > 5120) throw new Error('Comentário excede o limite de análise');
  return text.trim();
}
function normalizeSentiment(document) {
  if (categories.includes(document?.sentiment)) return document.sentiment;
  if (document?.sentiment !== 'mixed') throw new Error('Sentimento inválido');
  const { positive, negative } = document.confidenceScores || {};
  if (!Number.isFinite(positive) || !Number.isFinite(negative)) throw new Error('Scores inválidos');
  return positive === negative ? 'neutral' : positive > negative ? 'positive' : 'negative';
}
function validateMessage(message) {
  if (typeof message === 'string') message = JSON.parse(message);
  if (!message || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(message.id || '') ||
      !categories.includes(message.sentiment) || !['mixed', ...categories].includes(message.originalSentiment) ||
      !Number.isFinite(Date.parse(message.collectedAt))) throw new Error('Mensagem inválida');
  extractComment(message.text);
  return message;
}
module.exports = { extractComment, normalizeSentiment, validateMessage };
