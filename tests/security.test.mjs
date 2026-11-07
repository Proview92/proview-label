// Security check against the live server. Needs three confirmed test logins (master, owner, manager) - see README.
const URL='https://fiqoirnlmhjzicvktdwa.supabase.co', KEY='sb_publishable_j7p5qB-D6FMOV4B6zLiN_w_7xmfKLRM', PW='TestPass!2026';
const j=async(r)=>{ const t=await r.text(); try{return JSON.parse(t);}catch{return t;} };
async function login(email){ const r=await fetch(URL+'/auth/v1/token?grant_type=password',{method:'POST',headers:{apikey:KEY,'content-type':'application/json'},body:JSON.stringify({email,password:PW})}); const d=await j(r); if(!d.access_token) throw new Error('login '+email+' '+JSON.stringify(d)); return d.access_token; }
const H=(t)=>({apikey:KEY,Authorization:'Bearer '+t,'content-type':'application/json'});
const rpc=async(t,fn,body={})=>{ const r=await fetch(URL+'/rest/v1/rpc/'+fn,{method:'POST',headers:H(t),body:JSON.stringify(body)}); return [r.status,await j(r)]; };
const ins=async(t,table,rows,upsert)=>{ const r=await fetch(URL+'/rest/v1/'+table+(upsert?'?on_conflict=id':''),{method:'POST',headers:{...H(t),Prefer:(upsert?'resolution=merge-duplicates,':'')+'return=representation'},body:JSON.stringify(rows)}); return [r.status,await j(r)]; };
const sel=async(t,q)=>{ const r=await fetch(URL+'/rest/v1/'+q,{headers:H(t)}); return await j(r); };
const ok=(c,m)=>console.log((c?'PASS ':'FAIL ')+m);
const tm=await login('t-master@pl-test.invalid');
let [s,w]=await rpc(tm,'pl_whoami'); ok(w.master===true,'master whoami: master=true');
let [s2,org]=await rpc(tm,'pl_create_org',{p_name:'Test Kitchens Ltd',p_owner_email:'t-owner@pl-test.invalid',p_owner_name:'Tess Owner'}); ok(s2===200&&String(org).startsWith('org_'),'master creates business '+org);
let [s2b,org2]=await rpc(tm,'pl_create_org',{p_name:'Other Co',p_owner_email:null,p_owner_name:''}); ok(s2b===200,'master creates second business');
const to=await login('t-owner@pl-test.invalid');
[s,w]=await rpc(to,'pl_whoami'); ok(!w.master&&w.orgs.length===1&&w.orgs[0].role==='owner','owner sees only own business as owner');
let [s3,r3]=await ins(to,'pl_records',[{id:'tsite_1',org_id:org,site_id:'tsite_1',kind:'sites',data:{id:'tsite_1',name:'Site One',orgId:org}},{id:'tsite_2',org_id:org,site_id:'tsite_2',kind:'sites',data:{id:'tsite_2',name:'Site Two',orgId:org}},
  {id:'tprod_1',org_id:org,site_id:null,kind:'products',data:{id:'tprod_1',name:'Brie',orgId:org}},{id:'tlab_1',org_id:org,site_id:'tsite_1',kind:'labels',data:{id:'tlab_1',name:'Brie',siteId:'tsite_1'}},{id:'tlab_2',org_id:org,site_id:'tsite_2',kind:'labels',data:{id:'tlab_2',name:'Brie',siteId:'tsite_2'}}],true);
ok(s3===201,'owner writes sites, product, labels ('+s3+')');
let [s4]=await ins(to,'pl_records',[{id:'x_other',org_id:org2,site_id:null,kind:'products',data:{name:'hack'}}],true); ok(s4>=400,'owner cannot write into another business ('+s4+')');
let [s5,r5]=await ins(to,'pl_members',[{org_id:org,email:'t-mgr@pl-test.invalid',name:'Max Manager',role:'manager',site_ids:['tsite_1']}]); ok(s5===201,'owner adds a manager for Site One');
const tg=await login('t-mgr@pl-test.invalid');
[s,w]=await rpc(tg,'pl_whoami'); ok(w.orgs.length===1&&w.orgs[0].role==='manager'&&w.orgs[0].site_ids[0]==='tsite_1','manager whoami: manager of Site One only');
const mrec=await sel(tg,'pl_records?select=id,kind,site_id&order=id'); ok(JSON.stringify(mrec.map(x=>x.id))===JSON.stringify(['tlab_1','tprod_1','tsite_1']),'manager reads only Site One + business catalogue: '+mrec.map(x=>x.id).join(','));
let [s6]=await ins(tg,'pl_records',[{id:'tlab_3',org_id:org,site_id:'tsite_2',kind:'labels',data:{}}],true); ok(s6>=400,'manager cannot write to Site Two ('+s6+')');
let [s7]=await ins(tg,'pl_records',[{id:'tsite_3',org_id:org,site_id:'tsite_3',kind:'sites',data:{}}],true); ok(s7>=400,'manager cannot add sites ('+s7+')');
let [s8]=await ins(tg,'pl_records',[{id:'tlab_4',org_id:org,site_id:'tsite_1',kind:'labels',data:{id:'tlab_4',siteId:'tsite_1'}}],true); ok(s8===201,'manager can print labels at Site One ('+s8+')');
let [s9]=await ins(tg,'pl_members',[{org_id:org,email:'evil@x.invalid',role:'owner'}]); ok(s9>=400,'manager cannot add logins ('+s9+')');
let [s9b]=await rpc(tg,'pl_create_org',{p_name:'nope',p_owner_email:null,p_owner_name:''}); ok(s9b>=400,'manager cannot create businesses ('+s9b+')');
const anon=await sel(KEY,'pl_records?select=id'); ok(Array.isArray(anon)&&anon.length===0,'signed-out visitor sees nothing');
const mm=await sel(tm,'pl_records?select=id'); ok(mm.length===6,'master sees every record ('+mm.length+')');
const ownerOrgs=await sel(to,'pl_orgs?select=name'); ok(ownerOrgs.length===1,'owner sees one business in pl_orgs');
console.log(JSON.stringify({org,org2}));
