// Static renderer for the olcOS hero picture used by the README concept
// preview (docs/assets/olcos-preview*.png). It is a trimmed copy of the
// motion study that produced App/Views/FirewallArmorRenderer.swift: the same
// stone masonry wall, whole-wall cracks, eleven chaotic rays, the seven-strand
// braided traffic line and two-direction packet trains. Only the page controls
// were removed; `time` is fixed by the caller, so the image is one settled
// frame (time = END is the connected, wall-breached state).
//
// Usage (browser): renderHeroScene(canvas, { time: 12, intensity: .6, bg: '#0B0C0F' })
function renderHeroScene(canvas, opts) {
  'use strict';
  const ctx = canvas.getContext('2d');
  const BURST = 7.3, END = 12, MERGE_X = 167, WALL = 1.15;
  const time = Math.min(END, opts.time ?? END), failed = !!opts.failed;
  const flowClock = opts.flowClock ?? time;
  const intensity = () => opts.intensity ?? .6;
  const linePhase = time * (Math.PI/5+(Math.PI*.85-Math.PI/5)*intensity());
  const BG = opts.bg ?? '#0b0c10';
  // The pre-armor Signal line: seven woven strands, envelope pinned at both
  // edges, amplitude and pace follow measured throughput (0…1 here).
  const LINE_H = 200, LINE_STRANDS = 3; // 7 strands: j = -3…3
  const lineAmp = i => LINE_H*(.13+.18*i);
  const lineSpeed = i => Math.PI/5+(Math.PI*.85-Math.PI/5)*i;
  function volumetric(x01,j,phase){
    const x=clamp(x01),strand=j+LINE_STRANDS;
    const envelope=Math.pow(Math.sin(Math.PI*x),1.6);
    const carrier=Math.sin(x*Math.PI*3.4-phase+strand*.24);
    const overtone=Math.sin(x*Math.PI*6-phase*.65+strand*.38)*.24;
    return (carrier*.65+overtone)*envelope;
  }
  let width = 900, height = 460, scale = 1, raf = null;
  const clamp = x => Math.max(0, Math.min(1, x));
  const smooth = x => {x = clamp(x); return x*x*(3-2*x);};
  const rand = n => {let v = Math.sin(n*127.1+311.7)*43758.5453; return v-Math.floor(v);};
  let blocks = [], stone = true, DEPTH = 31;
  let frontMask = []; // projected front skins of the current frame, for clipping cracks
  // Hologram: 71 hexagonal prisms. Stone: stretcher-bond masonry with a
  // crenellated top, like a fortress wall — same footprint, same physics.
  function buildBlocks(){
    blocks=[];
    if(!stone){
      DEPTH=31;
      for (let row=-5;row<=5;row++) for (let col=-3;col<=3;col++) {
        const u=col*34.64+(Math.abs(row)%2?17.32:0), v=row*30;
        if(Math.abs(u)>114) continue;
        const edges=[0,1,2,3,4,5].map(i=>{const a=i*Math.PI/3;return [Math.cos(a)*17.2,Math.sin(a)*17.2];});
        blocks.push({u,v,hex:true,edges,id:blocks.length,r:Math.hypot(u*.82,v),seed:rand(blocks.length+1)});
      }
      return;
    }
    DEPTH=22;
    const BW=40,BH=21,ROWS=5;
    const push=(u,v,w,h,extra={})=>blocks.push({u,v,w,h,edges:[[w/2,0],[-w/2,0],[0,h/2],[0,-h/2]],id:blocks.length,r:Math.hypot(u*.82,v),seed:rand(blocks.length+1),...extra});
    for (let row=-ROWS;row<=ROWS;row++){
      const odd=Math.abs(row)%2===1,v=row*BH;
      if(!odd){for(let col=-3;col<=3;col++)push(col*BW,v,BW,BH);}
      else{
        for(let col=-3;col<=2;col++)push(col*BW+BW/2,v,BW,BH);
        push(-3*BW-BW/4,v,BW/2,BH);push(3*BW+BW/4,v,BW/2,BH); // closers
      }
    }
    // Battlements: merlons with embrasures on the top course.
    for (let col=-3;col<=3;col++){
      if(Math.abs(col)%2===1)continue;
      const w=BW*.8,h=BH*1.15;
      push(col*BW,-(ROWS+1)*BH+(BH-h)/2,w,h,{merlon:true});
    }
  }
  buildBlocks();
  function resize(){
    const r=canvas.getBoundingClientRect(), dpr=Math.min(2,devicePixelRatio||1);
    width=r.width;height=r.height;scale=Math.max(width/930,height/560);
    canvas.width=Math.round(width*dpr);canvas.height=Math.round(height*dpr);
    ctx.setTransform(dpr,0,0,dpr,0,0);paint();
  }
  function project(p){return [p[0]*.78+p[2]*.82, p[1]+p[0]*.22-p[2]*.25];}
  function depth(p){return p[2]*.78-p[0]*.6-p[1]*.08;}
  function rotate(p,a,b,c){
    let [x,y,z]=p, yy=y*Math.cos(a)-z*Math.sin(a),zz=y*Math.sin(a)+z*Math.cos(a);y=yy;z=zz;
    let xx=x*Math.cos(b)+z*Math.sin(b);zz=-x*Math.sin(b)+z*Math.cos(b);x=xx;z=zz;
    return [x*Math.cos(c)-y*Math.sin(c),x*Math.sin(c)+y*Math.cos(c),z];
  }
  function polygon(pts){ctx.beginPath();pts.forEach((p,i)=>i?ctx.lineTo(...p):ctx.moveTo(...p));ctx.closePath();}
  function radial(x,y,r,color,power){
    if(power<=0)return;const grad=ctx.createRadialGradient(x,y,0,x,y,r);
    grad.addColorStop(0,`rgba(${color},${power})`);grad.addColorStop(.25,`rgba(${color},${power*.5})`);grad.addColorStop(1,`rgba(${color},0)`);
    ctx.fillStyle=grad;ctx.fillRect(x-r,y-r,r*2,r*2);
  }
  function pressureAt(t){
    const load=smooth((t-1.45)/1.55);
    return failed?load*(1-smooth((t-4.8)/1.25)):load;
  }
  function faces(t){
    const all=[],pressure=pressureAt(t),burst=failed?-1:t-BURST;
    blocks.forEach(b=>{
      const radialWeight=Math.exp(-b.r*b.r/8000);
      const delay=b.r/480 + b.seed*.08,age=Math.max(0,burst-delay);
      const fly=age;
      const fading=1-smooth((fly-.9)/1.2);
      if(fading<=0)return;
      const stretch=(1+pressure*radialWeight*(failed?.16:.055));
      let displacement=pressure*radialWeight*(failed?74:30);
      const v0=80+rand(b.id+52)*75, s=1-Math.exp(-fly*1.9);
      let center=[b.u*stretch+s*b.u*.9,b.v*stretch+s*b.v*.72+fly*fly*12,displacement+s*v0+fly*33];
      const ax=fly*(rand(b.id+23)-.5)*3,ay=fly*(rand(b.id+32)-.5)*3,az=fly*(rand(b.id+44)-.5)*2.6;
      const vertices=[];
      const shape=b.hex?[0,1,2,3,4,5].map(i=>{const a=(i*60+30)*Math.PI/180;return [Math.cos(a)*19.1,Math.sin(a)*19.1];})
        :[[-b.w/2+.6,-b.h/2+.6],[b.w/2-.6,-b.h/2+.6],[b.w/2-.6,b.h/2-.6],[-b.w/2+.6,b.h/2-.6]];
      const sides=shape.length;
      for(let z of [-DEPTH,DEPTH])for(const [x,y] of shape){
        let p=rotate([x,y,z],ax,ay,az);vertices.push(p.map((v,j)=>v+center[j]));
      }
      const front=crackFront(t),reach=smooth((front-b.r)/34)*(1-smooth((burst-.25)/1))*(failed?(1-smooth((t-4.8)/1.25)):1);
      const hot=Math.max(pressure*radialWeight*(1-smooth((burst-.25)/1)),reach*.42,fly>0?Math.max(0,1-fly)*.75:0);
      const groups=[[...Array(sides).keys()].reverse(),[...Array(sides).keys()].map(i=>i+sides)];
      for(let i=0;i<sides;i++)groups.push([i,(i+1)%sides,(i+1)%sides+sides,i+sides]);
      groups.forEach((idx,face)=>{
        const p=idx.map(i=>vertices[i]),mean=p.reduce((s,v)=>s+depth(v),0)/p.length;
        const front=face===1,back=face===0;
        const red=failed?smooth((t-4.05)/.65)*hot:0;
        let fill;
        if(stone){
          // Weathered granite: per-block tone, warmer front, cooler shadowed sides.
          const L=84+b.seed*30-(b.merlon?6:0);
          fill=front?[L*1.04+hot*70+red*80,L*1.0+hot*85-red*40,L*.92+hot*95-red*55]
            :back?[L*.34,L*.35,L*.38]
            :[L*(.58+face*.04)+hot*25+red*45,L*(.58+face*.04)+hot*35-red*15,L*(.6+face*.04)+hot*45-red*20];
        }else fill=front?[28+hot*45+red*65,43+hot*81-red*65,62+hot*83-red*50]:back?[12,23,36]:[15+face*2+hot*10+red*45,28+face*2+hot*29-red*20,44+face*3+hot*43-red*25];
        all.push({p:p.map(project),depth:mean,alpha:fading,front,hot,red,fill,seed:b.seed,pts:p});
      });
    });
    frontMask=all.filter(f=>f.front&&f.alpha>.5).map(f=>f.p);
    all.sort((a,b)=>a.depth-b.depth);
    all.forEach(f=>{
      ctx.globalAlpha=f.alpha;polygon(f.p);ctx.fillStyle=`rgb(${f.fill.map(Math.round).join(',')})`;ctx.fill();
      ctx.lineWidth=f.front?(stone?1.6:1.15)+f.hot*.7:.65;
      ctx.strokeStyle=f.red>.1?`rgba(255,125,150,${.24+f.red*.66})`:f.hot>.2?`rgba(135,225,255,${.24+f.hot*.66})`:stone?(f.front?'rgba(38,34,30,.9)':'rgba(30,28,26,.8)'):f.front?'rgba(89,139,164,.64)':'rgba(71,106,132,.55)';ctx.stroke();
      if(stone&&f.front){
        // Stone grain: deterministic speckles and a chipped highlight edge.
        const cx=f.p.reduce((s,p)=>s+p[0],0)/f.p.length,cy=f.p.reduce((s,p)=>s+p[1],0)/f.p.length;
        const w=Math.abs(f.p[1][0]-f.p[0][0]),h=Math.abs(f.p[2][1]-f.p[1][1]);
        for(let g=0;g<6;g++){const gx=cx+(rand(f.seed*997+g)-.5)*w*.8,gy=cy+(rand(f.seed*613+g)-.5)*h*.7;
          ctx.fillStyle=`rgba(0,0,0,${.10+rand(f.seed*77+g)*.12})`;ctx.beginPath();ctx.ellipse(gx,gy,1.2+rand(g+f.seed*31)*2.4,.8+rand(g*3+f.seed)*1.3,rand(g)*3,0,Math.PI*2);ctx.fill();}
        ctx.beginPath();ctx.moveTo(...f.p[0]);ctx.lineTo(...f.p[1]);ctx.strokeStyle=`rgba(255,250,240,${.14+f.hot*.2})`;ctx.lineWidth=.9;ctx.stroke();
        ctx.beginPath();ctx.moveTo(...f.p[3]);ctx.lineTo(...f.p[0]);ctx.strokeStyle=`rgba(255,250,240,${.08+f.hot*.1})`;ctx.lineWidth=.7;ctx.stroke();
      }
      if(f.front&&!stone){
        const cx=f.p.reduce((s,p)=>s+p[0],0)/6,cy=f.p.reduce((s,p)=>s+p[1],0)/6;
        polygon(f.p.map(p=>[cx+(p[0]-cx)*.79,cy+(p[1]-cy)*.79]));
        ctx.strokeStyle=`rgba(114,170,191,${.10+f.hot*.3})`;ctx.lineWidth=.55;ctx.stroke();
      }
    });ctx.globalAlpha=1;
  }
  // Both envelopes and every packet travel left to right.
  const wave=(x,j,t)=>Math.sin(x*.025-t*1.8+j*.23)*8+Math.sin(x*.012-t*.7+j*.15)*3+j*1.45;
  // A real three-dimensional braid: seven strands twist around the wavy
  // axis. Depth (z) drives brightness, width and paint order per segment, so
  // near strands pass in front of far ones and the line reads as a tube.
  function braid(left,half,amp,settle,charge){
    const i=intensity(),R=(7+9*i)*settle,step=3,n=7;
    const axis=x=>amp*volumetric((x-left)/(2*half),0,linePhase);
    const pts=[];
    for(let x=left;x<=half;x+=step){
      const ax=axis(x),tw=(x-left)*.028+linePhase*1.35;
      const row=[];
      for(let k=0;k<n;k++){
        const a=tw+k*Math.PI*2/n,z=Math.sin(a),yo=Math.cos(a)*R;
        // Slight perspective: nearer strands drift right/up as in project().
        row.push({x:x+z*R*.35,y:ax+yo-z*R*.12,z});
      }
      pts.push(row);
    }
    ctx.lineCap='round';
    const edge=x=>{const q=(x-left)/(2*half);return smooth(q/.2)*smooth((1-q)/.2);};
    // Soft body glow first, behind every strand.
    ctx.beginPath();for(let x=left;x<=half;x+=6){const y=axis(x);x===left?ctx.moveTo(x,y):ctx.lineTo(x,y);}
    const glow=ctx.createLinearGradient(left,0,half,0);
    glow.addColorStop(0,'rgba(120,200,255,0)');glow.addColorStop(.3,'rgba(120,200,255,.16)');glow.addColorStop(.7,'rgba(140,240,215,.16)');glow.addColorStop(1,'rgba(140,240,215,0)');
    ctx.strokeStyle=glow;ctx.lineWidth=R*3.2+8;ctx.globalAlpha=settle*charge;ctx.stroke();
    // Segments sorted back-to-front for each slice.
    for(let s=1;s<pts.length;s++){
      const order=[...Array(n).keys()].sort((a,b)=>pts[s][a].z-pts[s][b].z);
      const e=edge((pts[s][0].x+pts[s-1][0].x)/2);
      for(const k of order){
        const a=pts[s-1][k],b=pts[s][k],d=(b.z+1)/2;
        const hue=k%2?[160,230,255]:[150,255,215];
        const bright=.18+.66*d;
        ctx.beginPath();ctx.moveTo(a.x,a.y);ctx.lineTo(b.x,b.y);
        const bg=[11,12,16];ctx.strokeStyle=`rgb(${Math.round(bg[0]+(hue[0]-bg[0])*bright)},${Math.round(bg[1]+(hue[1]-bg[1])*bright)},${Math.round(bg[2]+(hue[2]-bg[2])*bright)})`;
        ctx.lineWidth=(1.1+2.1*d)*(.6+.4*settle);
        ctx.globalAlpha=charge*settle*e;
        ctx.stroke();
      }
    }
    // Internet traffic, not a decoration: bursty packet trains ride the
    // strands. Most run outward (left→right); replies come back the other
    // way in a second tint. Train length and count follow throughput.
    const trains=6+Math.round(i*10),span=2*half;
    const strandAt=(x,k)=>{const ax=axis(x),tw=(x-left)*.028+linePhase*1.35,a=tw+k*Math.PI*2/n,z=Math.sin(a);return {x:x+z*R*.35,y:ax+Math.cos(a)*R-z*R*.12,z};};
    for(let m=0;m<trains;m++){
      const back=rand(m+301)<.28,k=Math.floor(rand(m+211)*n);
      const speed=(150+rand(m+401)*120)*(back?.8:1)*(.6+.7*i),len=30+rand(m+501)*70;
      const period=span+220+rand(m+601)*300,head=((flowClock*speed+rand(m+701)*period)%period);
      const x0=back?half-head:left+head;
      const dir=back?1:-1;
      for(let q=0;q<len;q+=3){
        const x=x0+dir*q;if(x<left||x>half)continue;
        const pnt=strandAt(x,k),d=(pnt.z+1)/2,fadeTail=1-q/len;
        ctx.beginPath();ctx.moveTo(pnt.x,pnt.y);const nx=strandAt(x+dir*3,k);ctx.lineTo(nx.x,nx.y);
        ctx.strokeStyle=back?'#ffcf93':'#ffffff';ctx.lineWidth=2+3.2*d;
        ctx.globalAlpha=charge*settle*edge(x)*(.3+.7*d)*Math.pow(fadeTail,.6);ctx.stroke();
      }
      const h=strandAt(x0,k);if(x0>left&&x0<half)radial(h.x,h.y,16,back?'255,200,140':'200,255,235',charge*settle*edge(x0)*.7*((h.z+1)/2));
    }
    ctx.globalAlpha=1;
  }
  function beam(t){
    const broken=!failed&&t>BURST+.45,charge=smooth((t-.45)/1.25);
    const red=failed&&t>=4.05;
    const half=Math.min(490,width/(2*scale));
    const extent=broken?half:(red?-42:-38+smooth((t-1)/1.1)*(12+DEPTH))*WALL;
    const left=-half,end=extent;
    // After the burst the beam settles into the woven Signal line.
    const settle=broken?smooth((t-BURST-.6)/1.9):0,amp=lineAmp(intensity());
    if(t<.3)return;
    ctx.save();
    const grad=ctx.createLinearGradient(left,0,Math.max(250,end),0);
    grad.addColorStop(0,red?'#ff5f7c':'#41cde9');grad.addColorStop(.35,red?'#ff8496':'#9396ff');grad.addColorStop(.6,red?'#ff9aaa':broken?'#75ecc5':'#c4e6ff');grad.addColorStop(1,red?'#ed597b':'#58d99e');
    const shape=(x,j)=>{
      const focus=broken?1:1-.78*Math.exp(-x*x/2200);
      const narrow=wave(x,j,flowClock)*focus;
      if(settle<=0)return narrow;
      const wide=j*3+amp*volumetric((x-left)/(2*half),Math.max(-LINE_STRANDS,Math.min(LINE_STRANDS,j)),linePhase);
      return narrow*(1-settle)+wide*settle;
    };
    if(settle<1)for(let j=-5;j<=5;j++){
      ctx.beginPath();for(let x=left;x<=end;x+=2){const y=shape(x,j);x===left?ctx.moveTo(x,y):ctx.lineTo(x,y);}
      ctx.strokeStyle=grad;ctx.globalAlpha=charge*(j===0?.96:.38)*(1-settle);ctx.lineWidth=j===0?2:1;
      ctx.lineCap='round';ctx.stroke();
    }
    if(settle>0)braid(left,half,amp,settle,charge);
    ctx.globalAlpha=1;
    for(let i=0;i<30;i++){
      const x=left+((i*61+flowClock*(broken?165:98))%(Math.abs(left)+490));if(x>end)continue;
      let y=shape(x,i%9-4);ctx.fillStyle=x>25&&broken?'#b0ffe1':red?'#ffacb7':'#d2e9ff';
      ctx.globalAlpha=charge*.75*(1-settle*.55);ctx.beginPath();ctx.ellipse(x,y,2.4,.9,0,0,Math.PI*2);ctx.fill();
    }ctx.globalAlpha=1;ctx.restore();
  }
  function core(t){
    const pressure=pressureAt(t)*(1-smooth((t-BURST)/.7));
    if(pressure>0){
      radial(7,-2,35+pressure*84,'94,190,245',pressure*.31);
      radial(7,-2,8+pressure*17,'188,236,255',pressure*.72);
      ctx.strokeStyle=`rgba(167,235,255,${pressure*.83})`;ctx.lineWidth=1.25;
      for(let k=0;k<9;k++){
        const a=k*Math.PI*2/9+.15,r=pressure*(36+rand(k+3)*55);
        ctx.beginPath();ctx.moveTo(7,0);ctx.lineTo(7+Math.cos(a+.2)*r*.38,Math.sin(a+.2)*r*.38);
        ctx.lineTo(7+Math.cos(a-.13)*r*.72,Math.sin(a-.13)*r*.72);ctx.lineTo(7+Math.cos(a)*r,Math.sin(a)*r);ctx.stroke();
      }
    }
    if(failed&&t>4.05)radial(-100,0,30,'255,75,109',.4*(1-smooth((t-5)/1.5)));
  }
  // Radius (wall units) the crack network has reached: whole wall by ~2.9 s.
  function crackFront(t){return smooth((t-1.5)/1.4)*205;}
  function fissures(t){
    if(t<1.5||t>BURST+.15)return;
    const growth=smooth((t-1.5)/1.4)*(1-smooth((t-BURST)/.15))*(failed?(1-smooth((t-4.8)/1.25))*.65:1);
    if(growth<=0)return;
    const p=pressureAt(t),center=project([0,0,DEPTH+p*(failed?74:30)]);
    const red=failed&&t>4.05;
    const front=crackFront(t);
    if(!frontMask.length)return;
    ctx.save();ctx.beginPath();frontMask.forEach(poly=>{poly.forEach((q,i)=>i?ctx.lineTo(...q):ctx.moveTo(...q));ctx.closePath();});ctx.clip();
    // Nine trunk cracks run to the wall edges; each spawns jagged branches
    // and hairline twigs as the front passes, so the whole armor is webbed.
    const draw=(pts,alphaScale,width)=>{
      for(const [line,alpha,color] of [[width*3.2,.16,'80,194,255'],[width,.88,'119,224,255'],[width*.42,1,'237,254,255']]){
        ctx.beginPath();pts.forEach((q,i)=>i?ctx.lineTo(...q):ctx.moveTo(...q));
        ctx.strokeStyle=`rgba(${red?'255,148,165':color},${Math.min(1,growth*alpha*alphaScale)})`;ctx.lineWidth=line;ctx.stroke();
      }
    };
    const polyline=(from,angle,length,seed,segments,wobble)=>{
      const pts=[from];let a=angle,x=from[0],y=from[1];
      for(let j=1;j<=segments;j++){
        a+=(rand(seed+j*7)-.5)*wobble;const r=length/segments*(.7+rand(seed+j*3)*.6);
        x+=Math.cos(a)*r*.78;y+=Math.sin(a)*r;pts.push([x,y]);
      }
      return pts;
    };
    for(let k=0;k<9;k++){
      const angle=k*Math.PI*2/9+.26+(rand(k+61)-.5)*.3;
      const full=170+rand(k+22)*50,len=Math.min(full,front*(.85+rand(k+5)*.3));
      const trunk=polyline(center,angle,len,k*97,10,.85);
      draw(trunk,1,1.5);
      for(let branch=1;branch<=4;branch++){
        const at=Math.min(trunk.length-1,1+branch);const from=trunk[at];
        const grown=smooth((len/full*7-at)/1.5);if(grown<=0)continue;
        const a=angle+(branch%2?.75:-.8)+(rand(k*13+branch)-.5)*.5;
        const twig=polyline(from,a,(26+rand(k+branch*31)*38)*grown,k*131+branch*17,3,.7);
        draw(twig,.9,.85);
        if(grown>.6){const leaf=polyline(twig[2],a+(branch%2?-.9:.95),(10+rand(k+branch*7)*14)*(grown-.6)/.4,k*7+branch*53,2,.6);draw(leaf,.7,.5);}
      }
    }
    ctx.restore();
  }
  function seepAndMerge(t,drawCore){
    if(failed||t<3.05)return;
    const fade=1-smooth((t-BURST-.05)/1);
    const pressure=smooth((t-1.45)/1.55);
    if(!drawCore&&fade>0)for(let k=0;k<11;k++){
      // A real seam of a real prism on the wall's lit face, picked at random.
      const cand=blocks.filter(b=>b.u>0&&Math.abs(b.v)<=120&&!b.merlon);
      const b=cand[Math.floor(rand(k*7+3)*cand.length)];
      const w=Math.exp(-b.r*b.r/8000),stretch=1+pressure*w*.055;
      const e=b.edges[Math.floor(rand(k+41)*b.edges.length)];
      const origin=project([b.u*stretch+e[0],b.v*stretch+e[1],DEPTH+pressure*w*30]).map(v=>v*WALL);
      const delay=rand(k+77)*.9,pace=1.1+rand(k+91)*1.2;
      const progress=smooth((t-3.05-delay)/pace);
      if(progress<=0)continue;
      const jitter=Math.sin(flowClock*(1.7+rand(k)*2.5)+k)*9*(1-progress*.6);
      const endY=wave(MERGE_X,0,flowClock)*.25;
      const c1=[origin[0]+40+rand(k+3)*60,origin[1]+(rand(k+9)-.5)*120+jitter],c2=[MERGE_X-20-rand(k+13)*70,endY+(rand(k+17)-.5)*90-jitter];
      const at=q=>{const m=1-q;return [m*m*m*origin[0]+3*m*m*q*c1[0]+3*m*q*q*c2[0]+q*q*q*MERGE_X,m*m*m*origin[1]+3*m*m*q*c1[1]+3*m*q*q*c2[1]+q*q*q*endY];};
      const gradient=ctx.createLinearGradient(origin[0],origin[1],MERGE_X,endY);
      gradient.addColorStop(0,k%2?'#b8c8ff':'#8de4ff');gradient.addColorStop(1,'#8bf4cf');
      for(let layer=0;layer<2;layer++){
        ctx.beginPath();for(let j=0;j<=60;j++){const xy=at(j/60*progress);j?ctx.lineTo(...xy):ctx.moveTo(...xy);}
        ctx.strokeStyle=gradient;ctx.globalAlpha=fade*(layer?.85:.13);ctx.lineWidth=layer?1.1:4.5;ctx.stroke();
      }
      ctx.globalAlpha=fade;radial(...origin,7,'152,224,255',.4*progress);
      for(let j=0;j<3;j++){
        const q=((flowClock*(.5+rand(k+j)*.5)+j*.31+k*.05)%1+1)%1;if(q>progress)continue;
        const xy=at(q);ctx.fillStyle='#d3fff0';ctx.beginPath();ctx.arc(...xy,1.25,0,Math.PI*2);ctx.fill();
      }
    }
    ctx.globalAlpha=1;
    if(!drawCore)return;
    const joined=smooth((t-5.25)/1.05)*(1-smooth((t-BURST-.6)/1.9));
    const settled=smooth((t-BURST-.3)/1.4);
    if(joined<=0)return;
    if(joined<=0)return;
    const right=Math.min(490,width/(2*scale));
    const left=t>=BURST?-Math.min(490,width/(2*scale)):MERGE_X;
    const grad=ctx.createLinearGradient(left,0,right,0);
    grad.addColorStop(0,'#82cfff');grad.addColorStop(.45,'#a3ccff');grad.addColorStop(.72,'#80f1c7');grad.addColorStop(1,'#50d99a');
    const trace=()=>{ctx.beginPath();for(let x=left;x<=right;x+=2){const y=wave(x,0,flowClock)*.25;x===left?ctx.moveTo(x,y):ctx.lineTo(x,y);}};
    // The fused core becomes visibly thicker before the wall can burst.
    for(let [line,alpha] of [[17,.07],[9,.16],[4.2,.88],[1.4,.95]]){
      trace();ctx.strokeStyle=line===1.4?'#e1fff4':grad;ctx.lineWidth=line*joined;ctx.globalAlpha=alpha*joined;ctx.stroke();
    }
    ctx.globalAlpha=1;
    // A shared packet clock makes the output's direction unmistakable.
    const source=-Math.min(490,width/(2*scale)),span=right-source;
    for(let i=0;i<11;i++){
      const x=source+((flowClock*180+i*83)%span);
      if(x<left)continue;
      ctx.beginPath();
      for(let tail=Math.max(left,x-11);tail<=x;tail+=1){
        const y=wave(tail,0,flowClock)*.25;
        tail===Math.max(left,x-11)?ctx.moveTo(tail,y):ctx.lineTo(tail,y);
      }
      ctx.strokeStyle='#effff8';ctx.lineWidth=2.5;ctx.globalAlpha=joined*.95;ctx.stroke();
    }
    ctx.globalAlpha=1;
    radial(MERGE_X,wave(MERGE_X,0,flowClock)*.25,18,'138,249,217',joined*.4*(1-settled));
  }
  function debris(t){
    const b=t-BURST;if(failed||b<0||b>2)return;
    radial(15,-3,80+b*70,'150,226,255',Math.max(0,.45-b*.8));
    for(let i=0;i<85;i++){
      const a=rand(i+345)*Math.PI*2,vel=40+rand(i+84)*155;
      const x=Math.cos(a)*b*vel*.8+b*45,y=Math.sin(a)*b*vel;
      ctx.globalAlpha=(1-smooth(b/2))*(.25+rand(i+71)*.6);
      ctx.strokeStyle=i%3?'#90d9f1':'#a9a0e5';ctx.lineWidth=i%4===0?1.8:.7;
      ctx.beginPath();ctx.moveTo(x,y);ctx.lineTo(x-Math.cos(a)*7,y-Math.sin(a)*7);ctx.stroke();
    }ctx.globalAlpha=1;
    const a=1-smooth(b/1.25);ctx.strokeStyle=`rgba(142,221,247,${a*.6})`;ctx.lineWidth=1;
    ctx.beginPath();ctx.ellipse(12+b*24,0,8+b*75,15+b*133,-.12,0,Math.PI*2);ctx.stroke();
  }
  function paint(){
    ctx.clearRect(0,0,width,height);ctx.fillStyle=BG;ctx.fillRect(0,0,width,height);
    ctx.save();ctx.translate(width*.51,height*.51);ctx.scale(scale,scale);
    // Both the core and the entering beam are behind the opaque prism faces.
    // Pressure separates the prisms and exposes the internal light through
    // real gaps. Flying blocks continue to occlude the beam during the burst.
    beam(time);ctx.save();ctx.scale(WALL,WALL);core(time);ctx.restore();seepAndMerge(time,true);
    ctx.save();ctx.scale(WALL,WALL);faces(time);fissures(time);ctx.restore();seepAndMerge(time,false);
    ctx.save();ctx.scale(WALL,WALL);debris(time);ctx.restore();ctx.restore();
  }
  const r = canvas.getBoundingClientRect(), dpr = Math.min(2, devicePixelRatio || 1);
  width = r.width; height = r.height; scale = Math.max(width/930, height/560) * (opts.zoom ?? 1);
  canvas.width = Math.round(width*dpr); canvas.height = Math.round(height*dpr);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  paint();
}
