"""Isolated CoreDevice transport. stdout: length-prefixed HEVC; stdin: JSON HID.

Wire: uint32 BE payload length, uint8 kind, payload. Kinds: 1=config JSON
(base64 VPS/SPS/PPS), 2=Annex B access unit, 3=status JSON. No network listener.
Only the pinned upstream RTP receiver is used; VNC serve() is never called.
"""
import argparse
import asyncio
import base64
import contextlib
import json
import logging
import signal
import struct
import sys
import time
import uuid

def log(stage, **fields):
    print(json.dumps(dict(stage=stage, monotonic=time.monotonic(), **fields)),
          file=sys.stderr, flush=True)


# Only controlled identifiers cross into UI/logs, never raw exception text,
# pairing records, device identifiers, or input values.
def failure_code(error):
    from pymobiledevice3.exceptions import DeveloperModeIsNotEnabledError
    if isinstance(error, DeveloperModeIsNotEnabledError):
        return 'developer-mode-disabled'
    known = {
        'developer-mode-disabled', 'developer-mode-status-unavailable',
        'wifi-device-not-found', 'wifi-route-unavailable',
        'selected-device-not-reachable-on-lan', 'selected-device-network-pairing-missing',
        'select-exactly-one-paired-device', 'selected-usb-device-unavailable',
        'network-route-inspection-failed', 'primary-display-not-unique',
        'existing-media-session', 'consumer-backlog', 'network-pairing-repair-failed',
    }
    if isinstance(error, RuntimeError) and str(error) in known:
        return str(error)
    if isinstance(error, TimeoutError):
        return 'connection-timed-out'
    if isinstance(error, (ConnectionError, OSError)):
        return 'connection-lost'
    return 'connection-failed'


def encode_packet(kind, payload):
    return struct.pack('>IB', len(payload) + 1, kind) + payload


def normalized_touch(command):
    values = [command.get('x'), command.get('y')]
    if any(type(v) not in (int, float) or not 0 <= v <= 1 for v in values):
        raise ValueError('invalid-normalized-coordinate')
    return tuple(round(v * 65535) for v in values)


def keyboard_usages(command):
    values = command.get('usages')
    if not isinstance(values, list) or len(values) > 240:
        raise ValueError('invalid-keyboard-report')
    if any(type(v) is not int or not 0 <= v < 240 for v in values):
        raise ValueError('invalid-keyboard-usage')
    return set(values)


TOOLBAR_ACTIONS = {'home', 'search', 'volumeDown', 'volumeUp', 'mute',
                   'dragLeft', 'dragRight', 'screenshot', 'switchApps', 'appSwitcher', 'autoUnlock'}


def validated_sequence(command):
    steps = command.get('steps')
    if command.get('action') not in TOOLBAR_ACTIONS or not isinstance(steps, list) or not 1 <= len(steps) <= 512:
        raise ValueError('invalid-toolbar-sequence')
    duration = 0
    for step in steps:
        if not isinstance(step, dict):
            raise ValueError('invalid-toolbar-step')
        kind = step.get('command')
        if kind == 'keys':
            keyboard_usages(step)
        elif kind == 'touch':
            normalized_touch(step)
            if type(step.get('down')) is not bool:
                raise ValueError('invalid-touch-state')
        elif kind == 'button':
            if type(step.get('usage')) is not int or step['usage'] not in (0x40, 0xE2, 0xE9, 0xEA):
                raise ValueError('invalid-consumer-button')
        elif kind == 'wait':
            delay = step.get('seconds')
            if type(delay) not in (int, float) or not 0 <= delay <= 5:
                raise ValueError('invalid-toolbar-delay')
            duration += delay
        else:
            raise ValueError('invalid-toolbar-step')
    if duration > 30:
        raise ValueError('toolbar-sequence-too-long')
    return steps


class Session:
    def __init__(self, args):
        self.args = args
        self.stop = asyncio.Event()
        self.output = asyncio.Queue(maxsize=120)
        self.hid = None
        self.keyboard = None
        self.keyboard_hid = None
        self.indigo = None
        self.touch = None
        self.home_down = False
        self.button_down = None
        self.action_task = None
        self.frames = 0
        self.media_started = False
        self.first_access_unit = asyncio.Event()
        self.receiver = None
        self.cleaning_up = False

    def packet(self, kind, payload):
        try:
            self.output.put_nowait(encode_packet(kind, payload))
        except asyncio.QueueFull:
            log('output.failed', reason='consumer-backlog')
            self.stop.set()
            raise RuntimeError('consumer-backlog')

    def status(self, state, **fields):
        log(state, **fields)
        self.packet(3, json.dumps(dict(state=state, **fields)).encode())

    async def write_output(self):
        # Pipe flow control is asynchronous: a slow viewer cannot freeze HID cleanup.
        loop = asyncio.get_running_loop()
        transport, protocol = await loop.connect_write_pipe(asyncio.streams.FlowControlMixin, sys.stdout.buffer)
        writer = asyncio.StreamWriter(transport, protocol, None, loop)
        try:
            while True:
                writer.write(await self.output.get())
                await writer.drain()
        finally:
            writer.close()

    async def release(self):
        from pymobiledevice3.remote.core_device.hid_service import TOUCHSCREEN_STATE_RELEASE, HID_BUTTON_STATE_UP
        log('input.release.request')
        errors = []
        operations = []
        if self.hid is not None and self.touch is not None:
            operations.append(self.hid.send_touchscreen(TOUCHSCREEN_STATE_RELEASE, *self.touch))
        if self.keyboard is not None and (self.keyboard_hid is not None or self.hid is not None):
            operations.append((self.keyboard_hid or self.hid).send_keyboard(self.keyboard, ()))
        if self.indigo is not None and (self.home_down or self.button_down is not None):
            operations.append(self.indigo.send_button(0x0C, self.button_down if self.button_down is not None else 0x40, HID_BUTTON_STATE_UP))
        for operation in operations:
            try:
                await asyncio.wait_for(operation, 2)
            except Exception as error:
                errors.append(type(error).__name__)
        self.touch = None
        self.home_down = False
        self.button_down = None
        log('input.release.response', errors=errors)

    async def cancel_action(self):
        task, self.action_task = self.action_task, None
        if task is not None:
            if not task.done():
                log('toolbar.cancel.request')
                task.cancel()
            await asyncio.gather(task, return_exceptions=True)

    async def send_event(self, rsd, command):
        from pymobiledevice3.remote.core_device.hid_service import (
            UniversalHIDServiceService, IndigoHIDService,
            TOUCHSCREEN_STATE_CONTACT, TOUCHSCREEN_STATE_RELEASE,
            HID_BUTTON_STATE_DOWN, HID_BUTTON_STATE_UP,
        )
        name = command['command']
        if name == 'wait':
            await asyncio.sleep(command['seconds'])
        elif name in ('home', 'button'):
            if self.indigo is None:
                log('indigo.connect.request')
                self.indigo = IndigoHIDService(rsd)
                await self.indigo.connect()
                log('indigo.connect.response')
            self.button_down = command.get('usage', 0x40)
            await self.indigo.send_button(0x0C, self.button_down, HID_BUTTON_STATE_DOWN)
            await self.indigo.send_button(0x0C, self.button_down, HID_BUTTON_STATE_UP)
            self.button_down = None
        elif name == 'keys':
            usages = keyboard_usages(command)
            if self.keyboard is None:
                log('keyboard.create.request')
                self.keyboard_hid = UniversalHIDServiceService(rsd)
                await self.keyboard_hid.connect()
                self.keyboard = await self.keyboard_hid.create_keyboard_service()
                log('keyboard.create.response')
            await self.keyboard_hid.send_keyboard(self.keyboard, usages)
        elif name == 'touch':
            position = normalized_touch(command)
            if type(command.get('down')) is not bool:
                raise ValueError('invalid-touch-state')
            if self.hid is None:
                log('hid.connect.request')
                self.hid = UniversalHIDServiceService(rsd)
                await self.hid.connect()
                log('hid.connect.response')
            self.touch = position
            await self.hid.send_touchscreen(TOUCHSCREEN_STATE_CONTACT if command['down'] else TOUCHSCREEN_STATE_RELEASE, *position)
            if not command['down']:
                self.touch = None
        else:
            raise ValueError('unknown-command')

    async def run_action(self, rsd, action, steps):
        self.status('toolbar.started', action=action)
        try:
            await self.release()
            for step in steps:
                await self.send_event(rsd, step)
            self.status('toolbar.completed', action=action)
        except asyncio.CancelledError:
            self.status('toolbar.cancelled', action=action)
            raise
        except Exception as error:
            self.status('toolbar.failed', action=action, error_type=type(error).__name__)
        finally:
            await self.release()

    async def commands(self, rsd):
        reader = asyncio.StreamReader(limit=65536)
        protocol = asyncio.StreamReaderProtocol(reader)
        transport, _ = await asyncio.get_running_loop().connect_read_pipe(lambda: protocol, sys.stdin.buffer)
        try:
            while line := await reader.readline():
                command = json.loads(line)
                name = command.get('command')
                # Never log coordinates, key values, passcodes, or user text.
                log('input.command.received', command=name if name in ('stop', 'release', 'touch', 'keys', 'home', 'sequence', 'decoded', 'decode-error') else 'unknown')
                if name in ('decoded', 'decode-error'):
                    self.status('video.' + name)
                    if name == 'decode-error' and self.receiver is not None:
                        self.receiver._on_decode_error()
                    continue
                # Await cleanup before accepting another action or physical input.
                await self.cancel_action()
                if name == 'stop':
                    self.stop.set()
                    return
                if name == 'release':
                    await self.release()
                    continue
                if not self.media_started:
                    self.status('input.rejected', reason='media-not-active')
                    continue
                try:
                    if name == 'sequence':
                        steps = validated_sequence(command)
                        self.action_task = asyncio.create_task(self.run_action(rsd, command['action'], steps))
                    else:
                        if name not in ('touch', 'keys', 'home'):
                            raise ValueError('unknown-command')
                        await self.send_event(rsd, command)
                        self.status('input.sent')
                except Exception as error:
                    self.status('input.failed', error_type=type(error).__name__)
                    await self.release()
        finally:
            await self.cancel_action()
            transport.close()
            self.stop.set()

    async def run(self):
        from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
        from pymobiledevice3.remote.core_device.display_service import DisplayService
        from pymobiledevice3.remote.core_device.screen_stream import open_media_receiver
        from pymobiledevice3.remote.core_device.vnc_server import VncStreamServer
        from pymobiledevice3.remote.core_device.hevc_rps import parse_sps, remove_emulation_prevention
        from pymobiledevice3.usbmux import list_devices

        connection = self.args.connection
        if connection == 'wifi':
            from network_transport import WifiTunnel
            from functools import partial
            from pairing_recovery import select_device
            self.args.serial = await select_device(self.args.serial, self.status)
            tunnel_class = partial(WifiTunnel, status=self.status)
        else:
            devices = [d for d in await list_devices() if d.is_usb and d.matches_udid(self.args.serial)]
            if len(devices) != 1:
                raise RuntimeError('selected-usb-device-unavailable')
            tunnel_class = UserspaceRsdTunnel
        from developer_mode import check_usb, require_before_stream
        # Resolve the selected USB serial too, before querying a specific device.
        if connection == 'usb':
            self.args.serial = devices[0].serial
        usb_verified = await check_usb(self.args.serial, self.status)
        self.status('tunnel.starting', transport=connection)
        async with tunnel_class(serial=self.args.serial, autopair=False, remotepairing_fallback=False) as rsd:
            self.status('tunnel.connected', transport=connection)
            await require_before_stream(rsd, usb_verified, self.status)
            if self.args.display_id is None:
                from pymobiledevice3.remote.core_device.device_info import DeviceInfoService
                async with DeviceInfoService(rsd) as info:
                    displays = (await info.get_display_info())['displays']
                primary = [d for d in displays if d.get('primary') and not d.get('external')]
                if len(primary) != 1:
                    raise RuntimeError('primary-display-not-unique')
                self.args.display_id = primary[0]['displayId']
                self.status('display.selected', display_id=self.args.display_id)
            service = DisplayService(rsd)
            media = None
            session_id = uuid.uuid4()
            started = False
            tasks = []
            receiver = None
            try:
                # dtremotedisplayd requires one reply-bearing request per channel.
                # Enforce exclusive ownership before using stopAll for cleanup.
                async with DisplayService(rsd) as check:
                    server = await check.get_media_stream_server_status()
                    if server.get('running') or server.get('sessions'):
                        log('media.exclusive.rejected', reason='existing-media-session')
                        raise RuntimeError('existing-media-session')
                    log('media.exclusive.accepted')
                async with DisplayService(rsd) as capabilities:
                    log('display.capability.request')
                    support = await capabilities.get_media_support_info()
                self.status('display.capability.response', supported_features=support.get('supportedFeatures'))
                if not support.get('supportedFeatures'):
                    raise RuntimeError('no-media-features')
                log('display.connect.request')
                await service.connect()
                media, address = open_media_receiver(service, (8 * 1024 * 1024, 4 * 1024 * 1024))
                log('media.start.request', display_id=self.args.display_id)
                # Mark before awaiting: cleanup also covers a lost negotiation reply.
                started = True
                answer = await asyncio.wait_for(service.start_video_stream(
                    receiver_ip=address, receiver_port=media.port, sender_ip=rsd.service.address[0],
                    display_id=self.args.display_id, client_session_id=session_id,
                    allow_rtcp_fb=False, ltrp_enabled=False), 30)
                sid = answer['connection']['options']['avcMediaStreamOptionClientSessionID']['uuid']
                session_id = sid if isinstance(sid, uuid.UUID) else uuid.UUID(sid)
                self.media_started = True
                self.status('media.started')
                owner = self

                class AccessUnits:
                    def __init__(self, vps, sps, pps, **callbacks):
                        sps_info = parse_sps(remove_emulation_prevention(sps[2:]))
                        self.width = sps_info.pic_width_in_luma_samples
                        self.height = sps_info.pic_height_in_luma_samples
                        owner.packet(1, json.dumps(dict(width=self.width, height=self.height,
                            parameter_sets=[base64.b64encode(n).decode() for n in (vps, sps, pps)])).encode())
                        owner.status('video.configured', width=self.width, height=self.height)

                    def feed(self, data):
                        owner.packet(2, data)
                        owner.frames += 1
                        owner.first_access_unit.set()
                        if owner.frames == 1 or owner.frames % 300 == 0:
                            owner.status('video.received', access_units=owner.frames)

                    def close(self):
                        log('video.adapter.closed')

                receiver = VncStreamServer(rsd, bind='127.0.0.1', audio=False, decoder='vt')
                self.receiver = receiver
                receiver._transcoder_cls = AccessUnits
                receiver._loop = asyncio.get_running_loop()
                cfg = answer['connection'].get('streamConfig', {})
                receiver._local_ssrc = int(cfg.get('RemoteSSRC', 0))
                receiver._remote_ssrc = int(cfg.get('LocalSSRC', 0))
                source_port = int(cfg.get('SourcePort', 0))
                receiver._rtcp_dest = (rsd.service.address[0], source_port) if source_port else None
                receiver._active_transport = media
                tasks = [asyncio.create_task(receiver._udp_recv_and_pipe(media)),
                         asyncio.create_task(receiver._rtcp_send_loop(media)),
                         asyncio.create_task(self.commands(rsd))]
                if self.args.audio:
                    tasks.append(asyncio.create_task(self.audio(rsd, receiver, session_id)))
                stop_task = asyncio.create_task(self.stop.wait())
                tasks.append(stop_task)
                first_frame = asyncio.create_task(asyncio.wait_for(self.first_access_unit.wait(), 20))
                try:
                    done, _ = await asyncio.wait([*tasks, first_frame], return_when=asyncio.FIRST_COMPLETED)
                    for task in done:
                        task.result()
                    if first_frame not in done:
                        log('session.stopping', reason='stopped-before-first-access-unit')
                        return
                    log('video.first-access-unit.confirmed')
                finally:
                    first_frame.cancel()
                    await asyncio.gather(first_frame, return_exceptions=True)
                done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
                for task in done:
                    task.result()
                log('session.stopping')
            finally:
                self.cleaning_up = True
                # Stop command production, release input, stop media, then dismantle transport.
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
                await self.release()
                if started:
                    log('media.stop.request')
                    try:
                        async def stop_owned_media():
                            async with DisplayService(rsd) as stop_service:
                                await stop_service.invoke(
                                    'com.apple.coredevice.feature.stopmediastream', {'stopAll': True},
                                    action_identifier='com.apple.coredevice.action.mediastreamstop')
                        await asyncio.wait_for(stop_owned_media(), 5)
                        log('media.stop.response')
                    except Exception as error:
                        log('media.stop.failed', error_type=type(error).__name__)
                if receiver is not None:
                    pending = list(receiver._pli_tasks)
                    for task in pending:
                        task.cancel()
                    await asyncio.gather(*pending, return_exceptions=True)
                if media is not None:
                    media.close()
                for resource in (self.hid, self.keyboard_hid, self.indigo, service):
                    if resource is not None:
                        try:
                            await asyncio.wait_for(resource.close(), 2)
                        except Exception as error:
                            log('service.close.failed', error_type=type(error).__name__)
                log('session.closed')

    async def audio(self, rsd, receiver, session_id):
        """Pair system audio with video; use the pinned macOS AAC/CoreAudio path."""
        from pymobiledevice3.remote.core_device.display_service import DisplayService
        from pymobiledevice3.remote.core_device.screen_stream import open_media_receiver
        from pymobiledevice3.remote.core_device.aac_eld import AACELDDecoder
        from pymobiledevice3.remote.core_device.audio_player import AudioQueuePlayer
        service = DisplayService(rsd)
        transport = None
        tasks = []
        try:
            self.status('audio.starting')
            await service.connect()
            transport, address = open_media_receiver(service, (4 * 1024 * 1024, 1024 * 1024))
            answer = await asyncio.wait_for(service.start_audio_stream(
                receiver_ip=address, receiver_port=transport.port,
                sender_ip=rsd.service.address[0], client_session_id=session_id), 25)
            cfg = answer['connection'].get('streamConfig', {})
            port = int(cfg.get('SourcePort', 0))
            receiver._audio_local_ssrc = int(cfg.get('RemoteSSRC', 0))
            receiver._audio_remote_ssrc = int(cfg.get('LocalSSRC', 0))
            if not port or not receiver._audio_local_ssrc or not receiver._audio_remote_ssrc:
                raise RuntimeError('audio-rtcp-negotiation-incomplete')
            receiver._audio_rtcp_dest = (rsd.service.address[0], port)
            receiver._audio_decoder = AACELDDecoder()
            receiver._audio_player = AudioQueuePlayer()
            self.status('audio.ready', payload_type=cfg.get('RxPayloadType'), mode=cfg.get('AudioStreamMode'))

            async def monitor():
                playing = False
                while True:
                    await asyncio.sleep(5)
                    played, dropped, errors = receiver._audio_player.stats()
                    log('audio.stats', received=receiver._audio_rtp_packets_received,
                        played=played, dropped=dropped, enqueue_errors=errors)
                    if played and not playing:
                        playing = True
                        self.status('audio.playing')

            tasks = [asyncio.create_task(receiver._audio_udp_recv(transport)),
                     asyncio.create_task(receiver._audio_rtcp_send_loop(transport)),
                     asyncio.create_task(monitor())]
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()
            raise RuntimeError('audio-receiver-ended')
        except Exception as error:
            self.status('audio.failed', error_type=type(error).__name__)
            # Keep the verified video/input running, but expose the audio failure.
            await self.stop.wait()
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            if receiver._audio_player is not None:
                receiver._audio_player.close()
                receiver._audio_player = None
            receiver._audio_decoder = None
            if transport is not None:
                transport.close()
            await asyncio.wait_for(service.close(), 2)
            log('audio.closed')


async def supervise(session):
    """Honor stop even before the command reader/media tasks have started.

    Cancel run only once. Its finally blocks retain responsibility for HID/media
    cleanup, including when the output pipe has already disappeared.
    """
    writer = asyncio.create_task(session.write_output())
    run = asyncio.create_task(session.run())
    stopping = asyncio.create_task(session.stop.wait())
    exit_code = 0
    try:
        done, _ = await asyncio.wait((writer, run, stopping), return_when=asyncio.FIRST_COMPLETED)
        if writer in done:
            log('session.supervisor.output-ended')
            writer.result()
        if run in done:
            log('session.supervisor.run-ended')
            run.result()
        elif stopping in done:
            log('session.supervisor.stop-requested')
    except Exception as error:
        log('session.failed', error_type=type(error).__name__, code=failure_code(error))
        exit_code = 1
    finally:
        session.stop.set()
        if not run.done() and not getattr(session, 'cleaning_up', False):
            log('session.supervisor.cancel-run-once')
            run.cancel()
        results = await asyncio.gather(run, return_exceptions=True)
        for result in results:
            if isinstance(result, Exception):
                log('session.cleanup.failed', error_type=type(result).__name__, code=failure_code(result))
                exit_code = 1
        writer.cancel()
        stopping.cancel()
        await asyncio.gather(writer, stopping, return_exceptions=True)
        log('session.supervisor.closed')
    return exit_code


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', help='Required for USB; Wi-Fi can select a unique saved pairing')
    parser.add_argument('--connection', choices=('usb', 'wifi'), default='usb')
    parser.add_argument('--audio', action='store_true', help='Play paired system audio through CoreAudio')
    parser.add_argument('--display-id', type=int, help='Defaults to the primary integrated display')
    args = parser.parse_args()
    logging.basicConfig(level=logging.WARNING, stream=sys.stderr)
    session = Session(args)
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, session.stop.set)
    try:
        return await supervise(session)
    finally:
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.remove_signal_handler(sig)


if __name__ == '__main__':
    sys.exit(asyncio.run(main()))
