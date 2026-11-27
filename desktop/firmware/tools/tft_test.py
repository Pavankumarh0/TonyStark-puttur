"""LEO TFT kiosk — protocol test from the PC (real device on a serial port).

    python tft_test.py [--port COM9]            # checks that need no pairing
    python tft_test.py --pair                   # + pairing (confirm on the device: tap Confirm or press BOOT)
    python tft_test.py --paired                 # + signed-frame tests with the saved key

The pairing key is stored encrypted with Windows DPAPI (current user) in %LOCALAPPDATA%\\LEO\\tft_key.dpapi.
Run with PlatformIO's Python (has pyserial):  %USERPROFILE%\\.platformio\\penv\\Scripts\\python.exe
"""
import argparse, ctypes, ctypes.wintypes as wt, hashlib, hmac, json, os, secrets, sys, time

import serial

KEY_FILE = os.path.join(os.environ['LOCALAPPDATA'], 'LEO', 'tft_key.dpapi')
results = []


# ---- DPAPI (Windows-supported secret storage, bound to this Windows user) ----
class _Blob(ctypes.Structure):
    _fields_ = [('cbData', wt.DWORD), ('pbData', ctypes.POINTER(ctypes.c_char))]


def _blob(b):
    buf = ctypes.create_string_buffer(b, len(b))
    return _Blob(len(b), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char))), buf


def dpapi(data, protect):
    inp, _keep = _blob(data)
    out = _Blob()
    fn = ctypes.windll.crypt32.CryptProtectData if protect else ctypes.windll.crypt32.CryptUnprotectData
    if not fn(ctypes.byref(inp), None, None, None, None, 0, ctypes.byref(out)):
        raise OSError('DPAPI failed')
    res = ctypes.string_at(out.pbData, out.cbData)
    ctypes.windll.kernel32.LocalFree(out.pbData)
    return res


def save_key(k):
    os.makedirs(os.path.dirname(KEY_FILE), exist_ok=True)
    open(KEY_FILE, 'wb').write(dpapi(k, True))


def load_key():
    return dpapi(open(KEY_FILE, 'rb').read(), False) if os.path.exists(KEY_FILE) else None


# ---- framing (must match the firmware: MAC over the exact frame bytes without ,"mac") ----
def frame(t, b, sid, seq, key=None):
    s = json.dumps({'v': 1, 't': t, 'sid': sid, 'seq': seq, 'b': b}, separators=(',', ':'))
    if key:
        s = s[:-1] + ',"mac":"' + hmac.new(key, s.encode(), hashlib.sha256).hexdigest()[:32] + '"}'
    return s


def verify(line, key):
    i = line.rfind(',"mac":"')
    if i < 0 or not line.endswith('"}') or len(line) - i != 42:
        return False
    body = line[:i] + '}'
    return hmac.compare_digest(hmac.new(key, body.encode(), hashlib.sha256).hexdigest()[:32], line[i + 8:i + 40])


class Dev:
    def __init__(self, port):
        self.s = serial.Serial(port, 115200, timeout=0.05)  # opening resets the ESP32 (auto-reset)
        self.buf = b''

    def send(self, line):
        self.s.write(line.encode() + b'\n')

    def frames(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            self.buf += self.s.read(4096)
            while b'\n' in self.buf:
                raw, self.buf = self.buf.split(b'\n', 1)
                txt = raw.decode(errors='replace').strip()
                if txt.startswith('{'):
                    try:
                        yield txt, json.loads(txt)
                    except ValueError:
                        pass

    def wait(self, pred, seconds=3.0):
        for txt, f in self.frames(seconds):
            if pred(f):
                return txt, f
        return None, None

    def close(self):
        self.s.close()


def check(name, ok, detail=''):
    results.append((name, bool(ok), detail))
    print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}")


def err_is(code):
    return lambda f: f.get('t') == 'ERROR' and f['b'].get('code') == code


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', default='COM9')
    ap.add_argument('--pair', action='store_true')
    ap.add_argument('--paired', action='store_true')
    a = ap.parse_args()

    d = Dev(a.port)
    _, hello = d.wait(lambda f: f.get('t') == 'HELLO', 6)
    check('HELLO after reset', hello, hello and f"fw {hello['b']['fw']} chip {hello['b']['chip']} paired={hello['b']['paired']} touch={hello['b']['touch']}")
    if not hello:
        sys.exit(1)
    sid = hello['sid']

    d.send(json.dumps({'v': 1, 't': 'HELLO', 'seq': 1, 'b': {}}))
    _, h2 = d.wait(lambda f: f.get('t') == 'HELLO')
    check('HELLO on request, same session', h2 and h2['sid'] == sid)

    d.send('this is not json')
    check('garbage line ignored (not JSON)', True, 'firmware ignores non-{ lines')
    d.send('{"v":1,"t":"PING",')
    check('broken JSON → ERROR bad_json', d.wait(err_is('bad_json'))[1])
    d.send('{' + '"x":"' + 'A' * 1500 + '"}')
    check('oversized frame → ERROR too_long', d.wait(err_is('too_long'))[1])
    d.send(json.dumps({'v': 2, 't': 'PING', 'seq': 2, 'b': {}}))
    check('wrong protocol version → ERROR bad_version', d.wait(err_is('bad_version'))[1])
    d.send(json.dumps({'v': 1, 't': 'RUN_SHELL', 'sid': sid, 'seq': 3, 'b': {'cmd': 'format c:'}}))
    check('unknown type (e.g. RUN_SHELL) → ERROR unknown_type', d.wait(err_is('unknown_type'))[1])
    d.send(json.dumps({'v': 1, 't': 'PAIR_KEY', 'sid': sid, 'seq': 4, 'b': {'code': '123456', 'key': '00' * 32}}))
    check('PAIR_KEY without a confirmed pairing → ERROR not_pairing', d.wait(err_is('not_pairing'))[1])

    key = load_key()
    if not hello['b']['paired']:
        fake = secrets.token_bytes(32)
        d.send(frame('STATUS', {'state': 'running', 'text': 'forged'}, sid, 5, fake))
        check('signed command while unpaired → ERROR not_paired', d.wait(err_is('not_paired'))[1])

    if a.pair:
        code = f'{secrets.randbelow(10**6):06d}'
        d.send(frame('PAIR_START', {'code': code}, sid, 10))
        _, w = d.wait(lambda f: f.get('t') == 'PAIR_WAIT', 3)
        check('PAIR_START → device shows code', w and w['b']['code'] == code, f'code {code}')
        print(f'\n>>> On the device: the code {code} is shown. Tap Confirm or press BOOT (60 s) <<<\n', flush=True)
        _, acc = d.wait(lambda f: f.get('t') in ('PAIR_ACCEPT', 'PAIR_REJECT'), 62)
        check('user confirmed on the device', acc and acc['t'] == 'PAIR_ACCEPT' and acc['b']['code'] == code,
              acc and acc['t'] or 'no answer (timeout)')
        if acc and acc['t'] == 'PAIR_ACCEPT':
            key = secrets.token_bytes(32)
            d.send(frame('PAIR_KEY', {'code': code, 'key': key.hex()}, sid, 11))
            txt, done = d.wait(lambda f: f.get('t') == 'PAIR_DONE', 4)
            check('PAIR_DONE signed with the new key', done and verify(txt, key))
            if done:
                save_key(key)
                check('key stored with Windows DPAPI', load_key() == key, KEY_FILE)
        a.paired = a.paired or (acc and acc['t'] == 'PAIR_ACCEPT')

    if a.paired and key:
        seq = 100
        d.send(frame('PING', {}, sid, seq, key))
        txt, pong = d.wait(lambda f: f.get('t') == 'PONG')
        check('signed PING → signed PONG', pong and verify(txt, key))
        replay = frame('PING', {}, sid, seq, key)
        d.send(replay)
        check('replayed frame (same seq) → ERROR replay', d.wait(err_is('replay'))[1])
        seq += 1
        good = frame('STATUS', {'state': 'running', 'text': 'Tampered?', 'project': 'jarvis'}, sid, seq, key)
        d.send(good.replace('Tampered?', 'Tampered!'))
        check('tampered body → ERROR bad_mac', d.wait(err_is('bad_mac'))[1])
        d.send(frame('STATUS', {'state': 'running', 'text': 'x'}, sid, seq, secrets.token_bytes(32)))
        check('wrong key → ERROR bad_mac', d.wait(err_is('bad_mac'))[1])
        d.send(frame('STATUS', {'state': 'running', 'text': 'x'}, 'deadbeefdeadbeef', seq, key))
        check('old/other session id → ERROR bad_session', d.wait(err_is('bad_session'))[1])
        d.send(json.dumps({'v': 1, 't': 'STATUS', 'sid': sid, 'seq': seq, 'b': {'text': 'unsigned'}}))
        check('unsigned command while paired → ERROR unsigned', d.wait(err_is('unsigned'))[1])

        seq += 1
        d.send(frame('STATUS', {'state': 'running', 'text': 'LEO Desktop connected. Protocol test running.', 'project': 'jarvis'}, sid, seq, key))
        txt, ack = d.wait(lambda f: f.get('t') == 'ACK' and f['b'].get('ack') == seq)
        check('STATUS shown (signed ACK)', ack and verify(txt, key))
        seq += 1
        d.send(frame('NOTIFY', {'level': 'info', 'text': 'Hello from the PC'}, sid, seq, key))
        check('NOTIFY shown (ACK)', d.wait(lambda f: f.get('t') == 'ACK' and f['b'].get('ack') == seq)[1])
        seq += 1
        nonce = secrets.token_hex(8)
        d.send(frame('APPROVAL_REQUEST', {'id': 'test1', 'nonce': nonce, 'title': 'Commit 2 files to jarvis?',
                                          'lines': ['README.md', 'docs/PLAN.md', 'Tap Approve or Deny']}, sid, seq, key))
        check('APPROVAL_REQUEST shown (ACK)', d.wait(lambda f: f.get('t') == 'ACK' and f['b'].get('ack') == seq)[1])
        print('\n>>> On the device: tap Approve or Deny (30 s) <<<\n', flush=True)
        txt, ev = d.wait(lambda f: f.get('t') == 'UI_EVENT', 32)
        check('touch → signed UI_EVENT bound to the request',
              ev and verify(txt, key) and ev['b'].get('req') == 'test1' and ev['b'].get('nonce') == nonce,
              ev and f"button={ev['b'].get('button')}" or 'no touch (timeout)')
        seq += 1
        d.send(frame('RESULT', {'ok': True, 'text': 'Protocol test finished'}, sid, seq, key))
        d.wait(lambda f: f.get('t') == 'ACK' and f['b'].get('ack') == seq)

    d.close()
    # Reconnect: reopening the port resets the board → new session; the old session's frames are refused.
    if a.paired and key:
        d = Dev(a.port)
        _, h3 = d.wait(lambda f: f.get('t') == 'HELLO', 6)
        check('reconnect: new HELLO with a new session id', h3 and h3['sid'] != sid and h3['b']['paired'])
        if h3:
            d.send(frame('PING', {}, sid, 999, key))
            check('frame from the previous session → ERROR bad_session', d.wait(err_is('bad_session'))[1])
        d.close()

    passed = sum(1 for r in results if r[1])
    print(f'\n{passed}/{len(results)} passed')
    sys.exit(0 if passed == len(results) else 1)


if __name__ == '__main__':
    main()
