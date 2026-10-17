"""Data-only paired battle proposals; every CLI option is chosen by trusted code."""
from __future__ import annotations

import hashlib
import json

MAPS = frozenset({'wasteland','fork','bridge','maze','swamp','archive','gatehouse','boss'})
BOTS = frozenset({'hold','release','selective','button','melt'})
PROFILES = frozenset({'base','novice','mid'})
DIFFICULTIES = frozenset({'intern','normal','hell'})
CONTROL = {'bot':'selective','profile':'base'}
MAX_SEED = 2147483647
CASE_KEYS = frozenset({'version','map','bot','profile','difficulty','seed'})
PROPOSAL_KEYS = frozenset({'version','hypothesis','map','difficulty','candidate'})
QUEUE_KEYS = frozenset({'version','kind','proposal','control','seeds','cases','proposal_sha256','case_sha256','coordinator'})


def _object(value, keys, label):
    if type(value) is not dict or set(value) != set(keys):
        raise ValueError(f'{label} must contain exactly {sorted(keys)}')
    return value


def _version(value):
    if type(value) is not int or value != 1:
        raise ValueError('version must be integer1')


def _enum(value, choices, label):
    if type(value) is not str or value not in choices:
        raise ValueError(f'{label} must be one of {sorted(choices)}')
    return value


def _seed(value):
    if type(value) is not int or not 0 <= value <= MAX_SEED:
        raise ValueError(f'seed must be integer0..{MAX_SEED}')
    return value


def fingerprint(value):
    data = json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode('utf-8')
    return hashlib.sha256(data).hexdigest()


def validate_case(value):
    _object(value, CASE_KEYS, 'case')
    _version(value['version'])
    return {'version':1, 'map':_enum(value['map'],MAPS,'map'), 'bot':_enum(value['bot'],BOTS,'bot'),
            'profile':_enum(value['profile'],PROFILES,'profile'),
            'difficulty':_enum(value['difficulty'],DIFFICULTIES,'difficulty'), 'seed':_seed(value['seed'])}


def case_fingerprint(value):
    return fingerprint(validate_case(value))


def validate_proposal(value):
    _object(value, PROPOSAL_KEYS, 'proposal')
    _version(value['version'])
    candidate = _object(value['candidate'], {'bot','profile'}, 'candidate')
    candidate = {'bot':_enum(candidate['bot'],BOTS,'bot'), 'profile':_enum(candidate['profile'],PROFILES,'profile')}
    if candidate == CONTROL:
        raise ValueError('candidate must differ from selective/base control')
    hypothesis = value['hypothesis']
    if type(hypothesis) is not str or not hypothesis.strip() or len(hypothesis) > 1000:
        raise ValueError('hypothesis must be a nonempty string of at most1000characters')
    return {'version':1,'hypothesis':hypothesis.strip(), 'map':_enum(value['map'],MAPS,'map'),
            'difficulty':_enum(value['difficulty'],DIFFICULTIES,'difficulty'), 'candidate':candidate}


def proposal_fingerprint(value):
    return fingerprint(validate_proposal(value))


def make_queue(proposal, seeds):
    proposal = validate_proposal(proposal)
    if type(seeds) is not list or not 1 <= len(seeds) <= 10:
        raise ValueError('coordinator seeds must be a list of1..10 paired seeds')
    seeds = [_seed(seed) for seed in seeds]
    if len(set(seeds)) != len(seeds):
        raise ValueError('paired seeds must be unique')
    cases = []
    for seed in seeds:
        for policy in (CONTROL,proposal['candidate']):
            cases.append(validate_case({'version':1,'map':proposal['map'],'difficulty':proposal['difficulty'],
                                        'seed':seed, **policy}))
    return {'version':1,'kind':'paired_battles','proposal':proposal,'control':dict(CONTROL), 'seeds':seeds,
            'cases':cases,'proposal_sha256':proposal_fingerprint(proposal),
            'case_sha256':[case_fingerprint(case) for case in cases],
            'coordinator':{'seed_authority':'coordinator','pairs':len(seeds)}}


def validate_queue(value):
    _object(value, QUEUE_KEYS, 'queue')
    _version(value['version'])
    if value['kind'] != 'paired_battles':
        raise ValueError('queue kind must be paired_battles')
    _object(value['control'], {'bot','profile'}, 'control')
    _object(value['coordinator'], {'seed_authority','pairs'}, 'coordinator')
    if type(value['coordinator']['pairs']) is not int:
        raise ValueError('coordinator pair count must be an integer')
    if type(value['cases']) is not list or type(value['case_sha256']) is not list:
        raise ValueError('cases and hashes must be lists')
    cases = [validate_case(case) for case in value['cases']]
    expected = make_queue(value['proposal'],value['seeds'])
    if cases != expected['cases'] or value != expected:
        raise ValueError('queue differs from derived paired cases/control/hash manifest')
    return expected


def comparison_fingerprint(proposal, seeds):
    queue = make_queue(proposal,seeds)
    return fingerprint({'map':queue['proposal']['map'],'difficulty':queue['proposal']['difficulty'],
                        'control':queue['control'],'candidate':queue['proposal']['candidate'],'seeds':queue['seeds']})
