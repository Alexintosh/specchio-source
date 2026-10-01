"""Save network pairing for an explicitly selected, already trusted USB iPhone."""
import argparse
import asyncio
import hashlib
import json

from pymobiledevice3.exceptions import RemotePairingCompletedError
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.pair_records import iter_remote_paired_identifiers
from pymobiledevice3.remote.tunnel_service import RemotePairingLockdownService


async def pair(serial):
    device_hash = hashlib.sha256(serial.encode()).hexdigest()[:12]
    print(json.dumps(dict(stage='wifi.pairing.starting', device_hash=device_hash)), flush=True)
    client = await create_using_usbmux(serial=serial, autopair=False, connection_type='USB')
    try:
        service = await RemotePairingLockdownService.create(client)
        try:
            try:
                await asyncio.wait_for(service.connect(autopair=True), 30)
            except RemotePairingCompletedError:
                pass  # Protocol success; no reconnect or repeated pairing.
        finally:
            await service.close()
        matches = [i for i in iter_remote_paired_identifiers()
                   if i.replace('-', '') == serial.replace('-', '')]
        if len(matches) != 1:
            raise RuntimeError('network-pairing-record-not-saved')
        print(json.dumps(dict(stage='wifi.pairing.saved', device_hash=device_hash)), flush=True)
    finally:
        await client.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    args = parser.parse_args()
    asyncio.run(pair(args.serial))
