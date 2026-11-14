import unittest
from distribution.direct_dmg import working_size_mib


class DiskImageCapacityTests(unittest.TestCase):
    def test_payload_always_has_room_for_apfs_and_layout(self):
        for size in [1, 29 << 20, 64 << 20, 128 << 20]:
            capacity = working_size_mib(size) << 20
            self.assertGreaterEqual(capacity - size, 64 << 20)
            self.assertEqual(capacity % (32 << 20), 0)
            self.assertLessEqual(capacity, 192 << 20)
        self.assertEqual(working_size_mib(29 << 20), 96)

    def test_unexpected_payloads_are_refused_before_creating_an_image(self):
        for value in [0, -1, (128 << 20) + 1, True, 29.5, None]:
            with self.assertRaises(ValueError):
                working_size_mib(value)


if __name__ == '__main__':
    unittest.main()
