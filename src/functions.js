const { app, output } = require('@azure/functions');
const services = require('./services');
const { createHandlers } = require('./handlers');
const handlers = createHandlers({ ...services, async fetchComment() {
  const response = await fetch(process.env.COMMENTS_URL || 'https://backend-n75y.onrender.com/comentarios',
    { signal: AbortSignal.timeout(60000) });
  if (!response.ok) throw new Error(`Endpoint de comentários HTTP ${response.status}`);
  return response.json();
} });
const queue = output.storageQueue({ queueName: 'sentimentos', connection: 'AzureWebJobsStorage' });
app.timer('coletarComentario', {
  schedule: '*/10 * * * * *', useMonitor: false, runOnStartup: false,
  extraOutputs: [queue],
  handler: async (_timer, context) => {
    const message = await handlers.collect();
    context.extraOutputs.set(queue, JSON.stringify(message));
    context.log(`Análise encaminhada: ${message.id}`);
  }
});
app.storageQueue('salvarSentimento', {
  queueName: 'sentimentos', connection: 'AzureWebJobsStorage', handler: handlers.consume
});
app.http('totaisSentimentos', {
  methods: ['GET'], authLevel: 'anonymous', route: 'sentimentos/totais', handler: handlers.list
});
