import type {CallToolResult} from '@modelcontextprotocol/server';

/** Successful tool result; the SDK validates structuredContent against the tool's output schema. */
export function result<T extends Record<string, unknown>>(data: T): CallToolResult {
  return {structuredContent: data, content: [{type: 'text', text: JSON.stringify(data)}]};
}

/** Error results carry only a stable UPPER_SNAKE code (listed per tool in src/mcp/tools.ts). */
export function toolError(code: string): CallToolResult {
  return {isError: true, content: [{type: 'text', text: code}]};
}
