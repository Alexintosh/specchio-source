"""List/delete only local RemotePairing records. Never emit their secret contents."""
import argparse
import json
import re

from pymobiledevice3.common import get_home_folder
from pymobiledevice3.pair_records import PAIRING_RECORD_EXT, get_remote_pairing_record_filename


def records(folder):
    result = {}
    for path in folder.glob(f'remote_*.{PAIRING_RECORD_EXT}'):
        identifier = path.name[len('remote_'):-(len(PAIRING_RECORD_EXT) + 1)]
        if re.fullmatch(r'[A-Za-z0-9-]+', identifier) and path.is_file() and not path.is_symlink():
            result[identifier] = path
    return result


def manage(folder, identifier=None):
    if identifier is not None:
        if not re.fullmatch(r'[A-Za-z0-9-]+', identifier):
            raise ValueError('invalid-device')
        # Resolve only from the actual inventory, never from caller-provided paths.
        path = records(folder).get(identifier)
        if path is not None:
            path.unlink(missing_ok=True)
    return {'devices': [{'id': identifier} for identifier in sorted(records(folder))]}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--remove')
    args = parser.parse_args()
    try:
        print(json.dumps(manage(get_home_folder(), args.remove)))
    except Exception:
        print(json.dumps({'error': 'device-record-operation-failed'}))
        raise SystemExit(1)
