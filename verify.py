#!/usr/bin/env python3
"""Rebuild the published source and compare against the pinned mainnet runtime hashes.

Optional network RPC URL rechecks those hashes and proxy pointers at the recorded
block. No private key, wallet, AWS access, transaction submission or gas required.
"""
import argparse,hashlib,json,os,pathlib,subprocess,urllib.request

ROOT=pathlib.Path(__file__).resolve().parent
RPC_ENV='HORIZEN_RPC_URL'
SLOT='0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
def sha(data):return hashlib.sha256(data).hexdigest()
def executable(code):
 size=int.from_bytes(code[-2:],'big')
 assert 0<size<len(code)-2,'Invalid Solidity metadata length'
 return code[:-size-2]
def immutable_nodes(value,out):
 if isinstance(value,dict):
  if value.get('nodeType')=='VariableDeclaration' and value.get('mutability')=='immutable':out[str(value['id'])]=value
  for child in value.values():immutable_nodes(child,out)
 elif isinstance(value,list):
  for child in value:immutable_nodes(child,out)
def rpc(method,params):
 try:
  req=urllib.request.Request(os.environ[RPC_ENV],data=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(),headers={'Content-Type':'application/json','User-Agent':'Layrs-Contract-Verification/1.0'})
  with urllib.request.urlopen(req,timeout=30) as response:body=json.load(response)
  assert 'error' not in body
  return body['result']
 except Exception:raise RuntimeError('RPC read failed: '+method) from None
def main():
 global RPC_ENV
 parser=argparse.ArgumentParser();parser.add_argument('--solc',default='solc');parser.add_argument('--network',choices=['horizen','base'],default='horizen');args=parser.parse_args()
 RPC_ENV='BASE_RPC_URL' if args.network=='base' else 'HORIZEN_RPC_URL'
 version=subprocess.check_output([args.solc,'--version'],text=True)
 manifest=json.loads((ROOT/('base-deployment.json' if args.network=='base' else 'deployment.json')).read_text());cache={};results=[]
 if os.getenv(RPC_ENV):
  assert int(rpc('eth_chainId',[]),16)==manifest['chainId']
  assert rpc('eth_getBlockByNumber',[hex(manifest['checkedBlock']),False])['hash']==manifest['checkedBlockHash']
 def build(build_path,address,expected_hash,executable_hash=None):
  spec=json.loads((ROOT/build_path).read_text());assert spec['compilerVersion'].removeprefix('v') in version
  sources={}
  for path,digest in spec['sources'].items():
   file=(ROOT/spec.get('sourceFiles',{}).get(path,path)).resolve();assert file.is_relative_to(ROOT)
   content=file.read_bytes();assert sha(content)==digest,'Source hash mismatch: '+path
   sources[path]={'content':content.decode()}
  settings=dict(spec['settings']);settings['outputSelection']={'*':{'':['ast'],'*':['evm.deployedBytecode']}}
  inp=json.dumps({'language':'Solidity','sources':sources,'settings':settings}).encode();key=sha(inp)
  if key not in cache:
   p=subprocess.run([args.solc,'--standard-json'],input=inp,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True)
   output=json.loads(p.stdout);errors=[x for x in output.get('errors',[]) if x['severity']=='error'];assert not errors,errors
   cache[key]=output
  compiled=cache[key]['contracts'][spec['sourcePath']][spec['contractName']]['evm']['deployedBytecode']
  code=bytearray.fromhex(compiled['object']);immutable_count=0
  nodes={};immutable_nodes(cache[key]['sources'],nodes)
  for ident,locations in compiled.get('immutableReferences',{}).items():
   name=nodes[ident]['name']
   if name=='__self':replacement=bytes.fromhex(address[2:].zfill(64))
   else:
    binding=spec['immutableBindings'][name];assert binding['astId']==int(ident)
    replacement=bytes.fromhex(binding['value'][2:]);assert len(replacement)==32
    if os.getenv(RPC_ENV) and binding.get('getterCalldata'):
     assert rpc('eth_call',[{'to':address,'data':binding['getterCalldata']},hex(manifest['checkedBlock'])])==binding['value']
   for loc in locations:
    assert loc['length']==32
    start=loc['start'];assert code[start:start+32]==bytes(32)
    code[start:start+32]=replacement;immutable_count+=1
  if executable_hash:
   assert sha(executable(code))==executable_hash,'Compiled executable runtime mismatch: '+build_path
  else:
   assert sha(code)==expected_hash,'Compiled runtime mismatch: '+build_path
  if os.getenv(RPC_ENV):
   live=bytes.fromhex(rpc('eth_getCode',[address,hex(manifest['checkedBlock'])])[2:])
   assert sha(live)==expected_hash,'On-chain full runtime hash mismatch'
   assert (executable(live)==executable(code)) if executable_hash else (live==code)
  return immutable_count
 for contract in manifest['contracts']:
  address=contract['implementation'] or contract['address']
  immutables=build(contract['build'],address,contract.get('implementationRuntimeSha256',contract['runtimeSha256']),contract.get('executableRuntimeSha256'))
  if contract['implementation']:
   build(contract['proxyBuild'],contract['address'],contract['runtimeSha256'])
   if os.getenv(RPC_ENV):
    slot=rpc('eth_getStorageAt',[contract['address'],SLOT,hex(manifest['checkedBlock'])]);assert '0x'+slot[-40:]==contract['implementation']
  results.append({'contract':contract['id'],'runtimeMatch':True,'comparisonScope':'executable-without-metadata' if contract.get('executableRuntimeSha256') else 'full-runtime-including-metadata','immutableLocations':immutables})
  print('PASS',contract['id'],flush=True)
 if os.getenv(RPC_ENV):
  for contract in manifest.get('additionalDeployments',[]):
   code=bytes.fromhex(rpc('eth_getCode',[contract['address'],hex(manifest['checkedBlock'])])[2:])
   assert code and sha(code)==contract['runtimeSha256']
   if contract.get('implementation'):
    slot=rpc('eth_getStorageAt',[contract['address'],SLOT,hex(manifest['checkedBlock'])])
    assert '0x'+slot[-40:]==contract['implementation']
    code=bytes.fromhex(rpc('eth_getCode',[contract['implementation'],hex(manifest['checkedBlock'])])[2:])
    assert code and sha(code)==contract['implementationRuntimeSha256']
   if contract.get('asset'):
    result=rpc('eth_call',[{'to':contract['address'],'data':'0x38d52e0f'},hex(manifest['checkedBlock'])])
    assert '0x'+result[-40:]==contract['asset']
   print('PASS on-chain identity (not source rebuild)',contract['id'])
  checks=manifest.get('adapterRegistrationChecks',[])+[c for contract in manifest['contracts'] for c in contract.get('configurationChecks',[])]
  for check in checks:
   assert rpc('eth_call',[{'to':check['address'],'data':check['calldata']},hex(manifest['checkedBlock'])])==check['rawResult']
 print(json.dumps({'chainId':manifest['chainId'],'checkedBlock':manifest['checkedBlock'],'rpcReread':bool(os.getenv(RPC_ENV)),'results':results},indent=2))
if __name__=='__main__':main()
