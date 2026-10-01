import json
from pathlib import Path
import tempfile
import unittest
from devices import manage


class DeviceManagementTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)

    def test_inventory_never_reads_or_exposes_pairing_secrets(self):
        (self.folder / 'remote_phone-1.plist').write_text('PRIVATE-KEY-SENTINEL')
        result = manage(self.folder)
        self.assertEqual(result, {'devices': [{'id': 'phone-1'}]})
        self.assertNotIn('PRIVATE', json.dumps(result))

    def test_removes_only_selected_remote_record(self):
        for name in ['remote_phone-1.plist', 'remote_phone-2.plist', 'phone-1.plist', 'remote_phone-1.backup']:
            (self.folder / name).write_text('secret')
        result = manage(self.folder, 'phone-1')
        self.assertEqual(result, {'devices': [{'id': 'phone-2'}]})
        self.assertEqual({p.name for p in self.folder.iterdir()},
                         {'remote_phone-2.plist', 'phone-1.plist', 'remote_phone-1.backup'})

    def test_missing_record_removal_is_idempotent(self):
        self.assertEqual(manage(self.folder, 'absent'), {'devices': []})

    def test_path_traversal_is_rejected(self):
        for identifier in ['../other', '/tmp/other', '', 'phone.plist']:
            with self.subTest(identifier=identifier), self.assertRaises(ValueError):
                manage(self.folder, identifier)

    def test_symlink_is_not_listed_or_removed(self):
        target = self.folder / 'valuable.plist'
        target.write_text('secret')
        link = self.folder / 'remote_phone.plist'
        link.symlink_to(target)
        self.assertEqual(manage(self.folder, 'phone'), {'devices': []})
        self.assertTrue(link.is_symlink())
        self.assertEqual(target.read_text(), 'secret')


if __name__ == '__main__':
    unittest.main()
