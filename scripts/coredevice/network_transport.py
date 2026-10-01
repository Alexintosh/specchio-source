"""Explicit authenticated LAN transport for the pinned userspace tunnel.

Provider injection follows the lifecycle-lock extension used by
DanielLemky/omarchy-iphone-mirror. No library files are modified.
"""
import asyncio
import contextlib
import ipaddress
import json
import re
import socket
import sys
from functools import partial

from pymobiledevice3.exceptions import ConnectionTerminatedError
from pairing_recovery import ensure_pairing

from pymobiledevice3.remote import userspace_tunnel as ut
from pymobiledevice3.remote.tunnel_service import (
    RemotePairingTunnelService, browse_remotepairing, iter_remote_paired_identifiers,
)


def log(stage, **fields):
    print(json.dumps(dict(stage=stage, **fields)), file=sys.stderr, flush=True)


async def command_output(*args):
    process = await asyncio.create_subprocess_exec(
        *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        output, _ = await asyncio.wait_for(process.communicate(), 5)
    except BaseException:
        with contextlib.suppress(ProcessLookupError):
            process.kill()
        await process.wait()
        raise
    if process.returncode:
        raise RuntimeError('network-route-inspection-failed')
    return output.decode()


async def lan_interfaces():
    ports = await command_output('/usr/sbin/networksetup', '-listallhardwareports')
    accepted = set()
    port = ''
    for line in ports.splitlines():
        if line.startswith('Hardware Port: '):
            port = line.removeprefix('Hardware Port: ')
        elif line.startswith('Device: ') and (port == 'Wi-Fi' or port == 'Ethernet' or port.startswith('Thunderbolt Ethernet')):
            accepted.add(line.removeprefix('Device: '))
    log('wifi.interfaces', accepted=sorted(accepted))
    return accepted


async def route_allowed(address, interfaces):
    version = ipaddress.ip_address(address.split('%', 1)[0]).version
    output = await command_output('/sbin/route', '-n', 'get', '-inet6' if version == 6 else '-inet', address)
    fields = dict(line.strip().split(':', 1) for line in output.splitlines() if ':' in line)
    interface = fields.get('interface', '').strip()
    allowed = interface in interfaces
    log('wifi.route', interface=interface, allowed=allowed)
    return allowed


async def bonjour_output(*arguments):
    """Bound the native continuous DNS-SD command and always reap its process."""
    process = await asyncio.create_subprocess_exec('/usr/bin/dns-sd', *arguments,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
    reader = asyncio.create_task(process.stdout.read())
    try:
        await asyncio.wait_for(asyncio.shield(reader), 4)
    except asyncio.TimeoutError:
        pass
    finally:
        if process.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                process.terminate()
        await process.wait()
        await asyncio.gather(reader, return_exceptions=True)
    return reader.result().decode()


async def native_bonjour_endpoints():
    # macOS mDNSResponder sees records that the pinned raw multicast browser
    # misses. Resolve through the system daemon; never guess device addresses.
    listing = await bonjour_output('-B', '_remotepairing._tcp', 'local.')
    names = set(re.findall(r'Add\s+\d+\s+\d+\s+local\.\s+_remotepairing\._tcp\.\s+(.+)', listing))
    endpoints = set()
    for name in names:
        resolved = await bonjour_output('-L', name.strip(), '_remotepairing._tcp', 'local.')
        for host, port in re.findall(r'can be reached at (.+?):(\d+) \(interface \d+\)', resolved):
            addresses = await asyncio.wait_for(asyncio.get_running_loop().getaddrinfo(
                host, int(port), type=socket.SOCK_STREAM), 5)
            for family, _, _, _, address in addresses:
                ip = address[0]
                if family == socket.AF_INET6 and address[3] and '%' not in ip:
                    ip += '%' + socket.if_indextoname(address[3])
                endpoints.add((ip, int(port)))
    log('wifi.discovery.native', services=len(names), endpoints=len(endpoints))
    return endpoints


async def wifi_provider_attempt(serial, autopair=False, remotepairing_fallback=False):
    identifiers = [i for i in iter_remote_paired_identifiers()
                   if serial and i.replace('-', '') == serial.replace('-', '')]
    if len(identifiers) != 1:
        log('wifi.pairing.rejected', matches=len(identifiers))
        raise RuntimeError('selected-device-network-pairing-missing')
    interfaces = await lan_interfaces()
    answers = await browse_remotepairing(timeout=4)
    endpoints = {(a.full_ip, answer.port) for answer in answers for a in answer.addresses}
    log('wifi.discovery', endpoints=len(endpoints))
    if not endpoints and sys.platform == 'darwin':
        endpoints = await native_bonjour_endpoints()
    if not endpoints:
        raise RuntimeError('wifi-device-not-found')
    allowed_routes = 0
    authentication_rejected = False
    for address, port in sorted(endpoints, key=lambda e: (':' in e[0], e[0], e[1])):
        service = None
        transferred = False
        try:
            if not await route_allowed(address, interfaces):
                continue
            allowed_routes += 1
            service = RemotePairingTunnelService(identifiers[0], address, port)
            await asyncio.wait_for(service.connect(autopair=False), 8)
            log('wifi.authenticated', transport='LAN')
            transferred = True
            return service, None
        except Exception as error:
            authentication_rejected |= isinstance(error, ConnectionTerminatedError)
            log('wifi.endpoint.failed', error_type=type(error).__name__, errno=getattr(error, 'errno', None))
        finally:
            # The authenticated provider is owned by UserspaceRsdTunnel after return.
            if service is not None and not transferred:
                with contextlib.suppress(Exception):
                    await asyncio.wait_for(service.close(), 2)
    if not allowed_routes:
        raise RuntimeError('wifi-route-unavailable')
    if authentication_rejected:
        raise RuntimeError('wifi-authentication-failed')
    raise RuntimeError('selected-device-not-reachable-on-lan')


# Retry only discovery/reachability failures. Pairing/configuration errors must
# still reach the app. No attempt limit: the session supervisor owns cancellation.
RETRYABLE_DISCOVERY_ERRORS = {
    'wifi-authentication-failed',
    'selected-device-network-pairing-missing',
    'wifi-device-not-found',
    'wifi-route-unavailable',
    'selected-device-not-reachable-on-lan',
}
DISCOVERY_RETRY_INTERVAL = 2


async def wifi_provider(serial, autopair=False, remotepairing_fallback=False, status=None):
    status = status or (lambda state: None)
    attempt = 0
    repair_attempted = False
    pairing_verified = False
    while True:
        attempt += 1
        log('wifi.search.attempt', attempt=attempt)
        try:
            result = await wifi_provider_attempt(serial, autopair, remotepairing_fallback)
            log('wifi.search.connected', attempt=attempt)
            return result
        except asyncio.CancelledError:
            log('wifi.search.cancelled', attempt=attempt)
            raise
        except Exception as error:
            code = str(error)
            if code in {'wifi-authentication-failed', 'selected-device-network-pairing-missing'}:
                if not pairing_verified:
                    outcome = await ensure_pairing(serial, status, allow_repair=not repair_attempted)
                    log('wifi.search.recovery', outcome=outcome or 'waiting-for-user')
                    if outcome is not None:
                        pairing_verified = True
                        repair_attempted = outcome == 'repaired'
                        status('tunnel.starting')
                else:
                    log('wifi.search.recovery', outcome='already-verified-no-repeat-pairing')
                    status('wifi.authentication-unavailable')
            else:
                status('wifi.searching')
            retryable = (str(error) in RETRYABLE_DISCOVERY_ERRORS
                         or isinstance(error, (TimeoutError, ConnectionError, socket.gaierror)))
            if not retryable:
                log('wifi.search.failed', attempt=attempt, error_type=type(error).__name__)
                raise
            log('wifi.search.retry', attempt=attempt, error_type=type(error).__name__,
                delay=DISCOVERY_RETRY_INTERVAL)
        try:
            await asyncio.sleep(DISCOVERY_RETRY_INTERVAL)
        except asyncio.CancelledError:
            log('wifi.search.cancelled', attempt=attempt, phase='retry-wait')
            raise


class WifiTunnel(ut.UserspaceRsdTunnel):
    def __init__(self, *args, status=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.status = status

    async def _aopen_locked(self):
        original = ut._create_no_root_tunnel_provider
        ut._create_no_root_tunnel_provider = (partial(wifi_provider, status=self.status)
                                                   if self.status is not None else wifi_provider)
        try:
            return await super()._aopen_locked()
        finally:
            ut._create_no_root_tunnel_provider = original
