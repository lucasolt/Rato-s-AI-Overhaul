#!/usr/bin/env python3
"""Console Lua remoto para Jagged Alliance 3, via o debug adapter do SolEngine.

O executavel do jogo serve DAP (Debug Adapter Protocol) em TCP 127.0.0.1:8165 --
a mesma porta que a extensao SolEngineLua.vsix do VS Code usa com
`"request": "attach"`. Este script fala DAP direto, sem VS Code no meio.

Uso:
    python tools/dap_probe.py "expr1" "expr2" ...
    python tools/dap_probe.py -f trecho.lua
    python tools/dap_probe.py --caps            # so o handshake + capabilities
    echo "expr" | python tools/dap_probe.py -

Cada argumento e avaliado como uma expressao Lua no processo vivo. Para rodar varias
linhas, mande um bloco com `do ... end` ou use -f.

Somente stdlib.
"""

import argparse
import json
import socket
import sys

HOST = "127.0.0.1"
PORT = 8165
TIMEOUT = 5.0

# --raw desliga o tidy() da saida
RAW = False


class DapError(Exception):
    pass


class Dap:
    def __init__(self, host=HOST, port=PORT, timeout=TIMEOUT, verbose=False):
        self.seq = 0
        self.verbose = verbose
        self.buf = b""
        self.events = []
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)

    # -- framing ---------------------------------------------------------------
    # Igual ao do LSP: cabecalho Content-Length, corpo JSON utf-8.

    def _send(self, obj):
        body = json.dumps(obj).encode("utf-8")
        head = ("Content-Length: %d\r\n\r\n" % len(body)).encode("ascii")
        if self.verbose:
            print(">> %s" % json.dumps(obj), file=sys.stderr)
        self.sock.sendall(head + body)

    def _read_message(self):
        while True:
            split = self.buf.find(b"\r\n\r\n")
            if split >= 0:
                head = self.buf[:split].decode("ascii", "replace")
                length = None
                for line in head.split("\r\n"):
                    if line.lower().startswith("content-length:"):
                        length = int(line.split(":", 1)[1].strip())
                if length is None:
                    raise DapError("cabecalho sem Content-Length: %r" % head)
                start = split + 4
                if len(self.buf) >= start + length:
                    body = self.buf[start:start + length]
                    self.buf = self.buf[start + length:]
                    msg = json.loads(body.decode("utf-8", "replace"))
                    if self.verbose:
                        print("<< %s" % json.dumps(msg), file=sys.stderr)
                    return msg
            chunk = self.sock.recv(65536)
            if not chunk:
                raise DapError("conexao fechada pelo adapter")
            self.buf += chunk

    # -- requests --------------------------------------------------------------

    def request(self, command, arguments=None, expect_response=True):
        self.seq += 1
        my_seq = self.seq
        msg = {"seq": my_seq, "type": "request", "command": command}
        if arguments is not None:
            msg["arguments"] = arguments
        self._send(msg)
        if not expect_response:
            return None
        # O adapter intercala `event` no meio das respostas -- ler ate casar o
        # request_seq esperado, guardando tudo que chegar pelo caminho.
        while True:
            m = self._read_message()
            if m.get("type") == "event":
                self.events.append(m)
                continue
            if m.get("type") == "response" and m.get("request_seq") == my_seq:
                return m
            self.events.append(m)

    def drain(self, timeout=0.4):
        """Consome eventos pendentes sem bloquear de verdade."""
        old = self.sock.gettimeout()
        self.sock.settimeout(timeout)
        try:
            while True:
                self.events.append(self._read_message())
        except (socket.timeout, DapError, OSError):
            pass
        finally:
            self.sock.settimeout(old)

    def close(self):
        try:
            self.request("disconnect", {"terminateDebuggee": False},
                         expect_response=False)
        except Exception:
            pass
        try:
            self.sock.close()
        except Exception:
            pass


def handshake(dap):
    init = dap.request("initialize", {
        "clientID": "dap_probe",
        "adapterID": "solengine",
        "linesStartAt1": True,
        "columnsStartAt1": True,
        "pathFormat": "path",
        "supportsRunInTerminalRequest": False,
    })
    caps = init.get("body") or {}
    dap.request("attach", {
        "type": "solengine",
        "request": "attach",
        "address": "localhost",
        "debugServer": PORT,
    })
    dap.drain()
    return caps


def tidy(result):
    """Tira o rodape de metatable que o adapter anexa a todo valor.

    O `result` do adapter vem como "<valor> {\\n\\tmetatable = table: 0x... [1]\\n}".
    O bloco e sempre o mesmo e nao diz nada -- em uma sessao de dezenas de expressoes
    ele triplica a saida. Removido so quando e exatamente esse rodape; qualquer outra
    chave dentro das chaves (uma tabela de verdade) e preservada.
    """
    if not isinstance(result, str):
        return result
    idx = result.rfind(" {")
    if idx < 0:
        return result
    tail = result[idx:]
    inner = tail[2:].rstrip()
    if inner.endswith("}"):
        inner = inner[:-1].strip()
    if inner.startswith("metatable =") and "\n" not in inner:
        return result[:idx].rstrip()
    return result


def evaluate(dap, expr, frame_id=None):
    """Avalia uma expressao Lua. Devolve (ok, texto)."""
    args = {"expression": expr, "context": "repl"}
    if frame_id is not None:
        args["frameId"] = frame_id
    r = dap.request("evaluate", args)
    if not r.get("success"):
        msg = r.get("message") or ""
        body = r.get("body") or {}
        if body.get("error"):
            msg = "%s | %s" % (msg, json.dumps(body["error"]))
        return False, msg
    out = (r.get("body") or {}).get("result", "")
    return True, (out if RAW else tidy(out))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("expressions", nargs="*",
                    help="expressoes Lua; '-' le de stdin")
    ap.add_argument("-f", "--file", help="arquivo .lua para avaliar como um bloco")
    ap.add_argument("--caps", action="store_true",
                    help="imprime as capabilities do adapter e sai")
    ap.add_argument("--frame", action="store_true",
                    help="pega um frameId de stackTrace antes de avaliar")
    ap.add_argument("--events", action="store_true",
                    help="imprime os eventos recebidos no fim")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="ecoa todo o trafego DAP em stderr")
    ap.add_argument("--raw", action="store_true",
                    help="nao limpa o rodape de metatable da saida")
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--timeout", type=float, default=TIMEOUT)
    args = ap.parse_args()

    global RAW
    RAW = args.raw

    exprs = []
    if args.file:
        with open(args.file, encoding="utf-8") as fh:
            exprs.append(fh.read())
    for e in args.expressions:
        exprs.append(sys.stdin.read() if e == "-" else e)

    try:
        dap = Dap(port=args.port, timeout=args.timeout, verbose=args.verbose)
    except OSError as exc:
        print("nao conectou em %s:%d -- %s" % (HOST, args.port, exc), file=sys.stderr)
        print("o jogo esta aberto? a porta so existe no JA3Debug.exe / modo dev.",
              file=sys.stderr)
        return 2

    rc = 0
    try:
        caps = handshake(dap)
        if args.caps:
            print(json.dumps(caps, indent=2, sort_keys=True))
            return 0

        frame_id = None
        if args.frame:
            th = dap.request("threads")
            threads = ((th.get("body") or {}).get("threads") or [])
            if threads:
                st = dap.request("stackTrace", {"threadId": threads[0]["id"],
                                                "startFrame": 0, "levels": 1})
                frames = ((st.get("body") or {}).get("stackFrames") or [])
                if frames:
                    frame_id = frames[0].get("id")
            print("-- frameId: %s" % frame_id, file=sys.stderr)

        for expr in exprs:
            ok, out = evaluate(dap, expr, frame_id)
            label = expr if len(expr) <= 70 else expr[:67] + "..."
            label = " ".join(label.split())
            if ok:
                print("%-72s => %s" % (label, out))
            else:
                rc = 1
                print("%-72s !! %s" % (label, out))
    except (DapError, socket.timeout, OSError) as exc:
        print("falha de protocolo: %s" % exc, file=sys.stderr)
        rc = 2
    finally:
        if args.events:
            for ev in dap.events:
                print("-- event: %s" % json.dumps(ev), file=sys.stderr)
        dap.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
