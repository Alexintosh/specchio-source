import asyncio
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch
import pairing_recovery as recovery
from pymobiledevice3.exceptions import RemotePairingCompletedError


def device(serial='selected'):
    return SimpleNamespace(serial=serial, is_usb=True)


class RecoveryTests(unittest.IsolatedAsyncioTestCase):
    async def exercise(self, validations, pair_error=None, allow_repair=True):
        client = SimpleNamespace(close=AsyncMock())
        services = []
        for valid in validations:
            services.append(SimpleNamespace(_attempt_pair_verify=AsyncMock(),
                _validate_pairing=AsyncMock(return_value=valid), close=AsyncMock()))
        pair = SimpleNamespace(connect=AsyncMock(side_effect=pair_error), close=AsyncMock())
        sequence = [services[0]]
        if not validations[0] and allow_repair:
            sequence += [pair, services[1]]
        status = Mock()
        with patch.object(recovery, 'list_devices', AsyncMock(return_value=[device()])),              patch.object(recovery, 'create_using_usbmux', AsyncMock(return_value=client)) as create,              patch.object(recovery.RemotePairingLockdownService, 'create', AsyncMock(side_effect=sequence)):
            try:
                result = await recovery.ensure_pairing('selected', status, allow_repair)
                return result, pair, status
            finally:
                client.close.assert_awaited_once()
                for service in sequence:
                    service.close.assert_awaited_once()
                create.assert_awaited_once_with(serial='selected', autopair=False, connection_type='USB')

    async def test_valid_pairing_never_rewritten(self):
        result, pair, _ = await self.exercise([True])
        self.assertEqual(result, 'verified')
        pair.connect.assert_not_awaited()

    async def test_rejected_pairing_is_renewed_and_verified_on_fresh_channel(self):
        result, pair, status = await self.exercise([False, True], RemotePairingCompletedError())
        self.assertEqual(result, 'repaired')
        pair.connect.assert_awaited_once_with(autopair=True)
        status.assert_any_call('pairing.repaired')

    async def test_silent_connect_success_is_not_accepted_without_validation(self):
        with self.assertRaisesRegex(RuntimeError, 'network-pairing-repair-failed'):
            await self.exercise([False, False])

    async def test_other_usb_phone_is_not_paired(self):
        with patch.object(recovery, 'list_devices', AsyncMock(return_value=[device('other')])),              patch.object(recovery, 'create_using_usbmux', AsyncMock()) as create:
            self.assertIsNone(await recovery.ensure_pairing('selected', Mock()))
        create.assert_not_awaited()

    async def test_locked_or_untrusted_phone_waits_without_autopair(self):
        status = Mock()
        with patch.object(recovery, 'list_devices', AsyncMock(return_value=[device()])),              patch.object(recovery, 'create_using_usbmux', AsyncMock(side_effect=ConnectionError())):
            self.assertIsNone(await recovery.ensure_pairing('selected', status))
        status.assert_any_call('pairing.unlock-required')

    async def test_unexpected_error_does_not_loop_as_locked_phone(self):
        with patch.object(recovery, 'list_devices', AsyncMock(return_value=[device()])), \
             patch.object(recovery, 'create_using_usbmux', AsyncMock(side_effect=ValueError())):
            with self.assertRaisesRegex(RuntimeError, 'network-pairing-repair-failed'):
                await recovery.ensure_pairing('selected', Mock())

    async def test_cancellation_during_repair_closes_all_resources(self):
        with self.assertRaises(asyncio.CancelledError):
            # No post-repair verification should occur after cancellation.
            client = SimpleNamespace(close=AsyncMock())
            verify = SimpleNamespace(_attempt_pair_verify=AsyncMock(),
                _validate_pairing=AsyncMock(return_value=False), close=AsyncMock())
            pair = SimpleNamespace(connect=AsyncMock(side_effect=asyncio.CancelledError), close=AsyncMock())
            with patch.object(recovery, 'list_devices', AsyncMock(return_value=[device()])),                  patch.object(recovery, 'create_using_usbmux', AsyncMock(return_value=client)),                  patch.object(recovery.RemotePairingLockdownService, 'create', AsyncMock(side_effect=[verify, pair])):
                try:
                    await recovery.ensure_pairing('selected', Mock())
                finally:
                    client.close.assert_awaited_once()
                    pair.close.assert_awaited_once()
                    verify.close.assert_awaited_once()

    async def test_missing_pairing_selects_unique_usb(self):
        with patch.object(recovery, 'list_devices', AsyncMock(return_value=[device()])),              patch.object(recovery, 'iter_remote_paired_identifiers', return_value=[]):
            self.assertEqual(await recovery.select_device(None, Mock()), 'selected')

    async def test_multiple_devices_without_unique_selection_fail_safely(self):
        with patch.object(recovery, 'list_devices', AsyncMock(return_value=[device('a'), device('b')])),              patch.object(recovery, 'iter_remote_paired_identifiers', return_value=['a', 'b']):
            with self.assertRaisesRegex(RuntimeError, 'select-exactly-one'):
                await recovery.select_device(None, Mock())

    async def test_no_pairing_waits_until_usb_attached(self):
        with patch.object(recovery, 'list_devices', AsyncMock(side_effect=[[], [device()]])),              patch.object(recovery, 'iter_remote_paired_identifiers', return_value=[]),              patch.object(recovery.asyncio, 'sleep', AsyncMock()):
            self.assertEqual(await recovery.select_device(None, Mock()), 'selected')


if __name__ == '__main__':
    unittest.main()
