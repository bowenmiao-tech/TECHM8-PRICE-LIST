import sharp from 'sharp';
import fs from 'node:fs/promises';

export async function badgeFeatures(buffer) {
  const { data, info } = await sharp(buffer).resize(256,256,{fit:'fill'}).removeAlpha().raw().toBuffer({resolveWithObject:true});
  let minX=256,minY=256,maxX=0,maxY=0,count=0;
  for(let y=0;y<104;y++) for(let x=152;x<256;x++) {
    const i=(y*256+x)*info.channels,r=data[i],g=data[i+1],b=data[i+2];
    if(r>190 && g>170 && b<90 && b<g*.4 && Math.abs(r-g)<80){count++;minX=Math.min(minX,x);maxX=Math.max(maxX,x);minY=Math.min(minY,y);maxY=Math.max(maxY,y);}
  }
  const width=maxX-minX+1,height=maxY-minY+1;
  if(count<180 || width<22 || height<22 || width/height<.65 || width/height>1.5) return null;
  const pixels=await sharp(data,{raw:{width:256,height:256,channels:info.channels}}).extract({left:minX,top:minY,width,height}).resize(32,32,{fit:'fill'}).raw().toBuffer();
  const mask=[];
  for(let i=0;i<1024;i++) mask.push(pixels[i*info.channels]<110 && pixels[i*info.channels+1]<110 && pixels[i*info.channels+2]<110 ? 1:0);
  return mask;
}

export async function detectSolderBadge(buffer) {
  const mask=await badgeFeatures(buffer);
  if(!mask) return {requiresSoldering:null,evidence:'No visible soldering badge; absence alone does not confirm plug-in installation'};
  const reference=JSON.parse(await fs.readFile(new URL('./solder-badge-reference.json',import.meta.url),'utf8'));
  let intersection=0,union=0;
  for(let i=0;i<1024;i++){if(mask[i]&&reference[i])intersection++;if(mask[i]||reference[i])union++;}
  const score=union?intersection/union:0;
  return score>=.42 ? {requiresSoldering:true,evidence:'Yellow upper-right soldering badge matches reference',score}
    : {requiresSoldering:null,evidence:'Yellow marking is not a confident soldering-badge match',score};
}

const pending=new Map();
export function checkSolderImage(url) {
  if(!url) return Promise.resolve({requiresSoldering:null,evidence:'No supplier product image'});
  if(!pending.has(url)) pending.set(url,(async()=>{
    try {
      const parsed=new URL(url);
      if(parsed.hostname!=='img.crazypos.com') throw new Error('Unrecognised supplier image host');
      parsed.searchParams.set('w','640');
      const response=await fetch(parsed,{signal:AbortSignal.timeout(20000)});
      if(!response.ok) throw new Error(`Image HTTP ${response.status}`);
      return await detectSolderBadge(Buffer.from(await response.arrayBuffer()));
    }catch(error){return {requiresSoldering:null,evidence:error.message};}
  })());
  return pending.get(url);
}
