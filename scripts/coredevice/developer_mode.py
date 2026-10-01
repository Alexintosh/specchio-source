"""Read the actual device setting; unavailable is never treated as disabled."""
import asyncio
import json
import sys
from pymobiledevice3.exceptions import DeveloperModeIsNotEnabledError
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.usbmux import list_devices


def log(stage, **fields):
    print(json.dumps(dict(stage=stage, **fields)), file=sys.stderr, flush=True)


async def check(client, status):
    status('developer-mode.checking')
    try:
        async with asyncio.timeout(8):
            value = await client.get_value(domain='com.apple.security.mac.amfi',
                                           key='DeveloperModeStatus')
    except DeveloperModeIsNotEnabledError:
        log('developer-mode.check', result='disabled-explicit-error')
        raise RuntimeError('developer-mode-disabled')
    except Exception as error:
        log('developer-mode.check', result='unknown', error_type=type(error).__name__)
        return None
    if type(value) is not bool:
        log('developer-mode.check', result='unknown-value')
        return None
    log('developer-mode.check', result='enabled' if value else 'disabled')
    if not value:
        raise RuntimeError('developer-mode-disabled')
    status('developer-mode.enabled')
    return True


async def check_usb(serial, status):
    client = None
    try:
        async with asyncio.timeout(12):
            devices = [d for d in await list_devices()
                       if d.is_usb and d.serial.replace('-', '') == serial.replace('-', '')]
            if len(devices) != 1:
                log('developer-mode.usb', result='selected-device-absent')
                return None
            client = await create_using_usbmux(serial=devices[0].serial, autopair=False, connection_type='USB')
            return await check(client, status)
    except RuntimeError as error:
        if str(error) == 'developer-mode-disabled':
            raise
        log('developer-mode.usb', result='unknown', error_type=type(error).__name__)
        return None
    except Exception as error:
        log('developer-mode.usb', result='unknown', error_type=type(error).__name__)
        return None
    finally:
        if client is not None:
            try:
                await asyncio.wait_for(client.close(), 2)
            except Exception:
                log('developer-mode.usb', result='close-failed')


async def require_before_stream(rsd, usb_verified, status):
    if usb_verified is True:
        log('developer-mode.preflight', result='verified-over-usb')
        return
    if await check(rsd, status) is not True:
        raise RuntimeError('developer-mode-status-unavailable')
