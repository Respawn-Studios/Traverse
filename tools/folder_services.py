"""The two exact folder-only Services declarations used by product packages."""

def descriptor(product):
    if product not in ('Traverse', 'Traverse Preview'):
        raise ValueError('Unknown folder service product')
    return [dict(NSMenuItem={'default': 'Open in '+product},
        NSMessage='openFoldersInTraverse', NSPortName=product,
        NSSendFileTypes=['public.folder'], NSRequiredContext={}, NSRestricted=True,
        NSServiceDescription='Browse selected folders in '+product+'.')]


def valid(fields, *, preview=False):
    marker = 'MacExplorerPreviewFolderServices' if preview else 'MacExplorerFolderServices'
    other = 'MacExplorerFolderServices' if preview else 'MacExplorerPreviewFolderServices'
    if other in fields:
        return False
    if marker not in fields:
        return 'NSServices' not in fields
    return fields.get(marker) == 'public-folders-service-v1' \
        and fields.get('NSServices') == descriptor('Traverse Preview' if preview else 'Traverse') \
        and fields['NSServices'][0].get('NSRestricted') is True
