"""Recognize only exact repaired production or earlier qualified image roots."""
import json
from download_candidate import current as original
def current(root):
    if json.loads((root/'reservation.json').read_bytes()).get('action')=='smb-selected-download-compatibility-build-production':
        from download_compatibility import current as compatible
        value,binary=compatible(root,'production')
        # Normalize the common image facts, without amending its immutable
        # build receipt. This exact action always builds the non-test binary.
        return dict(value,testImage=False,functionalOnly=False,optimizationLevel=3),binary
    return original(root)
