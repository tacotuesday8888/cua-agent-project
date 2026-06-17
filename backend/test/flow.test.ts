import { describe, expect, it } from 'vitest';
import { buildHostedGenerateRequest } from '../src/flow.js';

describe('buildHostedGenerateRequest', () => {
  it('passes the server-owned Basic output cap into Genkit and OpenAI passthrough config', () => {
    const request = buildHostedGenerateRequest({
      model: 'automatic',
      messages: [{ role: 'user', text: 'Summarize the active window.' }],
      maxTokens: 999_999,
    });

    expect(request.config).toEqual({
      maxOutputTokens: 4096,
      max_completion_tokens: 4096,
    });
    expect(request.returnToolRequests).toBe(true);
    expect(request.toolChoice).toBeUndefined();
  });
});
