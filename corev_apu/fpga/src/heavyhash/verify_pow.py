#!/usr/bin/env python3
"""
verify_pow.py — Full HeavyHash PoW verification in Python.

Computes the complete Kaspa HeavyHash pipeline:
  1. Pre-pow hash (blake2b-256 with "BlockHash" domain)
  2. cSHAKE256("ProofOfWorkHash") → Keccak hash
  3. Matrix generation (xoshiro256++)
  4. Matrix-vector multiply (4-bit entries)
  5. cSHAKE256("HeavyHash") → final PoW hash
  6. Compare against target from bits

Use this to verify the FPGA mining pipeline matches kaspad's computation.
"""

import hashlib
import struct
import sys
import json

# ----------------------------------------------------------------
#  Keccak-f[1600]
# ----------------------------------------------------------------

KECCAK_RC = [
    0x0000000000000001, 0x0000000000008082,
    0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001,
    0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088,
    0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B,
    0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080,
    0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080,
    0x0000000080000001, 0x8000000080008008,
]

KECCAK_ROT = [
     0,  1, 62, 28, 27,  36, 44,  6, 55, 20,
     3, 10, 43, 25, 39,  41, 45, 15, 21,  8,
    18,  2, 61, 56, 14
]

KECCAK_PI = [
     0, 10, 20,  5, 15,  16,  1, 11, 21,  6,
     7, 17,  2, 12, 22,  23,  8, 18,  3, 13,
    14, 24,  9, 19,  4
]

MASK64 = 0xFFFFFFFFFFFFFFFF

def rotl64(x, n):
    return ((x << n) | (x >> (64 - n))) & MASK64

def keccak_f1600(state):
    """In-place Keccak-f[1600] on a list of 25 uint64s."""
    for rnd in range(24):
        # Theta
        C = [state[x] ^ state[x+5] ^ state[x+10] ^ state[x+15] ^ state[x+20]
             for x in range(5)]
        for x in range(5):
            D = C[(x+4) % 5] ^ rotl64(C[(x+1) % 5], 1)
            for y in range(0, 25, 5):
                state[x+y] = (state[x+y] ^ D) & MASK64
        # Rho + Pi
        tmp = [0] * 25
        for i in range(25):
            tmp[KECCAK_PI[i]] = rotl64(state[i], KECCAK_ROT[i])
        # Chi
        for y in range(0, 25, 5):
            for x in range(5):
                state[y+x] = (tmp[y+x] ^ ((~tmp[y+(x+1)%5]) & tmp[y+(x+2)%5])) & MASK64
        # Iota
        state[0] = (state[0] ^ KECCAK_RC[rnd]) & MASK64

# ----------------------------------------------------------------
#  cSHAKE256 mid-state computation (matches kaspa's PowHash)
# ----------------------------------------------------------------

def left_encode(val):
    if val == 0:
        return bytes([1, 0])
    buf = []
    v = val
    while v > 0:
        buf.append(v & 0xFF)
        v >>= 8
    buf.reverse()
    return bytes([len(buf)] + buf)

def encode_string(s):
    s_bytes = s.encode('utf-8') if isinstance(s, str) else s
    return left_encode(len(s_bytes) * 8) + s_bytes

def compute_cshake_initial_state(custom_str):
    """Compute cSHAKE256 initial Keccak state after absorbing the prefix block."""
    prefix = bytearray(136)
    pos = 0
    # bytepad(encode_string("") || encode_string(custom), 136)
    le = left_encode(136)
    prefix[pos:pos+len(le)] = le
    pos += len(le)
    es_n = encode_string("")  # N = ""
    prefix[pos:pos+len(es_n)] = es_n
    pos += len(es_n)
    es_s = encode_string(custom_str)  # S = custom_str
    prefix[pos:pos+len(es_s)] = es_s
    pos += len(es_s)
    # Rest is zero-padded (already zero)

    state = [0] * 25
    for i in range(17):  # 136 / 8 = 17 lanes
        lane = int.from_bytes(prefix[i*8:(i+1)*8], 'little')
        state[i] ^= lane
    keccak_f1600(state)
    return state

def pow_hash(pre_pow_hash_bytes, timestamp, nonce):
    """
    Compute PowHash = cSHAKE256("ProofOfWorkHash", pre_pow_hash || ts_le || zeros(32) || nonce_le).

    Uses mid-state optimization matching kaspa's PowHash implementation:
    - Start with cSHAKE256 initial state (prefix block absorbed)
    - XOR in the 136-byte message block (with padding)
    - Run keccak_f1600
    - Extract 32-byte hash from state[0..3]
    """
    state = compute_cshake_initial_state("ProofOfWorkHash")

    # Build 136-byte message block
    msg = bytearray(136)
    msg[0:32] = pre_pow_hash_bytes
    msg[32:40] = struct.pack('<Q', timestamp)
    # bytes 40-71: zeros (already zero)
    msg[72:80] = struct.pack('<Q', nonce)
    # cSHAKE256 padding
    msg[80] = 0x04
    msg[135] = 0x80

    # XOR message into state
    for i in range(17):
        lane = int.from_bytes(msg[i*8:(i+1)*8], 'little')
        state[i] = (state[i] ^ lane) & MASK64

    keccak_f1600(state)

    # Extract hash: state[0..3] as LE u64s → 32 bytes
    result = b''
    for i in range(4):
        result += struct.pack('<Q', state[i])
    return result

def heavy_hash_second(hash_bytes):
    """Second cSHAKE256("HeavyHash") — just hash the 32-byte input."""
    state = compute_cshake_initial_state("HeavyHash")

    # 136-byte message: hash(32 bytes) + padding
    msg = bytearray(136)
    msg[0:32] = hash_bytes
    msg[32] = 0x04  # cSHAKE256 padding
    msg[135] = 0x80

    for i in range(17):
        lane = int.from_bytes(msg[i*8:(i+1)*8], 'little')
        state[i] = (state[i] ^ lane) & MASK64

    keccak_f1600(state)

    result = b''
    for i in range(4):
        result += struct.pack('<Q', state[i])
    return result

# ----------------------------------------------------------------
#  Matrix generation (xoshiro256++ seeded from pre-pow hash)
# ----------------------------------------------------------------

class Xoshiro256pp:
    def __init__(self, seed_bytes):
        """Seed from 32 bytes (4 x u64 LE)."""
        self.s = list(struct.unpack('<4Q', seed_bytes))

    def next(self):
        s = self.s
        result = (rotl64((s[0] + s[3]) & MASK64, 23) + s[0]) & MASK64
        t = (s[1] << 17) & MASK64
        s[2] = (s[2] ^ s[0]) & MASK64
        s[3] = (s[3] ^ s[1]) & MASK64
        s[1] = (s[1] ^ s[2]) & MASK64
        s[0] = (s[0] ^ s[3]) & MASK64
        s[2] = (s[2] ^ t) & MASK64
        s[3] = rotl64(s[3], 45)
        return result

def generate_matrix(pre_pow_hash_bytes):
    """Generate 64x64 matrix of 4-bit values from pre-pow hash."""
    xs = Xoshiro256pp(pre_pow_hash_bytes)
    matrix = [[0]*64 for _ in range(64)]

    for row in range(64):
        for col in range(0, 64, 16):
            r = xs.next()
            for k in range(16):
                if col + k < 64:
                    matrix[row][col + k] = (r >> (k * 4)) & 0xF
    return matrix

def matrix_vector_multiply(matrix, hash_bytes):
    """
    Multiply 64x64 matrix (4-bit entries) by vector (4-bit entries from hash).
    Input: 32-byte hash → 64 x 4-bit nibbles
    Output: 32-byte result

    Each output nibble = (sum of row[i] * vec[i] for i in 0..63) mod 16
    Result XORed with original hash.
    """
    # Extract 64 nibbles from hash (high nibble first per byte, matching kaspad)
    vec = []
    for b in hash_bytes:
        vec.append((b >> 4) & 0xF)
        vec.append(b & 0xF)

    # Matrix multiply
    result_nibbles = []
    for row in range(64):
        acc = 0
        for col in range(64):
            acc += matrix[row][col] * vec[col]
        # Reduce mod 16 (keep low 4 bits of sum)
        # Actually, kaspa uses >> 10 to reduce: takes bits [10:14] of the accumulator
        # This is equivalent to (acc >> 10) & 0xF
        result_nibbles.append((acc >> 10) & 0xF)

    # Pack nibbles back to bytes (high nibble first per byte, matching kaspad)
    result = bytearray(32)
    for i in range(32):
        result[i] = (result_nibbles[i*2] << 4) | result_nibbles[i*2 + 1]

    # XOR with original hash
    for i in range(32):
        result[i] ^= hash_bytes[i]

    return bytes(result)

# ----------------------------------------------------------------
#  Full HeavyHash PoW computation
# ----------------------------------------------------------------

def compute_heavy_hash(pre_pow_hash_bytes, timestamp, nonce):
    """Full HeavyHash: PowHash → matrix multiply → HeavyHash."""
    # Step 1: PowHash (first cSHAKE256)
    keccak_hash = pow_hash(pre_pow_hash_bytes, timestamp, nonce)

    # Step 2: Matrix generation
    matrix = generate_matrix(pre_pow_hash_bytes)

    # Step 3: Matrix-vector multiply
    product = matrix_vector_multiply(matrix, keccak_hash)

    # Step 4: Second cSHAKE256 (HeavyHash)
    final_hash = heavy_hash_second(product)

    return keccak_hash, product, final_hash

# ----------------------------------------------------------------
#  Pre-pow hash (same as solo_bridge.py)
# ----------------------------------------------------------------

DOMAIN_KEY = b"BlockHash"  # Raw domain separator, used directly as blake2b key

def compute_pre_pow_hash(header):
    """Compute pre-pow hash from RPC header dict."""
    h = hashlib.blake2b(digest_size=32, key=DOMAIN_KEY)

    # version (uint16 LE)
    h.update(struct.pack('<H', header['version'] & 0xFFFF))

    # parents
    parents = header.get('parentsByLevel', header.get('parents', []))
    h.update(struct.pack('<Q', len(parents)))
    for level in parents:
        if isinstance(level, dict):
            hashes = level.get('parentHashes', [])
        else:
            hashes = level
        h.update(struct.pack('<Q', len(hashes)))
        for parent_hash in hashes:
            h.update(bytes.fromhex(parent_hash))

    # merkle roots + utxo
    h.update(bytes.fromhex(header['hashMerkleRoot']))
    h.update(bytes.fromhex(header['acceptedIdMerkleRoot']))
    h.update(bytes.fromhex(header['utxoCommitment']))

    # timestamp = 0 (overridden)
    h.update(struct.pack('<q', 0))

    # bits
    h.update(struct.pack('<I', header['bits']))

    # nonce = 0 (overridden)
    h.update(struct.pack('<Q', 0))

    # daaScore
    daa = header.get('daaScore', 0)
    if isinstance(daa, str): daa = int(daa)
    h.update(struct.pack('<Q', daa))

    # blueScore
    bs = header.get('blueScore', 0)
    if isinstance(bs, str): bs = int(bs)
    h.update(struct.pack('<Q', bs))

    # blueWork — big-endian, strip leading zeros
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
    bw_bytes_be = bw_bytes_be.lstrip(b'\x00')
    h.update(struct.pack('<Q', len(bw_bytes_be)))
    h.update(bw_bytes_be)

    # pruningPoint
    h.update(bytes.fromhex(header['pruningPoint']))

    return h.digest()

def bits_to_target(bits):
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
    value &= (1 << 256) - 1
    return value.to_bytes(32, 'little')

# ----------------------------------------------------------------
#  Verification against live kaspad template
# ----------------------------------------------------------------

def verify_template(header, nonce, verbose=True):
    """
    Given a block header dict and a nonce, verify the full HeavyHash PoW.
    Returns True if the hash is below target.
    """
    if verbose:
        print(f"=== PoW Verification ===")
        print(f"  version:     {header['version']}")
        ts = header['timestamp']
        if isinstance(ts, str): ts = int(ts)
        print(f"  timestamp:   {ts}")
        print(f"  bits:        {header['bits']} (0x{header['bits']:08x})")
        print(f"  nonce:       {nonce} (0x{nonce:016x})")
        daa = header.get('daaScore', 0)
        if isinstance(daa, str): daa = int(daa)
        print(f"  daaScore:    {daa}")
        bs = header.get('blueScore', 0)
        if isinstance(bs, str): bs = int(bs)
        print(f"  blueScore:   {bs}")
        print(f"  blueWork:    {header.get('blueWork', '?')}")

    # Compute pre-pow hash
    pre_pow = compute_pre_pow_hash(header)
    if verbose:
        print(f"\n  pre_pow_hash:  {pre_pow.hex()}")

    # Get timestamp
    ts = header['timestamp']
    if isinstance(ts, str): ts = int(ts)

    # Compute full HeavyHash
    keccak_hash, mat_product, final_hash = compute_heavy_hash(pre_pow, ts, nonce)

    if verbose:
        print(f"  keccak_hash:   {keccak_hash.hex()}")
        print(f"  mat_product:   {mat_product.hex()}")
        print(f"  heavy_hash:    {final_hash.hex()}")

    # Compare with target
    target = bits_to_target(header['bits'])
    if verbose:
        print(f"  target:        {target.hex()}")

    # LE comparison: compare as 256-bit LE integers
    hash_int = int.from_bytes(final_hash, 'little')
    target_int = int.from_bytes(target, 'little')

    meets_target = hash_int <= target_int
    if verbose:
        print(f"\n  hash_int:    {hash_int:#066x}")
        print(f"  target_int:  {target_int:#066x}")
        print(f"  meets target: {'YES' if meets_target else 'NO'}")

    return meets_target

# ----------------------------------------------------------------
#  Interactive mode: connect to bridge and verify live shares
# ----------------------------------------------------------------

def verify_from_kaspad_log():
    """
    Manually verify using values from kaspad debug log.
    Edit these values to match your kaspad log output.
    """
    # From kaspad log: "block has invalid proof-of-work"
    # Fill in from the kaspad debug output
    print("=== Manual Verification Mode ===")
    print("Edit verify_pow.py and fill in header values from kaspad log")
    print("Then run: python3 verify_pow.py manual")

def main():
    if len(sys.argv) > 1 and sys.argv[1] == 'test':
        # Self-test with known values
        print("=== Self-test: cSHAKE256 mid-state ===")
        state = compute_cshake_initial_state("ProofOfWorkHash")
        print(f"  Mid-state[0]: {state[0]:#018x}")
        print(f"  Mid-state[1]: {state[1]:#018x}")
        print(f"  Mid-state[2]: {state[2]:#018x}")
        print(f"  Mid-state[3]: {state[3]:#018x}")
        print(f"  Mid-state[4]: {state[4]:#018x}")

        state2 = compute_cshake_initial_state("HeavyHash")
        print(f"\n  HeavyHash Mid-state[0]: {state2[0]:#018x}")

        # Test with known hash: all 42s
        pre_pow = bytes([42] * 32)
        timestamp = 5435345234
        nonce = 432432432

        print(f"\n=== Test vector from pow_hashers.rs ===")
        print(f"  pre_pow: {pre_pow.hex()}")
        print(f"  timestamp: {timestamp}")
        print(f"  nonce: {nonce}")

        kh = pow_hash(pre_pow, timestamp, nonce)
        print(f"  pow_hash result: {kh.hex()}")

        matrix = generate_matrix(pre_pow)
        print(f"  matrix[0][0..7]: {matrix[0][:8]}")

        product = matrix_vector_multiply(matrix, kh)
        print(f"  mat_product: {product.hex()}")

        fh = heavy_hash_second(product)
        print(f"  heavy_hash: {fh.hex()}")

        # Verify blake2b domain key is used correctly (raw bytes, not hashed)
        print(f"\n=== Blake2b domain key check ===")
        # kaspad's BlockHash hasher uses key=b"BlockHash" directly
        # Test: blake2b-256(key=b"BlockHash", data=version(1) LE u16)
        import hashlib as hl
        h = hl.blake2b(digest_size=32, key=b"BlockHash")
        h.update(struct.pack('<H', 1))
        test_hash = h.hexdigest()
        # If we accidentally hash the key first, we'd get a different result
        h_wrong = hl.blake2b(digest_size=32, key=hl.blake2b(b"BlockHash", digest_size=32).digest())
        h_wrong.update(struct.pack('<H', 1))
        assert test_hash != h_wrong.hexdigest(), "Sanity check failed"
        assert DOMAIN_KEY == b"BlockHash", f"DOMAIN_KEY wrong: {DOMAIN_KEY!r}"
        print(f"  DOMAIN_KEY = {DOMAIN_KEY!r} (correct: raw bytes, not hashed)")
        print(f"  blake2b(key=b'BlockHash', data=version_1) = {test_hash[:16]}...")

    elif len(sys.argv) > 1 and sys.argv[1] == 'live':
        # Live mode: connect to kaspad and verify current template
        import asyncio
        try:
            import websockets
        except ImportError:
            print("pip install websockets")
            sys.exit(1)

        kaspad_url = sys.argv[2] if len(sys.argv) > 2 else "ws://127.0.0.1:18210"
        address = sys.argv[3] if len(sys.argv) > 3 else "kaspatest:qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqkx9awp4e"

        async def run():
            print(f"Connecting to {kaspad_url}...")
            ws = await websockets.connect(kaspad_url, ping_interval=None)

            # Get block template
            req = json.dumps({"id": 1, "method": "getBlockTemplate",
                              "params": {"payAddress": address, "extraData": []}})
            await ws.send(req)
            resp = json.loads(await asyncio.wait_for(ws.recv(), timeout=10))

            if 'error' in resp and resp['error']:
                print(f"Error: {resp['error']}")
                return

            result = resp.get('result', resp.get('params', {}))
            block = result['block']
            header = block['header']

            print(f"\nGot template:")
            print(f"  Header keys: {list(header.keys())}")
            print(f"  parentsByLevel levels: {len(header.get('parentsByLevel', []))}")
            for i, level in enumerate(header.get('parentsByLevel', [])):
                if level:
                    print(f"    level {i}: {len(level)} parents, first={level[0][:16]}...")

            # Verify with nonce=0 (won't meet target, but tests the pipeline)
            print("\n--- Verifying with nonce=0 (should NOT meet target) ---")
            verify_template(header, 0)

            await ws.close()

        asyncio.run(run())

    elif len(sys.argv) > 1 and sys.argv[1] == 'bridge':
        # Read a share from stdin (JSON) and verify
        for line in sys.stdin:
            try:
                data = json.loads(line.strip())
                header = data['header']
                nonce = data['nonce']
                verify_template(header, nonce)
            except (json.JSONDecodeError, KeyError) as e:
                print(f"Parse error: {e}")

    else:
        print("Usage:")
        print("  python3 verify_pow.py test                  — Run self-test with known values")
        print("  python3 verify_pow.py live [kaspad_url] [addr] — Verify live template")
        print("  python3 verify_pow.py bridge                — Read shares from stdin")

if __name__ == '__main__':
    main()
