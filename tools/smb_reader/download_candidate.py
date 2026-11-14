"""Exact functional or production-profile qualification image authority."""
import json
from download_worker_build import current as functional
def current(root):
    action=json.loads((root/'reservation.json').read_bytes()).get('action')
    if action=='smb-selected-download-production-build':
        from download_production_build import current as production
        return production(root)
    return functional(root)
