import { describe, expect, it } from 'vitest';
import { buildHostedGenerateRequest } from '../src/flow.js';

describe('buildHostedGenerateRequest', () => {
  it('passes the server-owned Basic output cap into Vertex/Gemini config', () => {
    const request = buildHostedGenerateRequest({
      model: 'automatic',
      messages: [{ role: 'user', text: 'Summarize the active window.' }],
      maxTokens: 999_999,
    });

    expect(request.config).toEqual({
      maxOutputTokens: 4096,
    });
    expect(request.model.name).toBe('vertexai/gemini-3.5-flash');
    expect(request.returnToolRequests).toBe(true);
    expect(request.toolChoice).toBeUndefined();
  });
});
