import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import sharp from 'sharp';
import { detectSolderBadge } from './crazyparts-solder-badge.mjs';
const reference=JSON.parse(await fs.readFile(new URL('./solder-badge-reference.json',import.meta.url),'utf8'));
const pixels=Buffer.alloc(256*256*3,255);
for(let y=0;y<64;y++)for(let x=0;x<64;x++){
  const index=((y+12)*256+x+180)*3;
  const dark=reference[Math.floor(y/2)*32+Math.floor(x/2)];
  pixels[index]=dark?0:255;pixels[index+1]=dark?0:230;pixels[index+2]=0;
}
const result=await detectSolderBadge(await sharp(pixels,{raw:{width:256,height:256,channels:3}}).png().toBuffer());
assert.equal(result.requiresSoldering,true);
const white=await sharp({create:{width:256,height:256,channels:3,background:'white'}}).png().toBuffer();
assert.equal((await detectSolderBadge(white)).requiresSoldering,null);
console.log('PASS: soldering badge match and safe unknown result when no badge is visible.');
