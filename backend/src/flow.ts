import { genkit, z } from 'genkit';
import { vertexAI } from '@genkit-ai/google-genai';
import { getFirestore, FieldValue } from 'firebase-admin/firestore';
import { HttpsError } from 'firebase-functions/https';
import { ProxyRequestSchema, type ProxyRequest, type ProxyResponse, type ProxyUsage } from './types.js';
import { toGenkitMessages, fromGenkitResponse } from './translate.js';
import { monthKey, isOverCap, DEFAULT_MONTHLY_REQUEST_CAP } from './quota.js';
import { buildUsageRecord } from './usage.js';
import { ProxyError, normalizeProviderError } from './errors.js';
import {
  HOSTED_BASIC_MODEL,
  hostedBasicGenerationConfig,
  resolveHostedModel,
} from './hostedModel.js';

const hostedBasicLocation =
  process.env.VERTEX_AI_LOCATION || process.env.GCLOUD_LOCATION || 'global';

/// Vertex AI uses Google Cloud Application Default Credentials. In Firebase
/// Functions this means the runtime service account, with the Firebase project
/// id supplied by the platform. Local live tests can use `gcloud auth
/// application-default login` plus GCLOUD_PROJECT / VERTEX_AI_LOCATION.
export const ai = genkit({ plugins: [vertexAI({ location: hostedBasicLocation })] });

type HostedDynamicTool = ReturnType<typeof ai.dynamicTool>;

export function buildHostedGenerateRequest(
  req: ProxyRequest,
  dynamicTools: HostedDynamicTool[] = []
) {
  const model = resolveHostedModel(req.model);
  return {
    model: vertexAI.model(model),
    system: req.system,
    messages: toGenkitMessages(req),
    tools: dynamicTools,
    toolChoice: dynamicTools.length > 0 ? ('auto' as const) : undefined,
    config: hostedBasicGenerationConfig(req.maxTokens),
    returnToolRequests: true,
  };
}

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
      const generateRequest = buildHostedGenerateRequest(req, dynamicTools);
      let response;
      try {
        response = await ai.generate(generateRequest);
      } catch (err) {
        throw normalizeProviderError(err);
      }
      const latencyMs = Date.now() - started;

      const out = fromGenkitResponse(response);
      await recordUsage(uid, HOSTED_BASIC_MODEL, out.usage, latencyMs);
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
