// Host half: reuse DeepSeek's own authenticated browser connection.
export const name='local-rsi-panel';
export function apply(ctx){
  ctx.inject(['webServer','connection'],local=>{
    local.effect(()=>local.webServer.register({kind:'exact',path:'/local-rsi-api',async handler(req,res){
      const reject=local.connection.requestRejection(req);
      if(reject!==undefined){res.writeHead(reject);res.end();return;}
      if(req.method!=='POST'){res.writeHead(405);res.end();return;}
      try{
        let body='';for await(const part of req){body+=part;if(body.length>1048576)throw new Error('Request is too large');}
        const reply=await fetch('http://127.0.0.1:18803/rsi/ui',{method:'POST',body,
          headers:{'Authorization':'Bearer '+process.env.LOCAL_MODEL_API_KEY,'Content-Type':'application/json'}});
        res.writeHead(reply.status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(await reply.text());
      }catch(error){res.writeHead(500,{'Content-Type':'application/json'});res.end(JSON.stringify({error:error.message}));}
    }}),'local-rsi-panel route');
  });
}
