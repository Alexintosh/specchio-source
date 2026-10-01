import asyncio
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch
import developer_mode as mode
from session import failure_code
from pymobiledevice3.exceptions import DeveloperModeIsNotEnabledError


class DeveloperModeTests(unittest.IsolatedAsyncioTestCase):
    async def test_enabled(self):
        client = SimpleNamespace(get_value=AsyncMock(return_value=True))
        self.assertTrue(await mode.check(client, Mock()))
        client.get_value.assert_awaited_once_with(
            domain='com.apple.security.mac.amfi', key='DeveloperModeStatus')

    async def test_disabled_stops_preflight(self):
        client = SimpleNamespace(get_value=AsyncMock(return_value=False))
        with self.assertRaisesRegex(RuntimeError, '^developer-mode-disabled$'):
            await mode.require_before_stream(client, None, Mock())

    async def test_missing_or_malformed_value_is_unknown_not_disabled(self):
        for value in [None, '', 'false', {}, 0, 1]:
            with self.subTest(value=value):
                client = SimpleNamespace(get_value=AsyncMock(return_value=value))
                with self.assertRaisesRegex(RuntimeError, 'status-unavailable'):
                    await mode.require_before_stream(client, None, Mock())

    async def test_explicit_device_error_is_disabled(self):
        client = SimpleNamespace(get_value=AsyncMock(side_effect=DeveloperModeIsNotEnabledError()))
        with self.assertRaisesRegex(RuntimeError, 'developer-mode-disabled'):
            await mode.check(client, Mock())

    async def test_read_failure_is_unknown_not_disabled(self):
        client = SimpleNamespace(get_value=AsyncMock(side_effect=ConnectionError))
        self.assertIsNone(await mode.check(client, Mock()))

    async def test_usb_verified_does_not_require_remote_lockdown(self):
        client = SimpleNamespace(get_value=AsyncMock(side_effect=RuntimeError))
        await mode.require_before_stream(client, True, Mock())
        client.get_value.assert_not_awaited()

    async def test_cancellation_is_propagated(self):
        client = SimpleNamespace(get_value=AsyncMock(side_effect=asyncio.CancelledError))
        with self.assertRaises(asyncio.CancelledError):
            await mode.check(client, Mock())

    async def test_usb_disabled_closes_client_and_propagates(self):
        client = SimpleNamespace(get_value=AsyncMock(return_value=False), close=AsyncMock())
        device = SimpleNamespace(serial='selected', is_usb=True)
        with patch.object(mode, 'list_devices', AsyncMock(return_value=[device])), \
             patch.object(mode, 'create_using_usbmux', AsyncMock(return_value=client)):
            with self.assertRaisesRegex(RuntimeError, 'developer-mode-disabled'):
                await mode.check_usb('selected', Mock())
        client.close.assert_awaited_once()

    def test_library_and_explicit_errors_reach_ui(self):
        self.assertEqual(failure_code(DeveloperModeIsNotEnabledError()), 'developer-mode-disabled')
        self.assertEqual(failure_code(RuntimeError('developer-mode-disabled')), 'developer-mode-disabled')
        self.assertEqual(failure_code(RuntimeError('developer-mode-status-unavailable')), 'developer-mode-status-unavailable')


if __name__ == '__main__':
    unittest.main()
