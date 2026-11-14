"""Independent generated headers plus real descriptor/path replacement controls."""
import os
from pathlib import Path
import struct
import unittest
from unittest import mock
import uuid
from distribution import macho_minimum_os as m


def command(platform=1, minimum=0x000f0000, sdk=0x001b0000, tools=0):
    return struct.pack('<IIIIII', 0x32, 24+tools*8, platform, minimum, sdk, tools) + b'\x00'*tools*8


def image(commands, count=None):
    return struct.pack('<IIIIIIII',0xfeedfacf,0x100000c,0,2,len(commands) if count is None else count,
                       sum(len(c) for c in commands),0,0) + b''.join(commands)


class MachOMinimumOSTests(unittest.TestCase):
    def test_actual_public_encoding_with_and_without_tool_record(self):
        for tools in [0,1,3]:
            target=m.decode(image([command(tools=tools)]))
            self.assertEqual(target,dict(platform=1,minimumOS=(15,0,0),sdk=(27,0,0)))
            self.assertTrue(m.admitted(target))

    def test_unknown_bounded_commands_do_not_rewrite_build_version(self):
        target=m.decode(image([struct.pack('<II',0x777,8),command(minimum=0x000f0203)]))
        self.assertEqual(target['minimumOS'],(15,2,3))
        self.assertFalse(m.admitted(target))

    def test_missing_duplicate_and_legacy_only_build_commands_refuse(self):
        for commands in [[struct.pack('<II',0x777,8)],[command(),command()],[struct.pack('<IIII',0x24,16,0x000f0000,0x001b0000)]]:
            with self.subTest(commands=commands),self.assertRaises(ValueError):m.decode(image(commands))

    def test_magic_endianness_and_every_truncation_refuse(self):
        valid=image([command(tools=1)])
        for cut in range(len(valid)):
            with self.subTest(cut=cut),self.assertRaises(ValueError):m.decode(valid[:cut])
        for magic in [b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe',b'\xce\xfa\xed\xfe',b'zero']:
            with self.subTest(magic=magic),self.assertRaises(ValueError):m.decode(magic+valid[4:])

    def test_count_byte_bounds_and_exact_command_consumption(self):
        header=image([command()])[:32]
        for count,size in [(0,24),(4097,24),(1,0),(1,(1<<20)+8),(1,25)]:
            bad=bytearray(header);struct.pack_into('<II',bad,16,count,size)
            with self.subTest(count=count,size=size),self.assertRaises(ValueError):m.decode(bytes(bad))
        for data in [image([command()],count=2),image([command()],count=0),image([command()])+b'\x00'*8]:
            with self.assertRaises(ValueError):m.decode(data)

    def test_invalid_size_alignment_and_tool_count_refuse(self):
        for length in [0,4,12,16,4096]:
            bad=bytearray(image([command()]));struct.pack_into('<I',bad,36,length)
            with self.subTest(length=length),self.assertRaises(ValueError):m.decode(bytes(bad))
        bad=bytearray(image([command(tools=1)]));struct.pack_into('<I',bad,52,0)
        with self.assertRaises(ValueError):m.decode(bytes(bad))

    def test_platform_and_floor_are_separate_from_valid_shape(self):
        for platform,minimum,expected in [(1,0x000d0000,True),(1,0x000f0000,True),(1,0x000f0001,False),
                                           (1,0x00100000,False),(1,0,False),(0,0x000f0000,False),(2,0x000f0000,False)]:
            self.assertEqual(m.admitted(m.decode(image([command(platform,minimum)]))),expected)

    def test_declared_versions_are_bounded_and_do_not_drop_patch(self):
        for text,expected in [('15',(15,0,0)),('15.0',(15,0,0)),('15.0.1',(15,0,1))]:self.assertEqual(m.version(text),expected)
        for text in [None,15,'','0.0','15.0.0.0','15.256','65536.0','15.0\n','15.-1','１５.0']:
            with self.subTest(text=text),self.assertRaises(ValueError):m.version(text)

    def test_declared_info_cannot_raise_the_reviewed_floor(self):
        from distribution.preflight import info_checks
        for text,expected in [('15',True),('15.0',True),('15.0.0',True),('14.0',False),('15.0.1',False),('16.0',False),('99.0',False),(None,False)]:
            checks={r['id']:r['passed'] for r in info_checks(dict(LSMinimumSystemVersion=text),'com.generated.Traverse')}
            self.assertEqual(checks['reviewed_minimum_macos'],expected)


class MachODescriptorTests(unittest.TestCase):
    def setUp(self):
        root=Path(os.environ['TRAVERSE_DEPLOYMENT_TEST_ROOT'])
        self.assertEqual(root.resolve(),root)
        self.assertEqual(root.name,'source')
        self.assertTrue((root.parent/'reservation.json').is_file())
        self.root=root/str(uuid.uuid4()).upper();self.root.mkdir(mode=0o700)

    def test_regular_header_reads_without_reading_the_body(self):
        path=self.root/'Binary';data=image([command()]);path.write_bytes(data+b'Generated payload not needed by inspector')
        original=os.pread;seen=[]
        def observe(fd,length,offset):seen.append((length,offset));return original(fd,length,offset)
        with mock.patch.object(os,'pread',side_effect=observe):self.assertTrue(m.admitted(m.read_target(path)))
        self.assertEqual(seen,[(32,0),(24,32)])

    def test_symlink_directory_fifo_and_truncated_target_refuse(self):
        path=self.root/'Binary';path.write_bytes(image([command()]))
        link=self.root/'Link';link.symlink_to(path)
        fifo=self.root/'FIFO';os.mkfifo(fifo,0o600)
        short=self.root/'Short';short.write_bytes(b'Generated short file')
        for target in [link,self.root,fifo,short]:
            with self.subTest(target=target),self.assertRaises((ValueError,OSError)):m.read_target(target)

    def test_actual_byte_identical_replacement_refuses(self):
        path=self.root/'Binary';data=image([command()]);path.write_bytes(data)
        replacement=self.root/'Replacement';replacement.write_bytes(data)
        original=os.pread
        def replace(fd,length,offset):
            found=original(fd,length,offset)
            if offset==32:os.replace(replacement,path)
            return found
        with mock.patch.object(os,'pread',side_effect=replace),self.assertRaises(ValueError):m.read_target(path)


if __name__=='__main__':unittest.main()
