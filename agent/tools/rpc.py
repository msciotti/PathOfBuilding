#!/usr/bin/env python3
import socket,json,sys
def call(method,**params):
    s=socket.create_connection(("127.0.0.1",49090),timeout=600)
    s.sendall((json.dumps({"id":1,"method":method,"params":params})+"\n").encode())
    buf=b""
    while not buf.endswith(b"\n"): buf+=s.recv(1<<20)
    return json.loads(buf)
if __name__=="__main__":
    print(json.dumps(call(sys.argv[1],**json.loads(sys.argv[2] if len(sys.argv)>2 else "{}")),indent=1)[:int(sys.argv[3]) if len(sys.argv)>3 else 6000])
