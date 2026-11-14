"""Immutable release-case inputs. No signing, filesystem or account actions."""
import re

DIRECT_SHIPPING_PURPOSE = 'direct-shipping-v1'
RELEASE_PURPOSE_KEY = 'MacExplorerReleasePurpose'


def version_override(version=None, build=None):
    if version is None and build is None:
        return None
    if not isinstance(version, str) or not re.fullmatch(r'(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){2}', version):
        raise ValueError('An explicit three-component numeric candidate version is required')
    if not isinstance(build, str) or not re.fullmatch(r'[1-9][0-9]{0,9}', build) or int(build) > 2_147_483_647:
        raise ValueError('An explicit positive candidate build number is required')
    return dict(version=version, build=build)


def settings(override):
    if override is None:
        return []
    if not isinstance(override, dict) or set(override) != {'version', 'build'}:
        raise ValueError('Invalid candidate version fields')
    checked = version_override(override['version'], override['build'])
    return ['MARKETING_VERSION=' + checked['version'], 'CURRENT_PROJECT_VERSION=' + checked['build']]


def configuration(saved=None, *, channel=None, policy=None, version=None, build=None, local=False, shipping=False, private_updater=False, public_updater=False):
    if local and shipping:
        raise ValueError('Local review and shipping are distinct case purposes')
    requested = version_override(version, build)
    if saved is not None:
        if not isinstance(saved, dict):
            raise ValueError('Invalid release configuration')
        result = dict(saved)
        if channel is not None and channel != result.get('channel'):
            raise ValueError('A release case cannot switch distribution channels')
        if policy is not None and policy != result.get('accessPolicy', 'sandbox-selected-v1'):
            raise ValueError('A release case cannot switch access policies')
        if requested is not None and requested != result.get('versionOverride'):
            raise ValueError('A release case cannot switch version/build')
        if local and result.get('localReviewOnly') is not True:
            raise ValueError('An existing release case cannot become a local candidate')
        if shipping and result.get('shippingCandidate') is not True:
            raise ValueError('An existing case cannot become a shipping candidate')
        if private_updater and result.get('privateUpdater') is not True:
            raise ValueError('An existing release case cannot adopt an updater')
        if public_updater and result.get('publicUpdater') is not True:
            raise ValueError('An existing release case cannot adopt a public updater')
    else:
        result = dict(channel=channel or 'app-store', accessPolicy=policy or 'sandbox-selected-v1',
                      qualificationOnly=policy == 'local-user-v1' and not shipping)
        if requested is not None and not (local or shipping):
            raise ValueError('Version overrides require an explicit case purpose')
        if local or shipping:
            if requested is None:
                raise ValueError('Versioned candidates require both version and build')
            result.update(versionOverride=requested)
            if local: result['localReviewOnly'] = True
            else: result['shippingCandidate'] = True
        if private_updater: result['privateUpdater'] = True
        if public_updater: result['publicUpdater'] = True
        if shipping and policy == 'local-user-v1' and public_updater:
            result['releasePurpose'] = DIRECT_SHIPPING_PURPOSE
    selected = result.get('channel')
    access = result.get('accessPolicy', 'sandbox-selected-v1')
    if selected not in ('app-store', 'developer-id') or access not in ('sandbox-selected-v1', 'local-user-v1'):
        raise ValueError('Unknown release channel/access policy')
    if access == 'local-user-v1' and selected != 'developer-id':
        raise ValueError('Local-user qualification is Developer ID only')
    if type(result.get('privateUpdater',False))is not bool or (result.get('privateUpdater')is True \
        and (selected!='developer-id'or access!='sandbox-selected-v1')):
        raise ValueError('The private updater is direct-only and retains the sandbox policy')
    public = result.get('publicUpdater', False)
    direct_shipping = access == 'local-user-v1' and result.get('shippingCandidate') is True
    if direct_shipping:
        if selected != 'developer-id' or result.get('releasePurpose') != DIRECT_SHIPPING_PURPOSE \
                or result.get('qualificationOnly') is not False or public is not True \
                or result.get('privateUpdater') is True or 'localReviewOnly' in result:
            raise ValueError('Fresh local-user shipping requires its exact direct public purpose')
    elif 'releasePurpose' in result:
        raise ValueError('Only a fresh direct shipping case may carry release purpose')
    if type(public) is not bool or public and (result.get('privateUpdater') is True
            or selected != 'developer-id'
            or result.get('localReviewOnly') is not True and not direct_shipping):
        raise ValueError('The public updater requires a fresh Developer ID case with its exact purpose')
    if result.get('shippingCandidate') is True and (access != 'sandbox-selected-v1' and not direct_shipping
            or result.get('qualificationOnly') is True):
        raise ValueError('Shipping candidates require an admitted access policy and purpose')
    override = result.get('versionOverride')
    settings(override)
    purposes = [result.get('localReviewOnly') is True, result.get('shippingCandidate') is True]
    if override is not None and sum(purposes) != 1:
        raise ValueError('A versioned case must retain exactly one original purpose')
    if any(purposes) and override is None:
        raise ValueError('A versioned candidate lost its explicit version')
    return result


def admit_action(config, action):
    if config.get('localReviewOnly') is True and action not in ('prepare', 'archive', 'export'):
        raise ValueError('A local review candidate cannot be uploaded or notarized')
    if config.get('releasePurpose') == DIRECT_SHIPPING_PURPOSE \
            and action not in ('prepare', 'archive', 'export', 'notarize'):
        raise ValueError('Direct shipping uses only the Developer ID release actions')


def verify_observed(info, override, purpose=None):
    if override is not None:
        settings(override)
        if info.get('CFBundleShortVersionString') != override['version'] or info.get('CFBundleVersion') != override['build']:
            raise ValueError('Observed artifact version/build differs from its immutable request')
    if (purpose is None and RELEASE_PURPOSE_KEY in info) or (purpose is not None
            and info.get(RELEASE_PURPOSE_KEY) != purpose):
        raise ValueError('Observed artifact release purpose differs from its immutable request')


def shipping_metadata(saved, info, channel='developer-id'):
    """Fresh release authority only; never promotes a retained local case."""
    config=configuration(saved)
    if config.get('shippingCandidate') is not True or config.get('channel') != channel:
        raise ValueError('Exact fresh shipping case and channel required')
    admit_action(config,'notarize' if channel=='developer-id' else 'upload')
    verify_observed(info,config.get('versionOverride'),config.get('releasePurpose'))
    if info.get('CFBundleIdentifier') != 'com.respawnstudios.traverse' \
            or info.get('MacExplorerAccessPolicy') != config.get('accessPolicy','sandbox-selected-v1') \
            or info.get('MacExplorerDistributionChannel') != channel:
        raise ValueError('Shipping artifact identity/access policy differs')
    return config['versionOverride']['version'],config['versionOverride']['build']
