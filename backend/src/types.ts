import { z } from 'genkit';

/// The neutral request/response contract between the macOS client's
/// `HostedProvider` and the proxy. It mirrors the Swift `LLMRequest`/`LLMResponse`
/// content-block model, kept provider-agnostic so the backend can route to any
/// model without the client caring.

export const ImageSchema = z.object({
  mediaType: z.string(),
  dataBase64: z.string(),
});

export const ToolCallSchema = z.object({
  id: z.string(),
  name: z.string(),
  // Arbitrary JSON tool input; kept loose to stay provider-agnostic.
  input: z.any().optional(),
});

export const ToolResultSchema = z.object({
  toolUseId: z.string(),
  // The tool's name, needed to build a Genkit toolResponse part.
  name: z.string(),
  text: z.string(),
  isError: z.boolean().optional(),
});

export const MessageSchema = z.object({
  role: z.enum(['user', 'assistant']),
  text: z.string().optional(),
  images: z.array(ImageSchema).optional(),
  toolCalls: z.array(ToolCallSchema).optional(),
  toolResults: z.array(ToolResultSchema).optional(),
});

export const ToolDefSchema = z.object({
  name: z.string(),
  description: z.string(),
  // A JSON Schema object describing the tool input.
  parameters: z.any(),
});

export const ProxyRequestSchema = z.object({
  /** Logical model id, e.g. "gpt-5.4-mini". */
  model: z.string(),
  system: z.string().optional(),
  messages: z.array(MessageSchema),
  tools: z.array(ToolDefSchema).optional(),
  maxTokens: z.number().int().positive().optional(),
});

export type ProxyRequest = z.infer<typeof ProxyRequestSchema>;
export type Message = z.infer<typeof MessageSchema>;
export type ToolDef = z.infer<typeof ToolDefSchema>;

export interface ProxyUsage {
  inputTokens: number;
  outputTokens: number;
}

export type ProxyContent =
  | { type: 'text'; text: string }
  | { type: 'toolUse'; id: string; name: string; input: unknown };

export type StopReason = 'endTurn' | 'toolUse' | 'maxTokens' | 'other';

export interface ProxyResponse {
  content: ProxyContent[];
  stopReason: StopReason;
  usage: ProxyUsage;
}
