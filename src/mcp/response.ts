export function result<T>(data: T) {
  return { structuredContent: data, content: [{ type: 'text' as const, text: JSON.stringify(data) }] };
}
export function toolError(code: string) {
  return { isError: true, content: [{type:'text' as const, text: code}] };
}
