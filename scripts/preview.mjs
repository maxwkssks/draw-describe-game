import { createServer } from 'node:http';
import { readFile,stat } from 'node:fs/promises';
import { resolve, extname, join } from 'node:path';
const root=resolve('dist');
const mime={'.html':'text/html;charset=utf-8','.js':'text/javascript;charset=utf-8','.css':'text/css;charset=utf-8','.png':'image/png','.jpg':'image/jpeg','.webp':'image/webp'};
createServer(async(req,res)=>{
 try{
  const path=decodeURIComponent(new URL(req.url,'http://localhost').pathname);
  if(path.includes('..')){res.writeHead(403).end();return}
  const file=join(root,path==='/'?'index.html':path);
  if(!(await stat(file)).isFile())throw Error('not file');
  const data=await readFile(file);
  res.writeHead(200,{'content-type':mime[extname(file)]||'application/octet-stream','cache-control':'no-store','x-content-type-options':'nosniff'}).end(data);
 }catch{res.writeHead(404).end('Not Found')}
}).listen(Number(process.env.PORT)||3000,()=>console.log('Preview at http://localhost:3000'));
