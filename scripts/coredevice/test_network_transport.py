import asyncio
import socket
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import network_transport as network


class NetworkTransportTests(unittest.IsolatedAsyncioTestCase):
    async def test_native_bonjour_resolves_advertised_endpoint(self):
        listing = '15:49:06.128  Add 2 12 local. _remotepairing._tcp. device-instance\n'
        resolved = 'device-instance can be reached at Phone.local.:49152 (interface 12)\n'
        addresses = [(socket.AF_INET, socket.SOCK_STREAM, 6, '', ('192.168.1.2', 49152)),
                     (socket.AF_INET6, socket.SOCK_STREAM, 6, '', ('fe80::1', 49152, 0, 12))]
        with patch.object(network, 'bonjour_output', AsyncMock(side_effect=[listing, resolved])), \
             patch.object(asyncio.get_running_loop(), 'getaddrinfo', AsyncMock(return_value=addresses)), \
             patch.object(socket, 'if_indextoname', return_value='en1'):
            self.assertEqual(await network.native_bonjour_endpoints(),
                             {('192.168.1.2', 49152), ('fe80::1%en1', 49152)})

    async def test_interface_inventory_excludes_usb_and_tunnels(self):
        inventory = ('Hardware Port: Wi-Fi\nDevice: en1\n\n'
                     'Hardware Port: iPhone USB\nDevice: en8\n\n'
                     'Hardware Port: Ethernet\nDevice: en0\n')
        with patch.object(network, 'command_output', AsyncMock(return_value=inventory)):
            self.assertEqual(await network.lan_interfaces(), {'en1', 'en0'})
        for interface, expected in [('en1', True), ('en8', False), ('utun0', False)]:
            with patch.object(network, 'command_output', AsyncMock(return_value=f'interface: {interface}\n')):
                self.assertEqual(await network.route_allowed('192.168.1.2', {'en1', 'en0'}), expected)

    async def test_failed_authentication_closes_endpoint_without_pairing(self):
        service = SimpleNamespace(connect=AsyncMock(side_effect=ConnectionError()), close=AsyncMock())
        answer = SimpleNamespace(addresses=[SimpleNamespace(full_ip='192.168.1.2')], port=1234)
        with patch.object(network, 'iter_remote_paired_identifiers', return_value=['selected']), \
             patch.object(network, 'lan_interfaces', AsyncMock(return_value={'en1'})), \
             patch.object(network, 'browse_remotepairing', AsyncMock(return_value=[answer])), \
             patch.object(network, 'route_allowed', AsyncMock(return_value=True)), \
             patch.object(network, 'RemotePairingTunnelService', return_value=service):
            with self.assertRaisesRegex(RuntimeError, 'not-reachable'):
                await network.wifi_provider_attempt('selected')
        service.connect.assert_awaited_once_with(autopair=False)
        service.close.assert_awaited_once()

    async def test_provider_override_restored_after_cancellation(self):
        original = network.ut._create_no_root_tunnel_provider
        async def cancelled(_):
            self.assertIs(network.ut._create_no_root_tunnel_provider, network.wifi_provider)
            raise asyncio.CancelledError()
        with patch.object(network.ut.UserspaceRsdTunnel, '_aopen_locked', cancelled):
            with self.assertRaises(asyncio.CancelledError):
                await network.WifiTunnel(serial='selected')._aopen_locked()
        self.assertIs(network.ut._create_no_root_tunnel_provider, original)

class DiscoveryErrorTests(unittest.IsolatedAsyncioTestCase):
    async def test_no_bonjour_records_reports_device_not_found(self):
        with patch.object(network, 'iter_remote_paired_identifiers', return_value=['abc']), \
             patch.object(network, 'lan_interfaces', new=AsyncMock(return_value={'en1'})), \
             patch.object(network, 'browse_remotepairing', new=AsyncMock(return_value=[])), \
             patch.object(network, 'native_bonjour_endpoints', new=AsyncMock(return_value=set())):
            with self.assertRaisesRegex(RuntimeError, '^wifi-device-not-found$'):
                await network.wifi_provider_attempt('abc')


class PersistentDiscoveryTests(unittest.IsolatedAsyncioTestCase):
    async def test_retries_absent_device_and_route_until_connection(self):
        expected = (object(), None)
        attempt = AsyncMock(side_effect=[
            RuntimeError('wifi-device-not-found'),
            RuntimeError('wifi-route-unavailable'),
            RuntimeError('selected-device-not-reachable-on-lan'),
            TimeoutError(), expected])
        with patch.object(network, 'wifi_provider_attempt', attempt), \
             patch.object(network.asyncio, 'sleep', AsyncMock()) as delay:
            self.assertIs(await network.wifi_provider('selected'), expected)
        self.assertEqual(attempt.await_count, 5)
        self.assertEqual(delay.await_count, 4)
        for call in attempt.await_args_list:
            self.assertEqual(call.args, ('selected', False, False))

    async def test_unrecoverable_error_is_not_retried(self):
        attempt = AsyncMock(side_effect=RuntimeError('network-pairing-repair-failed'))
        with patch.object(network, 'wifi_provider_attempt', attempt):
            with self.assertRaisesRegex(RuntimeError, 'repair-failed'):
                await network.wifi_provider('selected')
        attempt.assert_awaited_once()

    async def test_cancel_during_retry_wait_stops_search(self):
        waiting = asyncio.Event()
        async def wait(_):
            waiting.set()
            await asyncio.Event().wait()
        attempt = AsyncMock(side_effect=RuntimeError('wifi-device-not-found'))
        with patch.object(network, 'wifi_provider_attempt', attempt), \
             patch.object(network.asyncio, 'sleep', wait):
            task = asyncio.create_task(network.wifi_provider('selected'))
            await waiting.wait()
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
        attempt.assert_awaited_once()

    async def test_cancel_during_endpoint_connection_closes_service(self):
        connecting = asyncio.Event()
        async def connect(**kwargs):
            connecting.set()
            await asyncio.Event().wait()
        service = SimpleNamespace(connect=connect, close=AsyncMock())
        answer = SimpleNamespace(addresses=[SimpleNamespace(full_ip='192.168.1.2')], port=1234)
        with patch.object(network, 'iter_remote_paired_identifiers', return_value=['selected']), \
             patch.object(network, 'lan_interfaces', AsyncMock(return_value={'en1'})), \
             patch.object(network, 'browse_remotepairing', AsyncMock(return_value=[answer])), \
             patch.object(network, 'route_allowed', AsyncMock(return_value=True)), \
             patch.object(network, 'RemotePairingTunnelService', return_value=service):
            task = asyncio.create_task(network.wifi_provider('selected'))
            await connecting.wait()
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
        service.close.assert_awaited_once()


class PairingRecoveryIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def test_repair_then_wifi_connects_without_new_user_attempt(self):
        expected = (object(), None)
        status = []
        with patch.object(network, 'wifi_provider_attempt', AsyncMock(side_effect=[
                RuntimeError('wifi-authentication-failed'), expected])), \
             patch.object(network, 'ensure_pairing', AsyncMock(return_value='repaired')) as repair, \
             patch.object(network.asyncio, 'sleep', AsyncMock()):
            self.assertIs(await network.wifi_provider('selected', status=status.append), expected)
        repair.assert_awaited_once()
        self.assertIn('tunnel.starting', status)

    async def test_wait_for_usb_then_recover_without_repeated_pairing(self):
        expected = (object(), None)
        errors = [RuntimeError('wifi-authentication-failed') for _ in range(3)]
        with patch.object(network, 'wifi_provider_attempt', AsyncMock(side_effect=errors + [expected])), \
             patch.object(network, 'ensure_pairing', AsyncMock(side_effect=[None, 'repaired'])) as repair, \
             patch.object(network.asyncio, 'sleep', AsyncMock()):
            self.assertIs(await network.wifi_provider('selected'), expected)
        self.assertEqual(repair.await_count, 2)

    async def test_cancel_recovery_does_not_retry(self):
        with patch.object(network, 'wifi_provider_attempt', AsyncMock(side_effect=RuntimeError('wifi-authentication-failed'))) as attempt, \
             patch.object(network, 'ensure_pairing', AsyncMock(side_effect=asyncio.CancelledError)):
            with self.assertRaises(asyncio.CancelledError):
                await network.wifi_provider('selected')
        attempt.assert_awaited_once()


if __name__ == '__main__':
    unittest.main()
