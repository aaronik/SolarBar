"""Run the Swift smoke binary against four ephemeral loopback TCP listeners."""
import socketserver
import struct
import subprocess
import sys
import threading
import time
from contextlib import ExitStack


class Listener(socketserver.ThreadingTCPServer):
    daemon_threads = True


class GX(socketserver.StreamRequestHandler):
    def handle(self):
        values = {840: 520, 841: (-9) & 0xFFFF, 842: (-46) & 0xFFFF, 843: 84,
                  808: 20, 850: 400, 817: 385, 826: 240}
        while True:
            try:
                request = self.rfile.read(12)
            except ConnectionResetError:
                return
            if not request:
                return
            seq, protocol, length, unit, function, start, count = struct.unpack('>HHHBBHH', request)
            assert (protocol, length, unit, function) == (0, 6, 100, 4)
            if self.server.mode == 'silent':
                time.sleep(10)
                return
            if any(i not in values for i in range(start, start + count)):
                pdu = b'\x84\x02'  # Exercise fallback to narrower reads.
            else:
                pdu = bytes([4, count * 2]) + b''.join(struct.pack('>H', values[i]) for i in range(start, start + count))
            if self.server.mode == 'malformed':
                seq += 1
            packet = struct.pack('>HHHB', seq, 0, len(pdu) + 1, 100) + pdu
            try:
                self.request.sendall(packet[:5])
                self.request.sendall(packet[5:])
            except (BrokenPipeError, ConnectionResetError):
                return


with ExitStack() as stack:
    ports = []
    for mode in ['valid', 'malformed', 'silent', 'silent']:
        server = stack.enter_context(Listener(('127.0.0.1', 0), GX))
        server.mode = mode
        threading.Thread(target=server.serve_forever, daemon=True, kwargs={'poll_interval': 0.1}).start()
        stack.callback(server.shutdown)
        ports.append(str(server.server_address[1]))
    subprocess.run([sys.argv[1], *ports], check=True, timeout=18)
