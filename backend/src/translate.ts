import type { MessageData, Part } from 'genkit';
import type { ProxyRequest, ProxyResponse, ProxyContent, StopReason } from './types.js';

/// Translates between the neutral wire contract and Genkit's message/response
/// shapes. Pure (no Genkit instance needed), so it is unit-tested directly.

function dataUrl(mediaType: string, dataBase64: string): string {
  return `data:${mediaType};base64,${dataBase64}`;
}

/**
 * Convert neutral messages into Genkit `MessageData`. A user turn carrying tool
 * results becomes a Genkit `tool` message (toolResponse parts); assistant turns
 * become `model` messages, with tool calls as `toolRequest` parts.
 */
export function toGenkitMessages(req: ProxyRequest): MessageData[] {
  const out: MessageData[] = [];

  for (const message of req.messages) {
    if (message.role === 'assistant') {
      const parts: Part[] = [];
      if (message.text) parts.push({ text: message.text });
      for (const call of message.toolCalls ?? []) {
        parts.push({ toolRequest: { ref: call.id, name: call.name, input: call.input ?? {} } });
      }
      if (parts.length > 0) out.push({ role: 'model', content: parts });
      continue;
    }

    // role === 'user'
    const toolResults = message.toolResults ?? [];
    if (toolResults.length > 0) {
      out.push({
        role: 'tool',
        content: toolResults.map((result) => ({
          toolResponse: {
            ref: result.toolUseId,
            name: result.name,
            output: result.isError ? { error: result.text } : result.text,
          },
        })),
      });
    }

    const parts: Part[] = [];
    if (message.text) parts.push({ text: message.text });
    for (const image of message.images ?? []) {
      parts.push({ media: { url: dataUrl(image.mediaType, image.dataBase64), contentType: image.mediaType } });
    }
    if (parts.length > 0) out.push({ role: 'user', content: parts });
  }

  return out;
}

/** A minimal view of a Genkit generate response, so this stays test-friendly. */
export interface GenkitResponseView {
  text: string;
  toolRequests: Array<{ toolRequest: { ref?: string; name: string; input?: unknown } }>;
  usage?: { inputTokens?: number; outputTokens?: number };
}

/** Convert a Genkit generate response into the neutral response contract. */
export function fromGenkitResponse(resp: GenkitResponseView): ProxyResponse {
  const content: ProxyContent[] = [];
  if (resp.text && resp.text.length > 0) {
    content.push({ type: 'text', text: resp.text });
  }
  for (const part of resp.toolRequests ?? []) {
    const call = part.toolRequest;
    content.push({
      type: 'toolUse',
      id: call.ref ?? call.name,
      name: call.name,
      input: call.input ?? {},
    });
  }
  const stopReason: StopReason = content.some((c) => c.type === 'toolUse') ? 'toolUse' : 'endTurn';
  return {
    content,
    stopReason,
    usage: {
      inputTokens: resp.usage?.inputTokens ?? 0,
      outputTokens: resp.usage?.outputTokens ?? 0,
    },
  };
}
