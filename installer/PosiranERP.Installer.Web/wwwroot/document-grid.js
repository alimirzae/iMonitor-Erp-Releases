/* AiBOS Document Grid v1: engine-independent OCR TSV line/column reconstruction.
   Coordinates use original OCR image pixels; no financial record is persisted. */
(function(global){
'use strict';
function normalize(v){return String(v||'').replace(/[۰-۹]/g,c=>String(c.charCodeAt(0)-1776)).replace(/[٠-٩]/g,c=>String(c.charCodeAt(0)-1632)).replace(/[٬،]/g,',').replace(/[٫]/g,'.').trim();}
function parse(tsv){
 const lines=String(tsv||'').replace(/\r/g,'').split('\n');const keys=lines.shift().split('\t');
 const k=n=>keys.indexOf(n);if(!['text','left','top','width','height','conf'].every(x=>k(x)>=0))return[];
 const words=[];for(const line of lines){const c=line.split('\t');if(c.length<keys.length)continue;
 const text=c.slice(k('text')).join('\t').trim(),conf=Number(c[k('conf')]);
 const w={text,normalized:normalize(text),confidence:conf,x:Number(c[k('left')]),y:Number(c[k('top')]),width:Number(c[k('width')]),height:Number(c[k('height')])};
 if(text&&conf>=0&&[w.x,w.y,w.width,w.height].every(Number.isFinite)&&w.width>0&&w.height>0)words.push(w);
 }return words;
}
function median(values){if(!values.length)return 0;const sorted=[...values].sort((a,b)=>a-b);return sorted[Math.floor(sorted.length/2)];}
function reconstruct(tsv,{direction='rtl',minConfidence=0}={}){
 const words=parse(tsv).filter(w=>w.confidence>=minConfidence);if(!words.length)return{columns:[],rows:[],words:[],warning:'no OCR words'};
 const h=Math.max(5,median(words.map(w=>w.height)));const tolerance=Math.max(4,h*.65);
 const rows=[];
 for(const w of [...words].sort((a,b)=>a.y+a.height/2-(b.y+b.height/2))){
  const cy=w.y+w.height/2;let row=rows.find(r=>Math.abs(r.cy-cy)<=tolerance);
  if(!row){row={cy,words:[]};rows.push(row)}row.words.push(w);row.cy=row.words.reduce((sum,z)=>sum+z.y+z.height/2,0)/row.words.length;
 }
 rows.sort((a,b)=>a.cy-b.cy);
 const nodes=words.map(w=>({x:w.x+w.width/2,w})).sort((a,b)=>a.x-b.x);
 const clusters=[];const xs=words.map(w=>w.x+w.width/2).sort((a,b)=>a-b);
 const broad=Math.max(h*2.5,(xs[xs.length-1]-xs[0])*.075);
 for(const node of nodes){let target=clusters.find(c=>Math.abs(c.center-node.x)<broad);
  if(!target){target={center:node.x,words:[]};clusters.push(target)}
  target.words.push(node.w);target.center=median(target.words.map(w=>w.x+w.width/2));
 }
 // Discard isolated noise columns and maintain stable physical ordering.
 let columns=clusters.filter(c=>c.words.length>=Math.max(2,Math.floor(rows.length*.18)))
  .sort((a,b)=>direction==='rtl'?b.center-a.center:a.center-b.center);
 if(columns.length===0)columns=clusters.sort((a,b)=>direction==='rtl'?b.center-a.center:a.center-b.center);
 const output=rows.map((row,index)=>{
  const cells=columns.map(()=>[]);for(const w of row.words){let best=0,d=Infinity;
   columns.forEach((c,i)=>{const dist=Math.abs(c.center-(w.x+w.width/2));if(dist<d){d=dist;best=i}});
   cells[best].push(w);
  }
  const values=cells.map(cell=>{cell.sort((a,b)=>direction==='rtl'?b.x-a.x:a.x-b.x);return{text:cell.map(w=>w.text).join(' '),normalized:normalize(cell.map(w=>w.text).join(' ')),confidence:cell.length?cell.reduce((a,w)=>a+w.confidence,0)/cell.length:0,
    bounds:cell.length?{x:Math.min(...cell.map(w=>w.x)),y:Math.min(...cell.map(w=>w.y)),right:Math.max(...cell.map(w=>w.x+w.width)),bottom:Math.max(...cell.map(w=>w.y+w.height))}:null};});
  return{index:index+1,y:row.cy,cells:values,review:values.some(v=>v.text&&v.confidence<55)};
 });
 return{columns:columns.map((c,i)=>({index:i+1,center:c.center})),rows:output,words,warning:columns.length>10?'Many columns detected; manual template assignment recommended':null};
}
global.AiBOSDocumentGrid={parse,reconstruct,normalize};
})(window);
