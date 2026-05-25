import { describe, it, expect } from 'vitest';
import { toGenkitMessages, fromGenkitResponse } from '../src/translate.js';
import type { ProxyRequest } from '../src/types.js';

describe('toGenkitMessages', () => {
  it('maps an assistant turn with text + tool call to a model message', () => {
    const req: ProxyRequest = {
      model: 'm',
      messages: [
        { role: 'assistant', text: 'ok', toolCalls: [{ id: 'c1', name: 'click', input: { x: 1 } }] },
      ],
    };
    expect(toGenkitMessages(req)).toEqual([
      {
        role: 'model',
        content: [{ text: 'ok' }, { toolRequest: { ref: 'c1', name: 'click', input: { x: 1 } } }],
      },
    ]);
  });

  it('maps a user turn with text and an image to a user message', () => {
    const req: ProxyRequest = {
      model: 'm',
      messages: [{ role: 'user', text: 'look', images: [{ mediaType: 'image/png', dataBase64: 'AAA' }] }],
    };
    const msgs = toGenkitMessages(req);
    expect(msgs[0].role).toBe('user');
    expect(msgs[0].content).toEqual([
      { text: 'look' },
      { media: { url: 'data:image/png;base64,AAA', contentType: 'image/png' } },
    ]);
  });

  it('maps tool results to a separate tool message', () => {
    const req: ProxyRequest = {
      model: 'm',
      messages: [{ role: 'user', toolResults: [{ toolUseId: 'c1', name: 'click', text: 'done' }] }],
    };
    expect(toGenkitMessages(req)).toEqual([
      { role: 'tool', content: [{ toolResponse: { ref: 'c1', name: 'click', output: 'done' } }] },
    ]);
  });
});

describe('fromGenkitResponse', () => {
  it('maps text + tool requests + usage to the neutral response', () => {
    const out = fromGenkitResponse({
      text: 'hi',
      toolRequests: [{ toolRequest: { ref: 't1', name: 'done', input: { summary: 'ok' } } }],
      usage: { inputTokens: 12, outputTokens: 7 },
    });
    expect(out.content).toEqual([
      { type: 'text', text: 'hi' },
      { type: 'toolUse', id: 't1', name: 'done', input: { summary: 'ok' } },
    ]);
    expect(out.stopReason).toBe('toolUse');
    expect(out.usage).toEqual({ inputTokens: 12, outputTokens: 7 });
  });

  it('reports endTurn and zero usage when no tools or usage are present', () => {
    const out = fromGenkitResponse({ text: 'bye', toolRequests: [] });
    expect(out.stopReason).toBe('endTurn');
    expect(out.usage).toEqual({ inputTokens: 0, outputTokens: 0 });
  });
});
