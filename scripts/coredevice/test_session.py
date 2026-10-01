import asyncio
import importlib.util
from pathlib import Path
import struct
import unittest
from unittest.mock import AsyncMock, Mock, patch
from types import SimpleNamespace
import uuid

spec = importlib.util.spec_from_file_location('coredevice_session', Path(__file__).with_name('session.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class WireTests(unittest.TestCase):
    def test_binary_packet_preserves_nal_bytes(self):
        payload = b'\x00\x00\x00\x01\x26\x01\xff'
        packet = module.encode_packet(2, payload)
        self.assertEqual(struct.unpack('>I', packet[:4])[0], len(payload) + 1)
        self.assertEqual(packet[4], 2)
        self.assertEqual(packet[5:], payload)

    def test_coordinates_reject_nonfinite_and_outside_surface(self):
        for value in (float('nan'), float('inf'), -0.01, 1.01, True, '0.5', None):
            with self.subTest(value=value), self.assertRaises(ValueError):
                module.normalized_touch(dict(x=value, y=0.5))
        self.assertEqual(module.normalized_touch(dict(x=0, y=1)), (0, 65535))

    def test_keyboard_rejects_truncation_and_invalid_usage(self):
        for values in ([240], [-1], [True], [1.5], 'abc', None):
            with self.subTest(values=values), self.assertRaises(ValueError):
                module.keyboard_usages(dict(usages=values))
        self.assertEqual(module.keyboard_usages(dict(usages=[4, 225, 4])), {4, 225})
        self.assertEqual(module.keyboard_usages(dict(usages=[])), set())


class CleanupTests(unittest.IsolatedAsyncioTestCase):
    async def test_audio_shares_video_session_and_cleans_up_on_cancel(self):
        session = module.Session(None)
        session_id = uuid.uuid4()
        ready = asyncio.Event()
        session.status = lambda state, **fields: ready.set() if state == 'audio.ready' else None
        service = SimpleNamespace(connect=AsyncMock(), close=AsyncMock(),
            start_audio_stream=AsyncMock(return_value={'connection': {'streamConfig': {
                'SourcePort': 1234, 'RemoteSSRC': 10, 'LocalSSRC': 20}}}))
        transport = SimpleNamespace(port=4321, close=Mock())
        player = SimpleNamespace(close=Mock(), stats=lambda: (0, 0, 0))
        async def receive(_):
            await asyncio.Future()
        receiver = SimpleNamespace(_audio_player=None, _audio_decoder=None,
            _audio_udp_recv=receive, _audio_rtcp_send_loop=receive)
        rsd = SimpleNamespace(service=SimpleNamespace(address=('::1', 0)))
        with patch('pymobiledevice3.remote.core_device.display_service.DisplayService', return_value=service), \
             patch('pymobiledevice3.remote.core_device.screen_stream.open_media_receiver', return_value=(transport, '::2')), \
             patch('pymobiledevice3.remote.core_device.aac_eld.AACELDDecoder'), \
             patch('pymobiledevice3.remote.core_device.audio_player.AudioQueuePlayer', return_value=player):
            task = asyncio.create_task(session.audio(rsd, receiver, session_id))
            await asyncio.wait_for(ready.wait(), 1)
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        self.assertEqual(service.start_audio_stream.call_args.kwargs['client_session_id'], session_id)
        self.assertEqual(receiver._audio_rtcp_dest, ('::1', 1234))
        player.close.assert_called_once()
        transport.close.assert_called_once()
        service.close.assert_awaited_once()

    async def test_failure_during_ordered_cleanup_is_not_reported_as_success(self):
        class FailingSession:
            stop = asyncio.Event()
            cleaning_up = True

            async def write_output(self):
                await asyncio.Future()

            async def run(self):
                self.stop.set()
                await asyncio.sleep(0.01)
                raise RuntimeError('consumer-backlog')

        self.assertEqual(await module.supervise(FailingSession()), 1)

    async def exercise_supervisor(self, fail_writer):
        started = asyncio.Event()
        cleanup_started = asyncio.Event()
        allow_cleanup = asyncio.Event()
        closed = []

        class StalledSession:
            stop = asyncio.Event()

            async def write_output(self):
                try:
                    await started.wait()
                    if fail_writer:
                        raise BrokenPipeError()
                    await asyncio.Future()
                finally:
                    closed.append('writer')

            async def run(self):
                try:
                    started.set()
                    await asyncio.Future()  # Models a tunnel/API stuck before input starts.
                finally:
                    cleanup_started.set()
                    await allow_cleanup.wait()  # Cleanup must survive a second stop request.
                    closed.append('run')

        session = StalledSession()
        supervisor = asyncio.create_task(module.supervise(session))
        await asyncio.wait_for(started.wait(), 1)
        if not fail_writer:
            session.stop.set()
        await asyncio.wait_for(cleanup_started.wait(), 1)
        self.assertFalse(supervisor.done())
        session.stop.set()
        allow_cleanup.set()
        self.assertEqual(await asyncio.wait_for(supervisor, 1), 1 if fail_writer else 0)
        self.assertCountEqual(closed, ['run', 'writer'])

    async def test_stop_during_connection_waits_for_cleanup(self):
        await self.exercise_supervisor(fail_writer=False)

    async def test_broken_output_pipe_still_completes_cleanup(self):
        await self.exercise_supervisor(fail_writer=True)

    async def test_release_attempts_keyboard_after_touch_failure(self):
        calls = []

        class HID:
            async def send_touchscreen(self, *args):
                calls.append('touch')
                raise ConnectionError()

            async def send_keyboard(self, service, keys):
                calls.append(('keys', service, tuple(keys)))

        session = module.Session(None)
        session.hid = HID()
        session.touch = (12, 34)
        session.keyboard = 42
        await session.release()
        self.assertEqual(calls, ['touch', ('keys', 42, ())])
        self.assertIsNone(session.touch)

    async def test_backpressure_stops_session_instead_of_dropping_hevc_deltas(self):
        session = module.Session(None)
        session.output = asyncio.Queue(maxsize=1)
        session.packet(2, b'first')
        with self.assertRaises(RuntimeError):
            session.packet(2, b'second')
        self.assertTrue(session.stop.is_set())

class ToolbarSequenceTests(unittest.IsolatedAsyncioTestCase):
    def session(self):
        session = module.Session(SimpleNamespace())
        session.status = Mock()
        session.release = AsyncMock()
        return session

    def test_invalid_sequence_rejected_before_hid_access(self):
        invalid = [
            {'command': 'wait', 'seconds': float('nan')},
            {'command': 'wait', 'seconds': 6},
            {'command': 'keys', 'usages': [240]},
            {'command': 'touch', 'down': True, 'x': -1, 'y': .5},
            {'command': 'button', 'usage': 0xFFFF},
            {'command': 'stop'},
        ]
        for step in invalid:
            with self.subTest(step=step), self.assertRaises(ValueError):
                module.validated_sequence({'action': 'home', 'steps': [step]})
        with self.assertRaises(ValueError):
            module.validated_sequence({'action': 'autoUnlock', 'steps': [{'command': 'wait', 'seconds': 5}] * 7})

    async def test_keyboard_sequence_is_ordered_and_released(self):
        session = self.session()
        session.send_event = AsyncMock()
        steps = module.validated_sequence({'action': 'search', 'steps': [
            {'command': 'keys', 'usages': [227]},
            {'command': 'keys', 'usages': [227, 44]},
            {'command': 'wait', 'seconds': .05},
            {'command': 'keys', 'usages': [227]},
            {'command': 'keys', 'usages': []},
        ]})
        await session.run_action('rsd', 'search', steps)
        self.assertEqual([call.args[1] for call in session.send_event.await_args_list], steps)
        self.assertEqual(session.release.await_count, 2)
        session.status.assert_any_call('toolbar.completed', action='search')

    async def test_unlock_cancellation_prevents_remaining_keys(self):
        session = self.session()
        started = asyncio.Event()
        async def blocked_event(rsd, step):
            started.set()
            await asyncio.Event().wait()
        session.send_event = AsyncMock(side_effect=blocked_event)
        session.action_task = asyncio.create_task(session.run_action(None, 'autoUnlock', [
            {'command': 'wait', 'seconds': 2}, {'command': 'keys', 'usages': [30]},
        ]))
        await started.wait()
        await session.cancel_action()
        self.assertIsNone(session.action_task)
        self.assertEqual(session.send_event.await_count, 1)
        self.assertEqual(session.release.await_count, 2)
        session.status.assert_any_call('toolbar.cancelled', action='autoUnlock')

    async def test_hid_error_releases_and_does_not_complete(self):
        session = self.session()
        session.send_event = AsyncMock(side_effect=OSError('test'))
        await session.run_action(None, 'home', [{'command': 'button', 'usage': 0x40}])
        session.status.assert_any_call('toolbar.failed', action='home', error_type='OSError')
        self.assertEqual(session.release.await_count, 2)
        self.assertFalse(any(call.args[0] == 'toolbar.completed' for call in session.status.call_args_list))

    async def test_keyboard_and_consumer_release_without_touch_service(self):
        session = module.Session(SimpleNamespace())
        session.keyboard_hid = SimpleNamespace(send_keyboard=AsyncMock())
        session.keyboard = 'keyboard'
        session.indigo = SimpleNamespace(send_button=AsyncMock())
        session.button_down = 0xE9
        await session.release()
        session.keyboard_hid.send_keyboard.assert_awaited_once_with('keyboard', ())
        self.assertEqual(session.indigo.send_button.await_args.args[:2], (0x0C, 0xE9))
        self.assertIsNone(session.button_down)


class ConnectionFailureTests(unittest.IsolatedAsyncioTestCase):
    def test_error_classification_never_exposes_exception_text(self):
        self.assertEqual(module.failure_code(RuntimeError('wifi-device-not-found')), 'wifi-device-not-found')
        self.assertEqual(module.failure_code(RuntimeError('secret payload')), 'connection-failed')
        self.assertEqual(module.failure_code(TimeoutError()), 'connection-timed-out')
        self.assertEqual(module.failure_code(ConnectionResetError()), 'connection-lost')

    async def test_supervisor_reports_discovery_failure_before_exit(self):
        async def writer():
            await asyncio.Event().wait()
        session = SimpleNamespace(stop=asyncio.Event(), write_output=writer,
            run=AsyncMock(side_effect=RuntimeError('wifi-device-not-found')))
        with patch.object(module, 'log') as log:
            self.assertEqual(await module.supervise(session), 1)
        log.assert_any_call('session.failed', error_type='RuntimeError', code='wifi-device-not-found')


if __name__ == '__main__':
    unittest.main()
