import {createRequire} from 'node:module';import {execFileSync} from 'node:child_process';import {readdirSync,existsSync} from 'node:fs';import path from 'node:path';
const require=createRequire(import.meta.url);let ts;let globalRoot;
try{ts=require('typescript');}catch{globalRoot=execFileSync('npm',['root','-g'],{encoding:'utf8'}).trim();ts=require(path.join(globalRoot,'typescript'));}
globalRoot??=execFileSync('npm',['root','-g'],{encoding:'utf8'}).trim();
const roots=[path.resolve('node_modules/@types'),...(globalRoot?[path.join(globalRoot,'@types'),path.join(globalRoot,'ts-node/node_modules/@types')]:[])].filter(p=>existsSync(path.join(p,'node')));
if(!roots.length)throw new Error('Node type declarations unavailable. This is not a passed check.');
const files=readdirSync('src/domain').filter(n=>n.endsWith('.ts')).map(n=>path.resolve('src/domain',n));files.push(path.resolve('src/integrations/threads.ts'));
const program=ts.createProgram(files,{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ESNext,moduleResolution:ts.ModuleResolutionKind.Bundler,strict:true,noEmit:true,allowImportingTsExtensions:true,skipLibCheck:true,typeRoots:roots,types:['node'],lib:['lib.es2022.d.ts','lib.dom.d.ts']});
const errors=ts.getPreEmitDiagnostics(program);if(errors.length){for(const d of errors)console.error(ts.flattenDiagnosticMessageText(d.messageText,' '));process.exit(1);}console.log(`Pure-domain/integration type check PASS (${files.length} files). Next/MCP/Supabase types are not included.`);
