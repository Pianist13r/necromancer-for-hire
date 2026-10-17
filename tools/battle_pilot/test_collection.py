"""Data-only collector/feedback and workload integration proofs; no live services."""
from argparse import Namespace
import copy
from datetime import datetime, timedelta, timezone
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE));sys.path.insert(0,str(HERE.parent/'night_pilot'))
import collect
import feedback
import run_night as night
import run_cycles as cycles
runner=night.battle_module('runner')
schema=feedback.schema
PROPOSAL={'version':1,'hypothesis':'Guard availability may change paired survival.',
          'map':'fork','difficulty':'normal','candidate':{'bot':'hold','profile':'base'}}


def reports(base,previous=None,proposal=None,seeds=None):
    previous=previous or feedback.empty();proposal=proposal or PROPOSAL
    collection=base/'collection';replay=base/'replay'
    collection.mkdir(parents=True);replay.mkdir()
    q=schema.make_queue(proposal,seeds if seeds is not None else [101,102])
    night._save(collection/'queue.json',q)
    c={'repo':str(base/'repo'),'workload':'battle','collection_success':True,'worker_runs':1,
       'round_offset':previous['round_offset'],'queued':len(q['cases']),
       'queue_sha256':feedback.digest(collection/'queue.json'),'manifest_errors':{},
       'unchanged':{'runtime':True,'owner':True}}
    night._save(collection/'collection-summary.json',c)
    records=[]
    for i,case in enumerate(q['cases']):
        directory=replay/'cases'/f'{i:03}';directory.mkdir(parents=True)
        terminal={key:case[key] for key in ('map','bot','seed','difficulty')}
        terminal.update(result='victory' if i%2 else 'defeat',t=100+i,hp=20+i,army=3,wave=2,
                        kills=4,lost=2,eco={'mana_min':10+i,'souls_spent':4+i})
        text=json.dumps({'t':1})+'\n'+json.dumps(terminal)+'\n'
        (directory/'engine.log').write_text(text,encoding='utf-8')
        r=runner.classify_log(case,text,0);r.pop('trace')
        r.update(index=i,case=case,case_sha256=q['case_sha256'][i],
                 raw_log={'sha256':feedback.digest(directory/'engine.log')},
                 command=runner.build_command(case,Path(c['repo'])),exit_code=0,accepted=True,
                 death_proof={'owned_processes_dead':True})
        night._save(directory/'result.json',r);records.append(r)
    r={'workload':'battle','replay_acceptance':True,'replay_complete':True,
       'queue_replayed':len(records),'model_runs':0,'engine_runs':len(records),
       'owned_processes_dead':True,'manifest_errors':{},'unchanged':{'runtime':True,'owner':True},
       'queue':str(collection/'queue.json'),'queue_sha256':feedback.digest(collection/'queue.json'),
       'case_sha256':q['case_sha256'],'records':records,'paired_stats':runner.paired_statistics(q,records)}
    night._save(replay/'summary.json',r)
    return collection/'collection-summary.json',replay/'summary.json'


class BattleTests(unittest.TestCase):
    def test_fresh_run_carries_verified_history_without_replaying_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp);repo=base/'repo';repo.mkdir()
            seeds=list(range(101,111))
            c,r=reports(base/'old',seeds=seeds)
            previous=feedback.advance(feedback.empty(),c,r)
            initial=base/'old-context.json';night._save(initial,previous)
            old_hashes={str(p):feedback.digest(p) for p in (base/'old').rglob('*') if p.is_file()}
            options=Namespace(repo=repo,out=base/'new',workload='battle',seed=101,
                batch_rounds=1,round_limit=2,cycle_limit=2,collect_minutes=15,replay_minutes=15,
                replay_workers=20,deadline=datetime.now(timezone.utc)+timedelta(hours=4),
                server_exe=base/'server',model_file=base/'model',chat_template=base/'template',
                resume=False,initial_context=initial)
            calls=[]
            def launch(command,stage,*rest):
                ctx=feedback.load(Path(command[command.index('--cycle-context')+1]))
                calls.append(ctx['round_offset'])
                proposal=PROPOSAL|{'candidate':{'bot':'release','profile':'base'}}
                newc,newr=reports(stage,ctx,proposal,seeds=seeds)
                for name in ('proposal.json','request.json','before.json','after.json'):
                    night._save(newc.parent/name,{})
                (newc.parent/'response.bin').write_bytes(b'raw')
                night._save(newr.parent/'before.json',{});night._save(newr.parent/'after.json',{})
                night._save(stage/'night-status.json',{'server_stop':{'dead':True}})
                return 0
            with patch.object(cycles,'code_guard',return_value={'source':'sha'}), \
                 patch.object(cycles,'artifact_manifest',return_value={}), \
                 patch.object(cycles,'identity',return_value={'pid':1,'create_time':0}), \
                 patch.object(night,'_same_process',return_value=False):
                self.assertEqual(cycles.run(options,launch),0)
                self.assertEqual(calls,[1])
                report=night._read(options.out/'cycle-status.json')
                self.assertEqual(report['committed_round_offset'],2)
                self.assertEqual(report['cycles_finished'],1)
                self.assertEqual(report['config']['initial_context']['sha256'],feedback.digest(initial))
                options.resume=True
                self.assertEqual(cycles.run(options,launch),0)
                self.assertEqual(calls,[1])
            self.assertEqual(old_hashes,{str(p):feedback.digest(p) for p in (base/'old').rglob('*') if p.is_file()})

    def test_http_documented_schema_and_normal_completion(self):
        class Response:
            def __enter__(self):return self
            def __exit__(self,*a):pass
            def read(self,*a):return json.dumps({'choices':[{'finish_reason':'stop',
                'message':{'content':json.dumps(PROPOSAL)}}]}).encode()
        with tempfile.TemporaryDirectory() as tmp,patch.object(collect,'urlopen',return_value=Response()) as post:
            out=Path(tmp)
            self.assertEqual(collect.request_proposal('http://127.0.0.1:8081','local',{},out,10),PROPOSAL)
            payload=night._read(out/'request.json')
            self.assertEqual(payload['max_tokens'],4096)
            self.assertEqual(set(payload['response_format']),{'type','json_schema'})
            nested=payload['response_format']['json_schema']
            self.assertEqual(nested['name'],'paired_battle');self.assertIs(nested['strict'],True)
            self.assertEqual(set(nested['schema']['required']),set(PROPOSAL))
            prompt=payload['messages'][0]['content']
            self.assertIn('five top-level keys: version, hypothesis, map, difficulty, candidate',prompt)
            self.assertIn('version must be the integer 1',prompt)
            self.assertIn('Do not output control, seeds',prompt)
            self.assertIn(json.dumps(PROPOSAL,separators=(',',':')).split('"hypothesis"')[0],prompt)
            self.assertEqual(post.call_count,1)
            with self.assertRaises(ValueError):collect.request_proposal('http://example.com','local',{},out,10)

    def test_truncated_response_is_retained_not_salvaged(self):
        class Response:
            def __enter__(self):return self
            def __exit__(self,*a):pass
            def read(self,*a):return json.dumps({'choices':[{'finish_reason':'length',
                'message':{'content':json.dumps(PROPOSAL)}}]}).encode()
        with tempfile.TemporaryDirectory() as tmp,patch.object(collect,'urlopen',return_value=Response()):
            out=Path(tmp)
            with self.assertRaisesRegex(ValueError,'finish'):collect.request_proposal('http://127.0.0.1:8081','local',{},out,10)
            self.assertTrue((out/'response.bin').is_file())
            self.assertFalse((out/'queue.json').exists())

    def test_unconstrained_schema_failure_keeps_raw_without_rescue(self):
        invalid={k:v for k,v in PROPOSAL.items() if k!='version'}
        invalid.update(control={'bot':'selective','profile':'base'},seeds=list(range(101,111)))
        raw=json.dumps({'choices':[{'finish_reason':'stop','message':{'content':json.dumps(invalid)}}]}).encode()
        class Response:
            def __enter__(self):return self
            def __exit__(self,*a):pass
            def read(self,*a):return raw
        with tempfile.TemporaryDirectory() as tmp,patch.object(collect,'urlopen',return_value=Response()) as post:
            out=Path(tmp)
            with self.assertRaises(ValueError):collect.request_proposal('http://127.0.0.1:8081','local',{},out,10)
            self.assertEqual((out/'response.bin').read_bytes(),raw)
            self.assertFalse((out/'queue.json').exists());self.assertEqual(post.call_count,1)

    def test_feedback_uses_raw_metrics_economy_and_all_history(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp);c,r=reports(base/'one')
            first=feedback.advance(feedback.empty(),c,r)
            pair=first['prior_battle']['pairs'][0]
            self.assertEqual(pair['delta']['eco']['mana_min'],1)
            next_proposal=PROPOSAL|{'candidate':{'bot':'release','profile':'mid'}}
            c2,r2=reports(base/'two',first,next_proposal)
            value=feedback.advance(first,c2,r2)
            p=base/'context.json';night._save(p,value)
            self.assertEqual(feedback.load(p),value)
            self.assertEqual(len(feedback.tested_configs(value)),2)
            history=feedback.history(feedback.load(p))
            self.assertEqual(len(history['rows']),2)
            self.assertEqual(history['rows'][0][-1][3],[2,1.0])
            self.assertEqual(history['rows'][1][3],'mid')
            self.assertNotIn('values',json.dumps(history))
            details,outcome=collect.observed_feedback(feedback.load(p)['prior_battle'],history)
            self.assertEqual(outcome['pairs'],2)
            self.assertEqual(outcome['paired_win_counts'],{'both_win':0,'control_only':0,'candidate_only':2,'both_lose':0})
            self.assertEqual(outcome['control_wins'],0);self.assertEqual(outcome['candidate_wins'],2)
            self.assertNotIn('hypothesis',details['proposal'])
            c3,r3=reports(base/'three',value,next_proposal)
            with self.assertRaisesRegex(ValueError,'duplicate'):feedback.advance(value,c3,r3)
            (r.parent/'cases/000/engine.log').write_text('tampered')
            with self.assertRaises(ValueError):feedback.load(p)

    def test_observation_report_separates_prior_facts_from_new_result_and_prose(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp);c,r=reports(base/'old')
            before=feedback.advance(feedback.empty(),c,r)
            proposal=PROPOSAL|{'candidate':{'bot':'release','profile':'base'},
                'hypothesis':'Candidate lost fewer units in the prior comparison.'}
            c2,r2=reports(base/'new',before,proposal)
            after=feedback.advance(before,c2,r2)
            report=feedback.observation_report(before,after,'model')
            prior=report['observed_before_proposal']
            self.assertEqual(prior['paired_win_counts'],
                {'both_win':0,'control_only':0,'candidate_only':2,'both_lose':0})
            self.assertEqual((prior['control_wins'],prior['candidate_wins']),(0,2))
            self.assertEqual(prior['metric_deltas']['lost'],{'n':2,'mean':0.0})
            self.assertEqual(report['observed_after_replay']['paired_win_counts'],
                night._read(r2)['paired_stats']['paired_win_counts'])
            self.assertEqual(report['proposal_hypothesis']['text'],proposal['hypothesis'])
            self.assertEqual(report['proposal_hypothesis']['verification_status'],'unverified_free_text')
            self.assertEqual(report['proposal_hypothesis']['selection_source'],'model')
            self.assertEqual(report['delta_direction'],'candidate minus control')
            self.assertNotIn('truth',report['proposal_hypothesis'])
            changed=copy.deepcopy(before)
            for pair in changed['prior_battle']['pairs']:
                pair['delta']['lost']=183.2
            signed=feedback.observation_report(changed,after,'model')['observed_before_proposal']
            self.assertEqual(signed['metric_deltas']['lost'],{'n':2,'mean':183.2})
            self.assertEqual(signed['lost_mean_direction'],'candidate_lost_more')
            empty_report=feedback.observation_report(feedback.empty(),before,'fallback')
            self.assertIsNone(empty_report['observed_before_proposal'])
            self.assertEqual(empty_report['proposal_hypothesis']['selection_source'],'fallback')

    def test_foreign_queue_mutated_stats_and_bad_exit_refused(self):
        for kind in ('queue_path','queue_sha','cases','statistics','exit','accepted','death'):
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as tmp:
                c,r=reports(Path(tmp)/'one');value=night._read(r)
                if kind=='queue_path':value['queue']=str(Path(tmp)/'other.json')
                if kind=='queue_sha':value['queue_sha256']='0'*64
                if kind=='cases':value['case_sha256'][1]='0'*64
                if kind=='statistics':value['paired_stats']['pairs'][0]['delta']['hp']=999
                if kind in ('accepted','death'):
                    if kind=='accepted':value['records'][0]['accepted']=False
                    else:value['records'][0]['death_proof']['owned_processes_dead']=False
                    night._save(r.parent/'cases/000/result.json',value['records'][0])
                if kind=='exit':
                    value['records'][0]['exit_code']=1
                    night._save(r.parent/'cases/000/result.json',value['records'][0])
                night._save(r,value)
                with self.assertRaises(ValueError):feedback.advance(feedback.empty(),c,r)
            
    def test_another_valid_candidate_replay_same_seeds_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp);c,r=reports(base/'one')
            other=PROPOSAL|{'candidate':{'bot':'release','profile':'base'}}
            c2,r2=reports(base/'two',proposal=other)
            with self.assertRaisesRegex(ValueError,'different queue'):
                feedback.advance(feedback.empty(),c,r2)

    def test_two_cycles_model_request_units_fixed_seed_pool_and_resume(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp);repo=base/'repo';repo.mkdir()
            options=Namespace(repo=repo,out=base/'out',workload='battle',seed=101,
                batch_rounds=1,round_limit=2,cycle_limit=2,collect_minutes=15,replay_minutes=15,
                replay_workers=20,deadline=datetime.now(timezone.utc)+timedelta(hours=4),
                server_exe=base/'server',model_file=base/'model',chat_template=base/'template',resume=False)
            observed=[]
            def launch(command,stage,*rest):
                self.assertIn('--workload',command);self.assertEqual(command[command.index('--seed')+1],'101')
                ctx=feedback.load(Path(command[command.index('--cycle-context')+1]))
                observed.append(ctx['round_offset'])
                proposal=PROPOSAL|{'candidate':{'bot':'hold' if ctx['round_offset']==0 else 'release','profile':'base'}}
                c,r=reports(stage,ctx,proposal)
                # The dispatcher retains all proposal/request/raw receipts in the seal.
                for name in ('proposal.json','request.json','before.json','after.json'):night._save(c.parent/name,{})
                (c.parent/'response.bin').write_bytes(b'raw')
                night._save(r.parent/'before.json',{})
                night._save(r.parent/'after.json',{})
                night._save(stage/'night-status.json',{'server_stop':{'dead':True}})
                return 0
            with patch.object(cycles,'code_guard',return_value={'source':'sha'}),\
                 patch.object(cycles,'artifact_manifest',return_value={}),patch.object(cycles,'identity',return_value={'pid':1,'create_time':0}),\
                 patch.object(night,'_same_process',return_value=False):
                self.assertEqual(cycles.run(options,launch),0)
                state=night._read(options.out/'cycle-status.json')
                self.assertEqual((state['rounds_attempted'],state['cycles_finished']),(2,2))
                for batch in state['batches']:
                    report_path=Path(batch['observation_report_path'])
                    self.assertEqual(report_path,Path(batch['path'])/'observation-report.json')
                    self.assertEqual(night._read(report_path)['proposal_hypothesis']['verification_status'],
                        'unverified_free_text')
                    self.assertIn(str(report_path.resolve()),night._read(Path(batch['path'])/'seal.json'))
                options.resume=True
                self.assertEqual(cycles.run(options,launch),0)
                self.assertEqual(observed,[0,1])
                Path(state['batches'][0]['observation_report_path']).write_text('{}',encoding='utf-8')
                self.assertEqual(cycles.run(options,launch),1)
                self.assertIn('completed batch data changed',
                    night._read(options.out/'cycle-status.json')['error'])
            command=night.replay_command(repo,base/'out',base/'collection',20,15,101,1,20,'battle')
            self.assertEqual(command[3],str(repo/'tools/battle_pilot/runner.py'))
            self.assertNotIn('--round-offset',command)
            self.assertEqual(command[command.index('--queue')+1],str(base/'collection/queue.json'))

    def test_artifact_stat_change_blocks_next_batch(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'model';p.write_bytes(b'original')
            values={str(p):{'size':p.stat().st_size,'mtime_ns':p.stat().st_mtime_ns}}
            self.assertTrue(cycles.artifact_stats_unchanged(values))
            p.write_bytes(b'changed')
            self.assertFalse(cycles.artifact_stats_unchanged(values))

if __name__=='__main__':unittest.main()
