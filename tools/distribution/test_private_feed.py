import copy,json,unittest,xml.etree.ElementTree as XML
from pathlib import Path
from unittest import mock
from distribution import private_feed

class PrivateFeedTests(unittest.TestCase):
 def fixture(self):
  config=dict(channel='developer-id',accessPolicy='sandbox-selected-v1',privateUpdater=True,shippingCandidate=True,
    versionOverride={'version':'0.1.3','build':'10'})
  admission=dict(schema=1,bundleID='com.respawnstudios.traverse',version='0.1.3',build='10',channel='Developer ID',
    team='CDLNJRG82U',timestamped=True,stapled=True,gatekeeper='accepted',container='dmg',containerStapled=True,containerGatekeeper='accepted')
  item=dict(version='0.1.3',build='10',architecture='arm64',minimumOS='15.0',sha256='a'*64,bytes=128,
    filename='Traverse-0.1.3-10-arm64.dmg',id='generated-10',admission=admission)
  entry=dict(version='0.1.3',build=10,state='preview',date='2026-10-23',title='Files < & >',summary='Generated only',changes=['No <script> content'])
  return config,item,entry
 def test_only_matching_qualified_updater_artifacts_are_admitted(self):
  c,a,n=self.fixture();private_feed.admit(c,a,n)
  for change in [dict(privateUpdater=False),dict(shippingCandidate=False),dict(channel='app-store')]:
   with self.assertRaises(ValueError):private_feed.admit({**c,**change},a,n)
  for key,value in [('stapled',False),('containerGatekeeper','rejected'),('team','other'),('timestamped',False)]:
   bad=copy.deepcopy(a);bad['admission'][key]=value
   with self.assertRaises(ValueError):private_feed.admit(c,bad,n)
  for key,value in [('build',9),('state','unreleased')]:
   with self.assertRaises(ValueError):private_feed.admit(c,a,{**n,**{key:value}})
 def test_notes_escape_text_and_feed_uses_signed_notes_namespace_and_machine_build(self):
  c,a,n=self.fixture();body=private_feed.notes(n)
  self.assertNotIn(b'<script>',body);self.assertIn(b'&lt;script&gt;',body)
  sig='A'*86+'=='
  tree=XML.fromstring(private_feed.appcast(a,n,sig,sig,len(body)))
  namespace={'s':'http://www.andymatuschak.org/xml-namespaces/sparkle'}
  item=tree.find('./channel/item')
  self.assertEqual(item.find('s:version',namespace).text,'10')
  self.assertEqual(item.find('s:hardwareRequirements',namespace).text,'arm64')
  note=item.find('s:releaseNotesLink',namespace)
  self.assertEqual(note.attrib['{'+namespace['s']+'}length'],str(len(body)))
  self.assertEqual(item.find('enclosure').attrib['url'],private_feed.BASE+'/archives/'+'a'*64+'.dmg')
 def test_prepare_refuses_every_failed_technical_check_before_signer_access(self):
  config,item,entry=self.fixture()
  inputs={'configuration.json':json.dumps(config).encode(),
    'dmg/manifest.json':json.dumps({'schema':1,'artifacts':[item]}).encode()}
  with mock.patch.object(private_feed.source_capsule,'read_at',side_effect=lambda root,name,limit:inputs[name]), \
    mock.patch.object(private_feed,'frozen_history',return_value={'releases':[entry]}), \
    mock.patch.object(Path,'exists',return_value=False),mock.patch.object(Path,'is_symlink',return_value=False), \
    mock.patch.object(private_feed.sparkle,'verify') as signer_setup, \
    mock.patch.object(private_feed.subprocess,'check_output') as signer:
   for identifier in ('export_answer_present','export_answer_type','complete_bundle_signature'):
    with self.subTest(identifier=identifier),mock.patch.object(private_feed.preflight,'inspect',return_value={
      'checks':[{'id':identifier,'passed':False}]}):
     with self.assertRaisesRegex(ValueError,'Distribution preflight did not pass'):
      private_feed.prepare(Path('/generated/qualified'))
   signer_setup.assert_not_called();signer.assert_not_called()

if __name__=='__main__':unittest.main()
