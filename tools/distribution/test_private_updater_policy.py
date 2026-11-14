import unittest
from distribution import preflight
from folder_services import descriptor as folder_service_descriptor

class PrivateUpdaterPolicyTests(unittest.TestCase):
    def test_folder_service_is_exact_restricted_and_private_beta_only(self):
        info=dict(TraversePrivateUpdaterVersion='2.10.0',MacExplorerAccessPolicy='sandbox-selected-v1',
            MacExplorerFolderServices='public-folders-service-v1',NSServices=folder_service_descriptor('Traverse'))
        def accepted(value,channel='developer-id'):
            return next(x['passed'] for x in preflight.info_checks(value,'com.respawnstudios.traverse',channel)
                if x['id']=='folder_service_boundary')
        self.assertTrue(accepted(info))
        self.assertFalse(accepted(info,'app-store'))
        for change in [dict(NSRestricted=False),dict(NSSendFileTypes=['public.item']),dict(NSSendTypes=['public.utf8-plain-text'])]:
            modified=dict(info);modified['NSServices']=[dict(info['NSServices'][0],**change)]
            self.assertFalse(accepted(modified))
        self.assertFalse(accepted(dict(info,NSServices=info['NSServices']*2)))

    def test_installer_exception_has_exact_two_names_only_in_selected_composition(self):
        parent={k:True for k in preflight.PARENT_RIGHTS}
        parent[preflight.UPDATER_MACH_RIGHT]=['com.respawnstudios.traverse-spks','com.respawnstudios.traverse-spki']
        self.assertTrue(all(x['passed']for x in preflight.entitlement_checks(parent,{},True,'com.respawnstudios.traverse')))
        self.assertFalse(all(x['passed']for x in preflight.entitlement_checks(parent,{})))
        for names in [[],['*'],['com.other-spks','com.other-spki'],
            ['com.respawnstudios.traverse-spks','com.respawnstudios.traverse-spki','extra']]:
            changed=dict(parent);changed[preflight.UPDATER_MACH_RIGHT]=names
            self.assertFalse(all(x['passed']for x in preflight.entitlement_checks(changed,{},True,'com.respawnstudios.traverse')))

    def test_apple_edition_refuses_even_hidden_update_configuration(self):
        for info in [dict(SUFeedURL='https://example.com'),dict(TraversePrivateUpdaterVersion='2.10.0'),dict(SUPublicEDKey='public')]:
            checks=preflight.info_checks(info,'com.respawnstudios.traverse','app-store')
            self.assertFalse(next(x['passed']for x in checks if x['id']=='updater_edition_boundary'))
        checks=preflight.info_checks(dict(TraversePrivateUpdaterVersion='wrong'),'com.respawnstudios.traverse','developer-id')
        self.assertFalse(next(x['passed']for x in checks if x['id']=='updater_edition_boundary'))
