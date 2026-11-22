from rpc import call
while True:
    r = call('probe_batch', budget=40)['result']
    print(r, flush=True)
    if r['remaining'] <= 0:
        break
