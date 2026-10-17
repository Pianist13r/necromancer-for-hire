"""Rebuild bounded battle feedback from SHA-bound queues and actual paired statistics."""
from __future__ import annotations
import hashlib
import json
import math
from pathlib import Path
import statistics

import importlib.util

def module(name, path):
    spec=importlib.util.spec_from_file_location(name,path)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value)
    return value

schema=module('feedback_battle_schema',Path(__file__).with_name('schema.py'))

MAX_BYTES = 512_000
METRICS = {'hp','t','kills','lost','cauldron_dmg','souls','mana','waves','contracts',
           'army','avg_army','idle_unit_seconds','army_cap','releases_manual','refreshes','buildings_built','casts_q','casts_w','casts_e'}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def empty():
    return {'protocol':1,'workload':'battle','round_offset':0,
            'comparison_fingerprints':[],'provenance':[],'prior_battle':None}


ECO = {'souls_end','souls_spent','souls_max','souls_buildings','all_maxed_t',
       'souls_at_maxed','souls_rush','rush_units','mana_abilities','mana_min',
       'mana_zero_n','mana_cap_share','mana_below_half_share'}

def numeric(values, allowed=METRICS):
    if type(values) is not dict:
        raise ValueError('battle metrics must be an object')
    result = {}
    for key, value in values.items():
        if key in allowed and type(value) in (int,float) and math.isfinite(value):
            result[key] = value
    if allowed is METRICS and type(values.get('eco')) is dict:
        result['eco']=numeric(values['eco'],ECO)
    return result


def tested_configs(value):
    result=[]
    for item in value['provenance'][2::3]:
        q=schema.validate_queue(json.loads(Path(item['path']).read_text(encoding='utf-8')))
        result.append({key:q['proposal'][key] for key in ('map','difficulty','candidate')} |
                      {'control':q['control'],'seeds':q['seeds']})
    return result


def history(value):
    """Bounded table: all outcomes, recent numeric detail, no pooled estimates."""
    result={'columns':['map','difficulty','bot','profile','pairs','paired_wins','delta_means'],
            'paired_wins_order':['both_win','control_only','candidate_only','both_lose'],
            'delta_order':['hp','lost','t','souls_spent','mana_abilities'],
            'delta_format':'[n,mean candidate minus control], four significant digits; null detail is omitted, not zero',
            'rows':[],'numeric_rows_omitted':0}
    for i in range(0,len(value['provenance']),3):
        replay=json.loads(Path(value['provenance'][i+1]['path']).read_text(encoding='utf-8'))
        queue=schema.validate_queue(json.loads(Path(value['provenance'][i+2]['path']).read_text(encoding='utf-8')))
        stats=replay['paired_stats']
        deltas=[]
        for key in result['delta_order']:
            if key in ('hp','lost','t'):
                summary=stats['metric_deltas'].get(key)
                deltas.append([summary['n'],float(format(summary['mean'],'.4g'))] if summary else None)
            else:
                values=[]
                for a,b in zip(replay['records'][::2],replay['records'][1::2]):
                    a=numeric(a['terminal'].get('eco',{}),ECO)
                    b=numeric(b['terminal'].get('eco',{}),ECO)
                    if key in a and key in b:values.append(b[key]-a[key])
                deltas.append([len(values),float(format(sum(values)/len(values),'.4g'))] if values else None)
        p=queue['proposal']
        result['rows'].append([p['map'],p['difficulty'],p['candidate']['bot'],p['candidate']['profile'],
            stats['complete_pairs'],[stats['paired_win_counts'][key] for key in result['paired_wins_order']],deltas])
    # At the maximum336 comparisons retain every configuration and outcome count.
    # Drop oldest numeric detail only; full values remain in verified raw receipts.
    for row in result['rows']:
        if len(json.dumps(result,separators=(',',':'),allow_nan=False).encode('utf-8'))<=32000:break
        row[-1]=None;result['numeric_rows_omitted']+=1
    return result


def _observed_battle(battle):
    if battle is None:
        return None
    pairs=battle['pairs']
    counts=dict.fromkeys(('both_win','control_only','candidate_only','both_lose'),0)
    for pair in pairs:
        control=pair['control']['result']=='victory'
        candidate=pair['candidate']['result']=='victory'
        counts['both_win' if control and candidate else
               'control_only' if control else 'candidate_only' if candidate else 'both_lose']+=1
    deltas={}
    for key in ('hp','lost'):
        values=[pair['delta'][key] for pair in pairs if key in pair['delta']]
        deltas[key]={'n':len(values),'mean':float(format(statistics.mean(values),'.4g'))} if values else None
    p=battle['proposal']
    return {'map':p['map'],'difficulty':p['difficulty'],'control':battle['control'],
        'candidate':p['candidate'],'pairs':len(pairs),'paired_win_counts':counts,
        'control_wins':counts['both_win']+counts['control_only'],
        'candidate_wins':counts['both_win']+counts['candidate_only'],
        'metric_deltas':deltas,'lost_mean_direction':_lost_direction(deltas['lost'])}


def _lost_direction(delta):
    if delta is None:return 'unavailable'
    if delta['mean']>0:return 'candidate_lost_more'
    if delta['mean']<0:return 'candidate_lost_fewer'
    return 'equal_mean_losses'


def observation_report(before, after, selection_source):
    """Display verified observations alongside, not inside, unverified proposal text.

    Call only after verified context load and accepted replay/feedback advancement.
    The first observation predates the proposal; the second follows its replay.
    """
    current=after['prior_battle']
    proposal=current['proposal']
    return {'version':1,'delta_direction':'candidate minus control',
        'metric_mean_format':'four significant digits',
        'observed_before_proposal':_observed_battle(before['prior_battle']),
        'observed_after_replay':_observed_battle(current),
        'proposal_hypothesis':{'text':proposal['hypothesis'],
            'verification_status':'unverified_free_text',
            'selection_source':selection_source or 'legacy_unspecified'}}


def verify_attempts(collection, directory, queue):
    """Legacy single-request receipts remain valid; new retries must be fully bound."""
    if 'attempt_protocol' not in collection:
        if collection.get('worker_runs')!=1:raise ValueError('invalid legacy model count')
        return
    count=collection.get('model_request_runs')
    attempts=collection.get('attempts')
    if (collection['attempt_protocol']!=1 or type(count) is not int or not 1<=count<=3
            or collection.get('worker_runs')!=count or collection.get('experiment_runs')!=1
            or type(attempts) is not list or len(attempts)!=count):
        raise ValueError('invalid audited model attempt counts')
    receipts=collection.get('attempt_receipts',{})
    if any(p.is_symlink() for p in directory.rglob('*')):raise ValueError('linked model attempt artifact')
    actual={str(p.relative_to(directory)):digest(p) for p in directory.rglob('*') if p.is_file()
            and (p.is_relative_to(directory/'attempts') or p.name=='fallback.json')}
    if not receipts or receipts!=actual:raise ValueError('model attempt receipts changed')
    for i,item in enumerate(attempts,1):
        folder=directory/'attempts'/f'{i:03}'
        if item.get('index')!=i or not (folder/'request.json').is_file():
            raise ValueError('model attempt request missing')
        if item.get('status')=='rejected':
            expected={'error':item['error']}
            if item.get('reason')=='request_wall_timeout':
                if i!=count or item.get('response_incomplete') is not True:raise ValueError('invalid incomplete request')
                expected.update(response_incomplete=True,reason='request_wall_timeout')
            if json.loads((folder/'error.json').read_text(encoding='utf-8'))!=expected:
                raise ValueError('model rejection changed')
        elif item.get('status')!='accepted' or i!=count:raise ValueError('invalid model attempt status')
    source=collection.get('selection_source')
    if source=='model':
        if (attempts[-1]['status']!='accepted' or collection.get('selected_attempt')!=count
                or collection.get('generator_success') is not True):raise ValueError('invalid model selection')
        selected=json.loads((directory/'attempts'/f'{count:03}'/'proposal.json').read_text(encoding='utf-8'))
        raw=json.loads((directory/'attempts'/f'{count:03}'/'response.bin').read_bytes())['choices'][0]
        if raw.get('finish_reason')!='stop' or schema.validate_proposal(json.loads(raw['message']['content']))!=selected:
            raise ValueError('accepted model raw response differs from selection')
    elif source=='fallback':
        timed_out=(collection.get('fallback_reason')=='request_wall_timeout'
                   and attempts[-1].get('reason')=='request_wall_timeout')
        if ((not timed_out and (count!=3 or collection.get('fallback_reason')!='bounded_rejections'))
                or any(a['status']!='rejected' for a in attempts)
                or collection.get('generator_success') is not False or collection.get('degraded') is not True):
            raise ValueError('invalid fallback selection')
        fallback=json.loads((directory/'fallback.json').read_text(encoding='utf-8'))
        selected=fallback['proposal']
        if (fallback.get('source')!='fallback' or fallback.get('reason')!=collection.get('fallback_reason')
                or fallback.get('comparison_sha256')!=
                schema.comparison_fingerprint(selected,queue['seeds'])):raise ValueError('fallback receipt changed')
    else:raise ValueError('unknown proposal source')
    if selected!=queue['proposal']:raise ValueError('selected proposal differs from queue')


def advance(previous, collection_path, replay_path):
    c = json.loads(Path(collection_path).read_text(encoding='utf-8'))
    r = json.loads(Path(replay_path).read_text(encoding='utf-8'))
    queue_path = Path(collection_path).parent/'queue.json'
    q = schema.validate_queue(json.loads(queue_path.read_text(encoding='utf-8')))
    if (c.get('workload') != 'battle' or c.get('collection_success') is not True
            or c.get('round_offset') != previous['round_offset']
            or c.get('queued') != len(q['cases']) or c.get('queue_sha256') != digest(queue_path)
            or c.get('manifest_errors') != {} or c.get('unchanged') != {'runtime':True,'owner':True}):
        raise ValueError('battle collection provenance/integrity unproven')
    verify_attempts(c,queue_path.parent,q)
    if (r.get('replay_acceptance') is not True or r.get('replay_complete') is not True
            or r.get('queue_replayed') != len(q['cases']) or r.get('model_runs') != 0
            or r.get('owned_processes_dead') is not True or r.get('manifest_errors') != {}
            or not r.get('unchanged') or not all(v is True for v in r['unchanged'].values())):
        raise ValueError('battle replay integrity/full terminal completion unproven')
    if (r.get('workload')!='battle' or Path(r.get('queue','')).resolve()!=queue_path.resolve()
            or r.get('queue_sha256')!=digest(queue_path) or r.get('case_sha256')!=q['case_sha256']):
        raise ValueError('replay is bound to a different queue')
    runner=module('feedback_battle_runner',Path(__file__).with_name('runner.py'))
    records=r.get('records',[])
    if len(records)!=len(q['cases']): raise ValueError('raw battle records incomplete')
    actual=[]
    for index,case in enumerate(q['cases']):
        path=Path(replay_path).parent/'cases'/f'{index:03}'/'result.json'
        record=json.loads(path.read_text(encoding='utf-8'))
        log=path.with_name('engine.log')
        if (record!=records[index] or record.get('index')!=index or record.get('case')!=case
                or record.get('case_sha256')!=q['case_sha256'][index]
                or record.get('raw_log',{}).get('sha256')!=digest(log)
                or record.get('command')!=runner.build_command(case,Path(c['repo']))
                or type(record.get('exit_code')) is not int or record['exit_code']!=0
                or record.get('accepted') is not True
                or record.get('death_proof',{}).get('owned_processes_dead') is not True):
            raise ValueError('raw battle execution identity changed')
        classified=runner.classify_log(case,log.read_text(encoding='utf-8',errors='replace'),record['exit_code'])
        if (classified['classification'] not in ('victory','defeat') or
                record.get('terminal')!=classified['terminal'] or
                record.get('classification')!=classified['classification']):
            raise ValueError('raw terminal result differs from execution report')
        actual.append(record)
    if r.get('paired_stats')!=runner.paired_statistics(q,actual):
        raise ValueError('paired statistics differ from raw executions')
    pairs=[]
    raw_receipts=[]
    for index,seed in enumerate(q['seeds']):
        pair={'seed':seed}
        metrics=[]
        for offset,name,policy in ((0,'control',q['control']),(1,'candidate',q['proposal']['candidate'])):
            terminal=actual[index*2+offset]['terminal']
            values=numeric(terminal);metrics.append(values)
            pair[name]={'bot':policy['bot'],'profile':policy['profile'],
                        'result':terminal['result'],'metrics':values}
            directory=Path(replay_path).parent/'cases'/f'{index*2+offset:03}'
            raw_receipts += [{'path':str((directory/name).resolve()),'sha256':digest(directory/name)}
                             for name in ('result.json','engine.log')]
        pair['delta']={key:metrics[1][key]-metrics[0][key] for key in metrics[0].keys()&metrics[1].keys()
                       if key!='eco'}
        if 'eco' in metrics[0] and 'eco' in metrics[1]:
            pair['delta']['eco']={key:metrics[1]['eco'][key]-metrics[0]['eco'][key]
                                 for key in metrics[0]['eco'].keys()&metrics[1]['eco'].keys()}
        pairs.append(pair)
    key = schema.comparison_fingerprint(q['proposal'],q['seeds'])
    if key in previous['comparison_fingerprints']:
        raise ValueError('duplicate completed battle comparison')
    result = {'protocol':1,'workload':'battle','round_offset':previous['round_offset']+1,
        'comparison_fingerprints':previous['comparison_fingerprints']+[key],
        'provenance':previous['provenance']+[
            {'path':str(Path(p).resolve()),'sha256':digest(p)}
            for p in (collection_path,replay_path,queue_path)],
        'prior_battle':{'proposal':q['proposal'],'control':q['control'],'seeds':q['seeds'],
            'engine_runs':r['engine_runs'],'pairs':pairs,'raw_receipts':raw_receipts,
            'interpretation':'fixed training seeds and seeded initial conditions, not identical realized random draws; paired candidate intervention may change bot AND profile; '
                             'different maps/difficulties are separate experiments, no causal generalization'}}
    if len(json.dumps(result,ensure_ascii=False,indent=2).encode('utf-8')) > MAX_BYTES:
        raise ValueError('battle feedback byte limit exceeded')
    return result


def load(path):
    p = Path(path)
    if p.is_symlink() or p.stat().st_size > MAX_BYTES:
        raise ValueError('linked/oversized battle feedback')
    value = json.loads(p.read_text(encoding='utf-8'))
    if type(value) is not dict or set(value) != set(empty()):
        raise ValueError('invalid battle feedback schema')
    sources = value['provenance']
    capacity = len(schema.MAPS) * len(schema.DIFFICULTIES) * (len(schema.BOTS) * len(schema.PROFILES) - 1)
    if type(sources) is not list or len(sources)>capacity*3 or len(sources)%3:
        raise ValueError('invalid battle feedback provenance')
    rebuilt = empty()
    for source in sources:
        if type(source) is not dict or set(source) != {'path','sha256'}:
            raise ValueError('invalid battle source')
        source_path = Path(source['path'])
        if (not source_path.is_absolute() or source_path.is_symlink()
                or not source_path.is_file() or source_path.stat().st_size>4_000_000
                or digest(source_path)!=source['sha256']):
            raise ValueError('battle source missing or changed')
    for i in range(0,len(sources),3):
        rebuilt = advance(rebuilt,sources[i]['path'],sources[i+1]['path'])
        if sources[i+2]['path'] != str((Path(sources[i]['path']).parent/'queue.json').resolve()):
            raise ValueError('battle queue provenance path mismatch')
    for receipt in (rebuilt['prior_battle'] or {}).get('raw_receipts',[]):
        if digest(receipt['path'])!=receipt['sha256']: raise ValueError('raw execution changed')
    if value != rebuilt:
        raise ValueError('battle feedback differs from actual reports')
    return value
