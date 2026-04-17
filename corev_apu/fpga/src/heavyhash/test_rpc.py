#!/usr/bin/env python3
"""Test kaspad wRPC message envelope formats."""

import asyncio
import json
import sys

import websockets

KASPAD_URL = sys.argv[1] if len(sys.argv) > 1 else "ws://127.0.0.1:18210"
ADDRESS = sys.argv[2] if len(sys.argv) > 2 else "kaspatest:qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqkx9awp4e"

MSG_ID = 1


async def try_raw(ws, label, raw_msg):
    global MSG_ID
    MSG_ID += 1
    print(f"--- {label} ---")
    print(f">>> {raw_msg}")
    await ws.send(raw_msg)
    try:
        resp = await asyncio.wait_for(ws.recv(), timeout=5.0)
        print(f"<<< {resp[:500]}")
    except asyncio.TimeoutError:
        print("<<< TIMEOUT")
    print()


async def main():
    print(f"Connecting to {KASPAD_URL}")
    print(f"Address: {ADDRESS}")
    print()

    ws = await websockets.connect(KASPAD_URL, ping_interval=None)

    p = ADDRESS

    # Fix: extraData is Vec<u8> — serde expects JSON array, not string
    await try_raw(ws, "getBlockTemplate (extraData=[])",
        json.dumps({"id": 1, "method": "getBlockTemplate",
                     "params": {"payAddress": p, "extraData": []}}))

    # Also try with some extra data bytes
    await try_raw(ws, "getBlockTemplate (extraData=[0])",
        json.dumps({"id": 2, "method": "getBlockTemplate",
                     "params": {"payAddress": p, "extraData": [0]}}))

    # Try getInfo for comparison
    await try_raw(ws, "getInfo",
        json.dumps({"id": 3, "method": "getInfo", "params": {}}))

    await ws.close()
    print("Done")


asyncio.run(main())
