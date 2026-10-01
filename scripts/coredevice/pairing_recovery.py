"""Verify and repair RemotePairing only through an already trusted, selected USB device."""
import asyncio
import contextlib
import json
import sys

from pymobiledevice3.exceptions import (
    RemotePairingCompletedError, NotTrustedError, NotPairedError,
    PairingError, PasscodeRequiredError, NoDeviceConnectedError,
    DeviceNotFoundError, ConnectionFailedError, ConnectionTerminatedError,
)
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.remote.tunnel_service import RemotePairingLockdownService
from pymobiledevice3.usbmux import list_devices
from pymobiledevice3.pair_records import iter_remote_paired_identifiers


def log(stage, **fields):
    print(json.dumps(dict(stage=stage, **fields)), file=sys.stderr, flush=True)


def matches(left, right):
    return left.replace('-', '') == right.replace('-', '')


async def select_device(serial, status):
    if serial:
        log('wifi.selection', branch='explicit-device')
        return serial
    while True:
        usb = [d for d in await list_devices() if d.is_usb]
        paired = list(iter_remote_paired_identifiers())
        # A single attached phone is an unambiguous user selection. Never repair
        # some other attached phone just because the selected phone is absent.
        if len(usb) == 1:
            log('wifi.selection', branch='unique-usb')
            return usb[0].serial
        if len(paired) == 1:
            log('wifi.selection', branch='unique-saved-pairing')
            return paired[0]
        if len(usb) > 1 or len(paired) > 1:
            log('wifi.selection', branch='ambiguous', usb=len(usb), paired=len(paired))
            raise RuntimeError('select-exactly-one-paired-device')
        log('wifi.selection', branch='waiting-for-usb')
        status('pairing.usb-required')
        await asyncio.sleep(2)


async def close(resource):
    with contextlib.suppress(Exception):
        await asyncio.wait_for(resource.close(), 2)


async def verify(client):
    service = await RemotePairingLockdownService.create(client)
    try:
        await service._attempt_pair_verify()
        # connect(autopair=False) silently returns even when validation is false.
        valid = await service._validate_pairing()
        log('wifi.pairing.validation', valid=valid)
        return valid
    finally:
        await close(service)


async def ensure_pairing(serial, status, allow_repair=True):
    """Return verified/repaired, or None when the user must attach/unlock/trust USB."""
    devices = [d for d in await list_devices() if d.is_usb and matches(d.serial, serial)]
    if len(devices) != 1:
        log('wifi.pairing.recovery', branch='selected-usb-absent')
        status('pairing.usb-required')
        return None
    client = None
    try:
        async with asyncio.timeout(40):
            status('pairing.verifying')
            # No trust dialogs or pairing with an untrusted device are automated.
            client = await create_using_usbmux(serial=devices[0].serial,
                                               autopair=False, connection_type='USB')
            from developer_mode import check
            await check(client, status)
            if await verify(client):
                return 'verified'
            if not allow_repair:
                log('wifi.pairing.recovery', branch='repair-already-attempted')
                raise RuntimeError('network-pairing-repair-failed')
            status('pairing.repairing')
            log('wifi.pairing.recovery', branch='renew-rejected-record')
            service = await RemotePairingLockdownService.create(client)
            try:
                try:
                    await service.connect(autopair=True)
                except RemotePairingCompletedError:
                    log('wifi.pairing.recovery', branch='pair-setup-completed')
            finally:
                await close(service)
            # File existence and connect() success are not proof. Verify anew.
            if not await verify(client):
                raise RuntimeError('network-pairing-repair-failed')
            status('pairing.repaired')
            return 'repaired'
    except asyncio.CancelledError:
        log('wifi.pairing.recovery', branch='cancelled')
        raise
    except Exception as error:
        if str(error) in {'network-pairing-repair-failed', 'developer-mode-disabled'}:
            raise
        if not isinstance(error, (NotTrustedError, NotPairedError, PairingError,
                                  PasscodeRequiredError, NoDeviceConnectedError,
                                  DeviceNotFoundError, ConnectionFailedError,
                                  ConnectionTerminatedError, ConnectionError, TimeoutError)):
            log('wifi.pairing.recovery', branch='unexpected-error', error_type=type(error).__name__)
            raise RuntimeError('network-pairing-repair-failed') from error
        log('wifi.pairing.recovery', branch='usb-unavailable', error_type=type(error).__name__)
        status('pairing.unlock-required')
        return None
    finally:
        if client is not None:
            await close(client)
