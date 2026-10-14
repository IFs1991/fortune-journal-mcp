import { appOrigin, publicConfig } from '@/src/lib/env';

export function GET() {
  const {supabaseUrl} = publicConfig();
  return Response.json({
    resource: `${appOrigin()}/api/mcp`,
    authorization_servers: [`${supabaseUrl.replace(/\/$/, '')}/auth/v1`],
    scopes_supported: ['openid'],
    resource_documentation: `${appOrigin()}/login`,
  }, {headers:{'Access-Control-Allow-Origin':'*','Cache-Control':'public, max-age=300'}});
}
export function OPTIONS() {
  return new Response(null,{status:204,headers:{
    'Access-Control-Allow-Origin':'*',
    'Access-Control-Allow-Methods':'GET,OPTIONS',
    'Access-Control-Allow-Headers':'content-type',
  }});
}
