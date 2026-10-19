import { cpSync, mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
const out=resolve('dist');
mkdirSync(out,{recursive:true});
cpSync(resolve('public'),out,{recursive:true,force:true});
const url=process.env.SUPABASE_URL;
const key=process.env.SUPABASE_ANON_KEY;
if(url&&key){
 if(!url.startsWith('https://'))throw Error('SUPABASE_URL must use https');
 writeFileSync(resolve(out,'config.js'),`window.DD_CONFIG = ${JSON.stringify({supabaseUrl:url,supabaseAnonKey:key})};\n`);
 console.log('Supabase public configuration included in build.');
}else console.warn('No Supabase env vars: dist/config.js contains placeholders. Configure SUPABASE_URL and SUPABASE_ANON_KEY before production deployment.');
console.log('Built static website to dist/');
