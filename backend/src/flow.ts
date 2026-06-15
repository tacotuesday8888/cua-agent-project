import { genkit, z } from 'genkit';
import { openAI } from '@genkit-ai/compat-oai/openai';
import { getFirestore, FieldValue } from 'firebase-admin/firestore';
import { HttpsError } from 'firebase-functions/https';
import { ProxyRequestSchema, type ProxyRequest, type ProxyResponse, type ProxyUsage } from './types.js';
import { toGenkitMessages, fromGenkitResponse } from './translate.js';
import { monthKey, isOverCap, DEFAULT_MONTHLY_REQUEST_CAP } from './quota.js';
import { buildUsageRecord } from './usage.js';
import { ProxyError, normalizeProviderError } from './errors.js';
import { resolveHostedModel } from './hostedModel.js';

/// The OpenAI key is read from process.env.OPENAI_API_KEY, which the function's
/// declared secret (see index.ts) populates at runtime.
export const ai = genkit({ plugins: [openAI()] });

export const llmProxyFlow = ai.defineFlow(
  {
    name: 'llmProxyFlow',
    inputSchema: ProxyRequestSchema,
    outputSchema: z.any(),
  },
  async (req: ProxyRequest): Promise<ProxyResponse> => {
    const uid = (ai.currentContext()?.auth as { uid?: string } | undefined)?.uid;
    if (!uid) {
      throw new HttpsError('unauthenticated', 'Sign in to use hosted AI.');
    }

    try {
      await enforceMonthlyCap(uid);

      // The model returns tool calls for the on-device agent to execute; it never
      // runs them here, so the dynamic tools need a schema but no handler.
      const dynamicTools = (req.tools ?? []).map((tool) =>
        ai.dynamicTool({
          name: tool.name,
          description: tool.description,
          inputJsonSchema: tool.parameters,
        })
      );

      const started = Date.now();
      const model = resolveHostedModel(req.model);
      let response;
      try {
        response = await ai.generate({
          model: openAI.model(model),
          system: req.system,
          messages: toGenkitMessages(req),
          tools: dynamicTools,
          toolChoice: dynamicTools.length > 0 ? 'auto' : undefined,
          returnToolRequests: true,
        });
      } catch (err) {
        throw normalizeProviderError(err);
      }
      const latencyMs = Date.now() - started;

      const out = fromGenkitResponse(response);
      await recordUsage(uid, model, out.usage, latencyMs);
      return out;
    } catch (err) {
      throw toHttpsError(err);
    }
  }
);

async function enforceMonthlyCap(uid: string): Promise<void> {
  const db = getFirestore();
  const ref = db.doc(`usage/${uid}`);
  const key = monthKey();
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const used = (snap.get(`months.${key}.requests`) as number | undefined) ?? 0;
    if (isOverCap(used, DEFAULT_MONTHLY_REQUEST_CAP)) {
      throw new ProxyError('resource-exhausted', 'Monthly usage limit reached.');
    }
    tx.set(ref, { months: { [key]: { requests: FieldValue.increment(1) } } }, { merge: true });
  });
}

async function recordUsage(
  uid: string,
  model: string,
  usage: ProxyUsage,
  latencyMs: number
): Promise<void> {
  try {
    const db = getFirestore();
    await db
      .collection('usageEvents')
      .add(buildUsageRecord({ uid, model, usage, latencyMs, status: 'ok' }));
  } catch {
    // Usage logging is best-effort; it must never fail the user's request.
  }
}

function toHttpsError(err: unknown): HttpsError {
  if (err instanceof HttpsError) return err;
  if (err instanceof ProxyError) return new HttpsError(err.code, err.message);
  return new HttpsError('internal', 'The AI request could not be completed.');
}
