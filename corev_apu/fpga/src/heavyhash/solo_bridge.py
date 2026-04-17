#!/usr/bin/env python3
"""
solo_bridge.py — Kaspa solo mining bridge for HeavyHash FPGA miner

Connects to kaspad (testnet) via wRPC JSON WebSocket, serves stratum
protocol to the FPGA miner. Translates GetBlockTemplate / SubmitBlock.

Prerequisites:
    pip install websockets

Start kaspad with JSON wRPC enabled:
    kaspad --testnet --utxoindex --rpclisten-json 0.0.0.0:18210

Run the bridge:
    python3 solo_bridge.py --kaspad ws://127.0.0.1:18210 \\
        --address kaspatest:qr... --listen 0.0.0.0:5555

On the FPGA board:
    kaspa_miner <bridge_host> 5555 kaspatest:qr...
"""

import asyncio
import argparse
import hashlib
import json
import struct
import signal
import time
import sys
import os
from typing import Optional

# Import local HeavyHash verification
# Ensure verify_pow.py is found regardless of CWD
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    from verify_pow import (compute_heavy_hash, compute_cshake_initial_state,
                            bits_to_target as vfy_bits_to_target)
    HAS_VERIFY = True
    print("verify_pow loaded OK")
except ImportError as e:
    print(f"verify_pow not available: {e}")
    HAS_VERIFY = False

try:
    import websockets
except ImportError:
    print("Install websockets: pip install websockets", file=sys.stderr)
    sys.exit(1)


# ----------------------------------------------------------------
#  Pre-pow hash computation
# ----------------------------------------------------------------

DOMAIN_KEY = b"BlockHash"  # Raw domain separator, used directly as blake2b key


def compute_pre_pow_hash(header: dict) -> bytes:
    """
    Compute the pre-pow hash from an RPC block header.

    This is hash_override_nonce_time(header, nonce=0, timestamp=0):
    all header fields are hashed INCLUDING nonce and timestamp, but
    both are set to zero.

    Field order follows rusty-kaspa consensus/core/src/hashing/header.rs.
    """
    h = hashlib.blake2b(digest_size=32, key=DOMAIN_KEY)

    # version (uint16 LE)
    h.update(struct.pack('<H', header['version'] & 0xFFFF))

    # parents: expanded form — write total expanded level count, then
    # for each expanded level write the parent hashes.
    # RPC parentsByLevel is already in expanded form (list of list of hashes).
    parents = header.get('parentsByLevel', header.get('parents', []))
    # write_len(expanded_len) — total number of levels
    h.update(struct.pack('<Q', len(parents)))
    for level in parents:
        if isinstance(level, dict):
            hashes = level.get('parentHashes', [])
        else:
            hashes = level
        # write_var_array: length then each hash
        h.update(struct.pack('<Q', len(hashes)))
        for parent_hash in hashes:
            h.update(bytes.fromhex(parent_hash))

    # hashMerkleRoot, acceptedIdMerkleRoot, utxoCommitment (32 bytes each)
    h.update(bytes.fromhex(header['hashMerkleRoot']))
    h.update(bytes.fromhex(header['acceptedIdMerkleRoot']))
    h.update(bytes.fromhex(header['utxoCommitment']))

    # timestamp = 0 (not actual timestamp!)
    h.update(struct.pack('<q', 0))

    # bits (uint32 LE)
    h.update(struct.pack('<I', header['bits']))

    # nonce = 0 (not skipped — hashed as zero)
    h.update(struct.pack('<Q', 0))

    # daaScore (uint64 LE)
    daa = header.get('daaScore', 0)
    if isinstance(daa, str):
        daa = int(daa)
    h.update(struct.pack('<Q', daa))

    # blueScore (uint64 LE)
    bs = header.get('blueScore', 0)
    if isinstance(bs, str):
        bs = int(bs)
    h.update(struct.pack('<Q', bs))

    # blueWork — write_blue_work: big-endian, strip leading zeros, length-prefixed
    bw_hex = header.get('blueWork', '0')
    if isinstance(bw_hex, str):
        if bw_hex.startswith('0x') or bw_hex.startswith('0X'):
            bw_hex = bw_hex[2:]
        if len(bw_hex) % 2:
            bw_hex = '0' + bw_hex
        bw_bytes_be = bytes.fromhex(bw_hex) if bw_hex else b''
    else:
        bw_int = int(bw_hex)
        if bw_int == 0:
            bw_bytes_be = b''
        else:
            byte_len = (bw_int.bit_length() + 7) // 8
            bw_bytes_be = bw_int.to_bytes(byte_len, 'big')
    # Strip leading zero bytes (like Rust's position(|b| b != 0))
    bw_bytes_be = bw_bytes_be.lstrip(b'\x00')
    # write_var_bytes: u64 LE length + bytes
    h.update(struct.pack('<Q', len(bw_bytes_be)))
    h.update(bw_bytes_be)

    # pruningPoint (32 bytes)
    h.update(bytes.fromhex(header['pruningPoint']))

    return h.digest()


def bits_to_target(bits: int) -> bytes:
    """Convert compact target bits to 256-bit target (32 bytes LE)."""
    exponent = (bits >> 24) & 0xFF
    mantissa = bits & 0x7FFFFF
    if bits & 0x800000:
        mantissa = -mantissa
    if exponent <= 3:
        value = mantissa >> (8 * (3 - exponent))
    else:
        value = mantissa << (8 * (exponent - 3))
    if value < 0:
        value = 0
    # Clamp to 256 bits
    value &= (1 << 256) - 1
    return value.to_bytes(32, 'little')


def target_to_difficulty(target_bytes: bytes) -> float:
    """Convert 256-bit target to pool-style difficulty."""
    t = int.from_bytes(target_bytes, 'little')
    if t == 0:
        return float('inf')
    return (1 << 255) / t


# ----------------------------------------------------------------
#  Kaspad wRPC client
# ----------------------------------------------------------------

class KaspadClient:
    def __init__(self, url: str):
        self.url = url
        self.ws = None
        self.next_id = 1
        self.pending = {}       # id -> Future
        self.notifications = asyncio.Queue()
        self._recv_task = None

    async def connect(self):
        self.ws = await websockets.connect(
            self.url, ping_interval=20, ping_timeout=60,
            close_timeout=5, max_size=2**22
        )
        self._recv_task = asyncio.create_task(self._recv_loop())

    async def close(self):
        if self._recv_task:
            self._recv_task.cancel()
        if self.ws:
            await self.ws.close()

    @property
    def connected(self):
        if self.ws is None:
            return False
        try:
            return self.ws.state.name == 'OPEN'
        except AttributeError:
            # Fallback: try the connection
            return True

    async def reconnect(self):
        print("Reconnecting to kaspad...")
        try:
            await self.close()
        except Exception:
            pass
        await asyncio.sleep(1)
        await self.connect()
        print("Reconnected")

    async def _recv_loop(self):
        try:
            async for raw in self.ws:
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                msg_id = msg.get('id')
                if msg_id is not None and msg_id in self.pending:
                    self.pending[msg_id].set_result(msg)
                else:
                    # Notification from kaspad
                    await self.notifications.put(msg)
        except websockets.ConnectionClosed as e:
            print(f"kaspad connection closed: {e}")
        except asyncio.CancelledError:
            pass
        # Wake any pending calls so they don't hang
        for msg_id, fut in list(self.pending.items()):
            if not fut.done():
                fut.set_exception(ConnectionError("kaspad disconnected"))

    async def call(self, method: str, params: dict = None) -> dict:
        if not self.connected:
            await self.reconnect()

        msg_id = self.next_id
        self.next_id += 1
        msg = {'id': msg_id, 'method': method}
        if params:
            msg['params'] = params

        loop = asyncio.get_running_loop()
        future = loop.create_future()
        self.pending[msg_id] = future

        await self.ws.send(json.dumps(msg))

        try:
            resp = await asyncio.wait_for(future, timeout=10.0)
        finally:
            self.pending.pop(msg_id, None)

        if 'error' in resp and resp['error']:
            raise RuntimeError(f"kaspad RPC error: {resp['error']}")

        return resp.get('result', resp.get('params', {}))

    async def get_block_template(self, pay_address: str) -> dict:
        return await self.call('getBlockTemplate', {
            'payAddress': pay_address,
            'extraData': []
        })

    async def submit_block(self, block: dict) -> dict:
        return await self.call('submitBlock', {
            'block': block,
            'allowNonDAABlocks': False
        })

    async def subscribe_new_block_template(self):
        return await self.call('notifyNewBlockTemplateRequest', {})


# ----------------------------------------------------------------
#  Stratum server (serves one FPGA miner)
# ----------------------------------------------------------------

class StratumSession:
    def __init__(self, reader, writer, bridge):
        self.reader = reader
        self.writer = writer
        self.bridge = bridge
        self.addr = writer.get_extra_info('peername')

    async def run(self):
        print(f"Miner connected from {self.addr}")
        self.bridge.miner = self
        try:
            while True:
                line = await self.reader.readline()
                if not line:
                    break
                await self.handle_message(line.decode().strip())
        except (asyncio.CancelledError, ConnectionError):
            pass
        finally:
            print(f"Miner disconnected: {self.addr}")
            if self.bridge.miner is self:
                self.bridge.miner = None
            self.writer.close()

    async def handle_message(self, line: str):
        if not line:
            return
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            return

        method = msg.get('method', '')
        msg_id = msg.get('id')

        if method == 'mining.subscribe':
            await self.send_json({
                'id': msg_id,
                'result': [True, 'kaspa-solo/0.1'],
                'error': None
            })
            # Send current difficulty
            if self.bridge.current_difficulty > 0:
                await self.send_notify_difficulty()
            # Send current job if available
            if self.bridge.current_job:
                await self.send_notify_job()

        elif method == 'mining.submit':
            params = msg.get('params', [])
            if len(params) >= 3:
                job_id = params[1]
                nonce_hex = params[2]
                await self.bridge.handle_share(nonce_hex, msg_id, self, job_id=job_id)
            else:
                await self.send_json({
                    'id': msg_id,
                    'result': None,
                    'error': [20, 'Bad params', None]
                })

    async def send_json(self, obj: dict):
        line = json.dumps(obj) + '\n'
        self.writer.write(line.encode())
        await self.writer.drain()

    async def send_notify_difficulty(self):
        await self.send_json({
            'id': None,
            'method': 'mining.set_difficulty',
            'params': [self.bridge.current_difficulty]
        })

    async def send_notify_job(self):
        job = self.bridge.current_job
        if not job:
            return
        # params: [job_id, headerHash_hex]
        # headerHash = prepow_hash(32) + timestamp(8) = 40 bytes
        header_hash = job['prepow_hash'].hex() + job['timestamp_bytes'].hex()
        await self.send_json({
            'id': None,
            'method': 'mining.notify',
            'params': [job['id'], header_hash]
        })


# ----------------------------------------------------------------
#  Solo mining bridge
# ----------------------------------------------------------------

class SoloBridge:
    def __init__(self, kaspad_url: str, pay_address: str, listen_port: int):
        self.kaspad_url = kaspad_url
        self.pay_address = pay_address
        self.listen_port = listen_port
        self.kaspad: Optional[KaspadClient] = None
        self.miner: Optional[StratumSession] = None
        self.current_job = None
        self.current_block = None     # full block template for submission
        self.job_blocks = {}          # job_id -> block template (keep last N)
        self.current_difficulty = 1.0
        self.job_counter = 0
        self.blocks_found = 0
        self.shares_received = 0
        self.running = True

    async def start(self):
        # Connect to kaspad
        print(f"Connecting to kaspad at {self.kaspad_url} ...")
        self.kaspad = KaspadClient(self.kaspad_url)
        await self.kaspad.connect()
        print("Connected to kaspad")

        # Subscribe to new block template notifications
        try:
            await self.kaspad.subscribe_new_block_template()
            print("Subscribed to new block template notifications")
        except Exception as e:
            print(f"Warning: could not subscribe to notifications: {e}")
            print("Will poll for new templates instead")

        # Start stratum server
        server = await asyncio.start_server(
            self._on_miner_connect,
            '0.0.0.0', self.listen_port
        )
        print(f"Stratum server listening on port {self.listen_port}")

        # Run main loop
        await asyncio.gather(
            self._template_loop(),
            self._notification_loop(),
            server.serve_forever()
        )

    async def _on_miner_connect(self, reader, writer):
        session = StratumSession(reader, writer, self)
        await session.run()

    async def _template_loop(self):
        """Poll for new block templates."""
        while self.running:
            try:
                if not self.kaspad.connected:
                    await self.kaspad.reconnect()
                await self._fetch_template()
            except ConnectionError:
                print("Lost connection to kaspad, will retry...")
                await asyncio.sleep(3.0)
                continue
            except Exception as e:
                print(f"Template fetch error: {e}")
            await asyncio.sleep(1.0)

    async def _notification_loop(self):
        """Handle notifications from kaspad."""
        while self.running:
            try:
                msg = await asyncio.wait_for(
                    self.kaspad.notifications.get(), timeout=5.0
                )
                method = msg.get('method', '')
                if 'blockTemplate' in method.lower() or 'NewBlockTemplate' in method:
                    await self._fetch_template()
            except asyncio.TimeoutError:
                continue
            except Exception as e:
                print(f"Notification error: {e}")

    async def _fetch_template(self):
        result = await self.kaspad.get_block_template(self.pay_address)

        block = result.get('block')
        if not block:
            return

        # Log first template for debugging
        if self.job_counter == 0:
            print(f"First template header keys: {list(block['header'].keys())}")
            h = block['header']
            print(f"  nonce={h.get('nonce')!r} timestamp={h.get('timestamp')!r} "
                  f"bits={h.get('bits')!r} daaScore={h.get('daaScore')!r}")
            print(f"  parents structure: {json.dumps(block['header'].get('parents', block['header'].get('parentsByLevel', '???')))[:200]}")

        is_synced = result.get('isSynced', False)
        if not is_synced:
            print("Warning: kaspad not synced (use --enable-unsynced-mining)")
            # Continue anyway — useful for devnet/testing

        header = block['header']

        # Compute pre-pow hash
        prepow_hash = compute_pre_pow_hash(header)

        # Check if this is new work
        if (self.current_job and
                self.current_job['prepow_hash'] == prepow_hash):
            return  # same template, no update needed

        # Extract target from bits
        bits = header['bits']
        target_bytes = bits_to_target(bits)
        self.current_difficulty = target_to_difficulty(target_bytes)

        # Extract timestamp as 8 bytes LE
        ts = header['timestamp']
        if isinstance(ts, str):
            ts = int(ts)
        timestamp_bytes = struct.pack('<q', ts)

        # Store block template for later submission
        self.current_block = block

        # Create job
        self.job_counter += 1
        job_id = str(self.job_counter)
        self.current_job = {
            'id': job_id,
            'prepow_hash': prepow_hash,
            'timestamp_bytes': timestamp_bytes,
            'target': target_bytes,
            'bits': bits,
        }

        # Store block template indexed by job ID
        self.job_blocks[job_id] = block
        # Keep only last 10 templates to avoid memory leak
        if len(self.job_blocks) > 10:
            oldest = min(self.job_blocks.keys(), key=int)
            del self.job_blocks[oldest]

        print(f"New job #{self.job_counter}: "
              f"prepow={prepow_hash[:8].hex()}... "
              f"diff={self.current_difficulty:.2f} "
              f"daa={header.get('daaScore', '?')}")

        # Notify miner
        if self.miner:
            await self.miner.send_notify_difficulty()
            await self.miner.send_notify_job()

    async def handle_share(self, nonce_hex: str, msg_id: int,
                           session: StratumSession, job_id: str = None):
        """Handle a share submission from the miner."""
        self.shares_received += 1

        # Look up the EXACT block template the miner was working on
        block_template = None
        if job_id and job_id in self.job_blocks:
            block_template = self.job_blocks[job_id]
            print(f"  Using stored template for job #{job_id}")
        elif self.current_block:
            block_template = self.current_block
            print(f"  WARNING: job #{job_id} not found, using current template "
                  f"(job #{self.current_job['id'] if self.current_job else '?'})")
        else:
            await session.send_json({
                'id': msg_id, 'result': None,
                'error': [25, 'No current job', None]
            })
            return

        # Parse nonce (big-endian hex from miner -> uint64)
        try:
            nonce_bytes = bytes.fromhex(nonce_hex)
            nonce = int.from_bytes(nonce_bytes, 'big')
        except (ValueError, OverflowError):
            await session.send_json({
                'id': msg_id, 'result': None,
                'error': [20, 'Bad nonce format', None]
            })
            return

        print(f"Share received: nonce=0x{nonce:016x} (decimal: {nonce})")

        # Local PoW verification BEFORE submitting
        header = block_template['header']
        pre_pow = compute_pre_pow_hash(header)
        ts = header['timestamp']
        if isinstance(ts, str): ts = int(ts)

        if HAS_VERIFY:
            keccak_hash, mat_product, final_hash = compute_heavy_hash(pre_pow, ts, nonce)
            target = vfy_bits_to_target(header['bits'])
            hash_int = int.from_bytes(final_hash, 'little')
            target_int = int.from_bytes(target, 'little')
            valid_pow = hash_int <= target_int
            print(f"  LOCAL VERIFY: pre_pow={pre_pow[:8].hex()}... "
                  f"keccak={keccak_hash[:8].hex()}... "
                  f"heavy={final_hash[:8].hex()}...")
            print(f"  LOCAL VERIFY: hash_int={hash_int:#066x}")
            print(f"  LOCAL VERIFY: target  ={target_int:#066x}")
            print(f"  LOCAL VERIFY: {'VALID' if valid_pow else 'INVALID'} PoW")
            if not valid_pow:
                print(f"  !!! Python says PoW is INVALID — nonce does NOT satisfy target")
                print(f"  !!! This means FPGA is computing different HeavyHash than kaspad")
        else:
            print(f"  pre_pow={pre_pow[:8].hex()}... ts={ts} (verify_pow not available)")

        # Set the nonce in the CORRECT block template and submit
        block = json.loads(json.dumps(block_template))  # deep copy
        orig_nonce = block['header'].get('nonce')
        print(f"  Template nonce was: {orig_nonce!r} (type={type(orig_nonce).__name__})")
        block['header']['nonce'] = nonce
        print(f"  Setting nonce to:   {nonce!r} (type={type(nonce).__name__})")
        print(f"  Template daa={block['header'].get('daaScore', '?')} "
              f"(current daa={self.current_block['header'].get('daaScore', '?') if self.current_block else '?'})")

        try:
            result = await self.kaspad.submit_block(block)
            report = result.get('report', result)
            print(f"Block submitted! kaspad response: {report}")
            self.blocks_found += 1
            await session.send_json({
                'id': msg_id, 'result': True, 'error': None
            })
        except Exception as e:
            err_msg = str(e)
            print(f"Block rejected: {err_msg}")
            await session.send_json({
                'id': msg_id, 'result': None,
                'error': [23, err_msg, None]
            })

        # Fetch new template after submission
        await self._fetch_template()


# ----------------------------------------------------------------
#  Main
# ----------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description='Kaspa solo mining bridge for FPGA miner')
    parser.add_argument('--kaspad', default='ws://127.0.0.1:18210',
                        help='kaspad wRPC JSON URL (default: ws://127.0.0.1:18210)')
    parser.add_argument('--address', required=True,
                        help='Kaspa pay address (kaspatest:q... for testnet)')
    parser.add_argument('--listen', type=int, default=5555,
                        help='Stratum listen port (default: 5555)')
    args = parser.parse_args()

    bridge = SoloBridge(args.kaspad, args.address, args.listen)

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    def shutdown(sig, frame):
        bridge.running = False
        print(f"\nShutting down. Blocks found: {bridge.blocks_found}")
        loop.stop()

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    print("Kaspa Solo Mining Bridge")
    print(f"  kaspad:  {args.kaspad}")
    print(f"  address: {args.address}")
    print(f"  listen:  :{args.listen}")
    print()

    try:
        loop.run_until_complete(bridge.start())
    except KeyboardInterrupt:
        pass
    finally:
        loop.close()


if __name__ == '__main__':
    main()
