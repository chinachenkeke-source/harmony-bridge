"""Run against the installed phone app through an HDC-forwarded localhost port.
Usage: python3 transfer_roundtrip.py PORT TOKEN_FILE
Creates one explicitly named test fixture in the phone app's private sharing list.
"""
import base64, hashlib, json, pathlib, sys, urllib.request, urllib.error
port=int(sys.argv[1]); token=pathlib.Path(sys.argv[2]).read_text().strip()
def request(route, body, credential=token):
    data=json.dumps(body,ensure_ascii=True).encode('ascii')
    req=urllib.request.Request(f'http://127.0.0.1:{port}/{route}',data=data,headers={'Authorization':'Bearer '+credential,'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=20) as response:
        result=json.load(response)
    assert result['ok'],result['error']
    return result
try:
    request('list',{},'invalid')
    raise AssertionError('Server accepted invalid token')
except urllib.error.HTTPError as error:
    assert error.code==401
payload=(bytes(range(256))*12289)+b'HarmonyBridge EOF\n'
identifier=''; offset=0
for begin in range(0,len(payload),196608):
    chunk=payload[begin:begin+196608]
    result=request('upload',{'id':identifier,'name':'测试-多分块-往返校验.bin','offset':offset,'data':base64.b64encode(chunk).decode(),'final':begin+len(chunk)==len(payload)})
    identifier=result['id'];offset+=len(chunk)
    assert result['size']==offset
files=request('list',{})['files']
assert any(f['id']==identifier and f['size']==len(payload) for f in files)
received=bytearray()
while True:
    reply=request('download',{'id':identifier,'offset':len(received)})
    chunk=base64.b64decode(reply['data']);received.extend(chunk)
    if reply['eof']:break
    assert chunk
assert received==payload
try:
    request('download',{'id':'../../outside','offset':0})
    raise AssertionError('Server accepted invalid file id')
except urllib.error.HTTPError as error:
    assert error.code==400
print(json.dumps({'bytes':len(payload),'sha256':hashlib.sha256(received).hexdigest(),'roundtrip':'PASS','unicode_filename':'PASS','unauthorized_request':'REJECTED','invalid_file_id':'REJECTED'},indent=2))
