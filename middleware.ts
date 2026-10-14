/** Keep browser sessions fresh without involving MCP bearer requests. */
import { NextResponse, type NextRequest } from 'next/server';
import { createServerClient } from '@supabase/ssr';
import { publicConfig } from '@/src/lib/env';

export async function middleware(request: NextRequest) {
  let response = NextResponse.next({request});
  const {supabaseUrl,publishableKey}=publicConfig();
  const client=createServerClient(supabaseUrl,publishableKey,{
    cookies:{
      getAll:()=>request.cookies.getAll(),
      setAll:(items)=>{
        items.forEach(({name,value})=>request.cookies.set(name,value));
        response=NextResponse.next({request});
        items.forEach(({name,value,options})=>response.cookies.set(name,value,options));
      },
    },
  });
  await client.auth.getUser();
  return response;
}
export const config={matcher:['/login','/oauth/consent','/auth/:path*','/api/oauth/:path*','/api/account/:path*']};
