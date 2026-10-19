#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Compile only the candidate DT and assemble a disposable existing-kernel FIT.

Not a firmware build or installable release. All outputs stay in a temporary
directory; the qualified SDK and APs are never modified.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile

def properties(blob):
    h=struct.unpack_from('>10I',blob);pos=h[2];strings=h[3];stack=[];out={}
    assert h[0]==0xd00dfeed
    while True:
        tag=struct.unpack_from('>I',blob,pos)[0];pos+=4
        if tag==1:
            end=blob.index(0,pos);stack.append(blob[pos:end].decode());pos=(end+4)&~3
        elif tag==2:stack.pop()
        elif tag==3:
            n,off=struct.unpack_from('>II',blob,pos);pos+=8
            end=blob.index(0,strings+off);name=blob[strings+off:end].decode()
            out['/'.join(stack)+'/'+name]=blob[pos:pos+n];pos+=(n+3)&~3
        elif tag==4:pass
        elif tag==9:return out
        else:raise ValueError(tag)

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--sdk',type=Path,required=True)
p.add_argument('--candidate-dts',type=Path,required=True)
p.add_argument('--its-script',type=Path,required=True)
p.add_argument('--qualified-fit',type=Path,required=True)
args=p.parse_args();sdk=args.sdk
linux=sdk/'build_dir/target-arm_cortex-a7+neon-vfpv4_musl_eabi/linux-ipq40xx_generic/linux-5.4.164'
dts=linux/'arch/arm/boot/dts'
original=properties(args.qualified_fit.read_bytes())
checks=[]
def check(name,result):
    assert result,name
    checks.append(name)
with tempfile.TemporaryDirectory(prefix='e410b-offline-fit-')as directory:
    tmp=Path(directory);dtbs={};maps={}
    for model in ('e410','e410b'):
        source=dts/('qcom-ipq4019-cambium-'+model+'.dts')if model=='e410'else args.candidate_dts
        run=subprocess.run(['gcc','-E','-nostdinc','-undef','-D__DTS__','-x','assembler-with-cpp','-I',str(dts),'-I',str(linux/'include'),str(source)],capture_output=True,check=True)
        dtb=tmp/(model+'.dtb')
        subprocess.run([str(linux/'scripts/dtc/dtc'),'-I','dts','-O','dtb','-o',str(dtb),'-'],input=run.stdout,capture_output=True,check=True)
        dtbs[model]=dtb;maps[model]=properties(dtb.read_bytes())
        old=properties(original['/images/fdt@'+model+'/data'])
        delta={key for key in set(old)|set(maps[model])if old.get(key)!=maps[model].get(key)}
        want={'/soc/wifi@a800000/qcom,ath10k-calibration-variant'}if model=='e410b'else set()
        check(model+' exact full DT property delta',delta==want)
        for phy in ('a000000','a800000'):
            key='/soc/wifi@'+phy+'/qcom,ath10k-calibration-variant'
            expected=b'Cambium-E410B-5G\0'if model=='e410b'and phy=='a800000'else None
            check(model+' '+phy+' correct variant or absence',maps[model].get(key)==expected)
    kernel=tmp/'qualified-kernel';kernel.write_bytes(original['/images/kernel@1/data'])
    call=['sh',str(args.its_script),'-k',str(kernel),'-A','arm','-C','none','-a','0x80208000','-e','0x80208000','-d','Cambium Networks Sage family','-D','config@5',
          '5:e410:'+str(dtbs['e410']),'17:e410b:'+str(dtbs['e410b']),'ap.dk01.1-c2:e410:'+str(dtbs['e410'])]
    its=tmp/'test.its';its.write_bytes(subprocess.check_output(call))
    fit=tmp/'OFFLINE-NOT-FOR-INSTALL.itb'
    subprocess.run([str(sdk/'staging_dir/host/bin/mkimage'),'-f',str(its),str(fit)],capture_output=True,check=True)
    new=properties(fit.read_bytes())
    check('kernel payload byte identical',new['/images/kernel@1/data']==original['/images/kernel@1/data'])
    for key,value in original.items():
        if key.startswith('/configurations/')or key in ('/images/kernel@1/load','/images/kernel@1/entry','/images/kernel@1/compression'):
            check('qualified FIT mapping '+key,new.get(key)==value)
    for model in ('e410','e410b'):
        check('FIT selected DT payload '+model,new['/images/fdt@'+model+'/data']==dtbs[model].read_bytes())
    result=dict(status='PASS',controls=len(checks),checks=checks,qualified_fit_sha256=hashlib.sha256(args.qualified_fit.read_bytes()).hexdigest(),candidate_dts_sha256=hashlib.sha256(args.candidate_dts.read_bytes()).hexdigest(),compiled_dtb_sha256={m:hashlib.sha256(p.read_bytes()).hexdigest()for m,p in dtbs.items()},scope='Disposable DT/FIT test, existing kernel unchanged; no full firmware build, AP write or release image')
print(json.dumps(result,indent=2))
