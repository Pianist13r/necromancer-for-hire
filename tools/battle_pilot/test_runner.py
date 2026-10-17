"""Raw classification, paired accounting and contained subprocess stubs; no engines/models."""
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('tested_battle_runner',Path(__file__).with_name('runner.py'))
runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
schema=runner.schema


def proposal():
    return {'version':1,'hypothesis':'Holding lines changes paired losses.','map':'fork',
            'difficulty':'normal','candidate':{'bot':'hold','profile':'base'}}


def log_for(case, result='victory'):
    trace={'t':2.0,'hp':100.0,'mana':80.0,'foes':1,'kills':0,'wave':1,'lost':0}
    terminal={'map':case['map'],'seed':case['seed'],'bot':case['bot'],'difficulty':case['difficulty'],
              'result':result,'t':200.0,'hp':100.0 if result=='victory' else 0.0,'army':5,'wave':5,'kills':10,'lost':3}
    return json.dumps(trace)+'\n'+json.dumps(terminal)+'\nERROR: 2 resources still in use at exit (run with --verbose for details).\n'


class ClassifierTests(unittest.TestCase):
    def setUp(self):self.case=schema.make_queue(proposal(),[101])['cases'][0]

    def test_defeat_is_valid_full_terminal_data(self):
        result=runner.classify_log(self.case,log_for(self.case,'defeat'),0)
        self.assertEqual(result['classification'],'defeat')
        self.assertTrue(result['trace']);self.assertEqual(result['terminal']['hp'],0)

    def test_timeout_never_becomes_defeat(self):
        result=runner.classify_log(self.case,'BALANCE TIMEOUT: fork seed=101\n',2)
        self.assertEqual(result['classification'],'censored')
        result=runner.classify_log(self.case,log_for(self.case),1,stop_kind='wall_timeout')
        self.assertEqual(result['classification'],'censored')

    def test_stop_and_infrastructure_are_distinct(self):
        self.assertEqual(runner.classify_log(self.case,'',1,stop_kind='STOP')['classification'],'aborted')
        self.assertEqual(runner.classify_log(self.case,'SCRIPT ERROR: bad\n',1,stop_kind='wall_timeout')['classification'],'invalid')

    def test_only_exact_known_exit_diagnostic_is_accepted(self):
        valid=log_for(self.case)
        for text in (valid.replace('2 resources','3 resources'),valid+'ERROR: another problem\n'):
            self.assertEqual(runner.classify_log(self.case,text,0)['classification'],'invalid')

    def test_missing_duplicate_wrong_identity_nonfinite_rejected(self):
        valid=log_for(self.case)
        for text in ('',valid+json.dumps({'result':'victory'})+'\n',valid.replace('"seed": 101','"seed": 102'),
                     valid.replace('"hp": 100.0','"hp": NaN')):
            self.assertEqual(runner.classify_log(self.case,text,0)['classification'],'invalid')

    def test_generated_command_has_only_fixed_and_enum_flags(self):
        command=runner.build_command(self.case,Path('C:/safe'))
        self.assertIn('steps=8',command);self.assertIn('profile=base',command)
        self.assertEqual(command[command.index('--fixed-fps')+1],'60')
        with self.assertRaises(ValueError):runner.build_command(dict(self.case,dev='invuln=1'),Path('C:/safe'))

    def test_parent_server_exe_argument_is_not_a_model_runner(self):
        parent={'name':'python.exe','cmdline':['python.exe','run_night.py','--server-exe','C:/AI/llama.cpp/llama-server.exe']}
        self.assertFalse(runner.foreign_runner(parent))
        self.assertTrue(runner.foreign_runner({'name':'llama-server.exe','cmdline':['llama-server.exe']}))
        self.assertTrue(runner.foreign_runner({'name':'python.exe','cmdline':['python.exe','-m','llama_cpp.server']}))

    def test_atomic_replace_retries_reader_collision_with_finite_bound(self):
        with tempfile.TemporaryDirectory() as name:
            path=Path(name)/'status.json';real_replace=Path.replace;calls=[]
            def replace(source,target):
                calls.append(1)
                if len(calls)==1:raise PermissionError('reader sharing')
                return real_replace(source,target)
            with patch.object(Path,'replace',replace),patch.object(runner.time,'sleep',return_value=None):
                runner.save(path,{'ok':True})
            self.assertEqual(json.loads(path.read_text()),{'ok':True});self.assertEqual(len(calls),2)
            with patch.object(Path,'replace',side_effect=PermissionError('still locked')), \
                 patch.object(runner.time,'monotonic',side_effect=[0,4]), self.assertRaises(PermissionError):
                runner.save(path,{'ok':False})
            self.assertEqual(json.loads(path.read_text()),{'ok':True})


class BatchTests(unittest.TestCase):
    def run_stub(self, *, pairs=2, stop=False, pressure=False, tamper=False, timeout=False, bad_queue_receipt=False,
                 ram_gib=32, workers=20, ram_after_first=None):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name);repo=root/'repo';(repo/'godot').mkdir(parents=True)
            (repo/'godot/project.godot').write_text('config_version=5',encoding='utf-8')
            collection=root/'collection';collection.mkdir();queue_path=collection/'queue.json'
            queue=schema.make_queue(proposal(),list(range(101,101+pairs)))
            runner.save(queue_path,queue);runtime=runner.runtime_manifest(repo)
            runner.save(collection/'before.json',{'runtime':runtime,'owner':{}})
            runner.save(collection/'after.json',{'runtime':runtime,'owner':{}})
            runner.save(collection/'collection-summary.json',{'status':'completed','collection_success':True,
                'queued':pairs*2,'manifest_errors':{},'unchanged':{'runtime':True,'owner':True},
                'queue_sha256':'wrong' if bad_queue_receipt else runner.record(queue_path)['sha256']})
            out=root/'out';instances=[];clock={'value':1000.0}
            class Process:
                def __init__(self, code):self.returncode=code
                def poll(self):return self.returncode
                def wait(self, timeout):return self.returncode
            class Job:
                def __init__(self):self.closed=False;self.process=None;instances.append(self)
                def spawn(self, command, **kwargs):
                    self.flags=kwargs['creationflags'];self.env=kwargs['env']
                    case=dict(version=1,map=command[command.index('--map')+1],bot=command[command.index('--bot')+1],
                              seed=int(command[command.index('--seed')+1]),difficulty='normal',profile='base')
                    kwargs['stdout'].write(log_for(case,'victory' if case['bot']=='selective' else 'defeat'));kwargs['stdout'].flush()
                    self.process=Process(None if timeout and len(instances)==1 else 0)
                    if timeout and len(instances)==1:clock['value']+=901
                    if tamper and len(instances)==1:queue_path.write_text(queue_path.read_text()+'\n',encoding='utf-8')
                    return self.process,{'pid':10000+len(instances),'create_time':1.0}
                def remaining(self):return []
                def stop(self, timeout=5):
                    if self.process and self.process.returncode is None:self.process.returncode=1
                    return {'owned_processes_dead':True,'before':[],'remaining':[],'identities':[]}
                def close(self):self.closed=True
            def snapshot(repo,path):
                if stop and not (out/'STOP').exists():(out/'STOP').touch()
                return {'runtime':runner.runtime_manifest(repo),'owner':{'exists':False,'files':{}},
                        'engine':{'sha256':'console'},'main_engine':{'sha256':'main'},'head':'frozen',
                        'queue':runner.record(path),'collection_receipts':{n:runner.record(path.parent/n)
                           for n in ('before.json','after.json','collection-summary.json')}}
            with patch.object(runner,'module',return_value=SimpleNamespace(OwnedJob=Job)), \
                 patch.object(runner,'snapshot',side_effect=snapshot), \
                 patch.object(runner.psutil,'process_iter',return_value=[]), \
                 patch.object(runner.psutil,'virtual_memory',side_effect=lambda:SimpleNamespace(available=(3 if pressure else
                     ram_after_first(instances) if callable(ram_after_first) else
                     ram_after_first if ram_after_first is not None and instances else ram_gib)*1024**3)), \
                 patch.object(runner.psutil,'cpu_percent',return_value=[0]*32), \
                 patch.object(runner.time,'monotonic',side_effect=lambda:clock['value']), \
                 patch.object(runner.time,'sleep',return_value=None):
                report=runner.run_batch(repo,queue_path,out,workers=workers)
            files=[json.loads((out/'cases'/f'{i:03}'/'result.json').read_text()) for i in range(len(instances))
                   if (out/'cases'/f'{i:03}'/'result.json').exists()]
            return report,instances,files

    def test_four_battles_losses_valid_and_pair_deltas_retained(self):
        report,jobs,files=self.run_stub()
        self.assertTrue(report['batch_acceptance'],report)
        self.assertEqual(report['classification_counts']['defeat'],2)
        self.assertEqual(report['paired_stats']['paired_win_counts']['control_only'],2)
        self.assertEqual(report['paired_stats']['metric_deltas']['hp']['values'],[-100.0,-100.0])
        self.assertTrue(all(not value['guard_pending'] and value['accepted'] for value in files))
        self.assertEqual(len({job.env['APPDATA'] for job in jobs}),4)
        self.assertTrue(all(job.flags & runner.subprocess.BELOW_NORMAL_PRIORITY_CLASS for job in jobs))

    def test_twenty_jobs_are_exact_ten_pairs(self):
        report,jobs,_=self.run_stub(pairs=10)
        self.assertEqual(len(jobs),20);self.assertEqual(report['paired_stats']['complete_pairs'],10)
        self.assertTrue(report['owned_processes_dead']);self.assertTrue(report['replay_complete'])

    def test_bad_collection_queue_hash_prevents_any_spawn(self):
        report,jobs,_=self.run_stub(bad_queue_receipt=True)
        self.assertEqual(jobs,[]);self.assertFalse(report['batch_acceptance'])
        self.assertEqual(report['status'],'error')

    def test_memory_admission_caps_requested_workers(self):
        for workers,ram,expected in ((1,32,1),(2,32,2),(4,32,4),(20,32,20),(20,9,4),(20,7,2),(20,6,1)):
            with self.subTest(workers=workers,ram=ram):
                report,jobs,_=self.run_stub(pairs=10,workers=workers,ram_gib=ram)
                self.assertEqual(report['requested_workers'],workers)
                self.assertEqual(report['effective_workers'],expected)
                self.assertLessEqual(report['peak_active_cases'],expected)
                self.assertEqual(len(jobs),20);self.assertTrue(report['batch_acceptance'])

    def test_memory_admission_stops_without_startup_reservation(self):
        report,jobs,_=self.run_stub(ram_gib=5.9)
        self.assertEqual(len(jobs),0)
        self.assertEqual(report['effective_workers'],0)
        self.assertEqual(report['stop_reason'],'memory_admission')

    def test_memory_drops_before_next_launch_retains_queue(self):
        report,jobs,_=self.run_stub(ram_gib=32,ram_after_first=5.9)
        self.assertEqual(len(jobs),1)
        self.assertEqual(report['classification_counts']['victory'],1)
        self.assertEqual(report['stop_reason'],'memory_admission')
        self.assertEqual(len(report['unrun']),3)

    def test_memory_admission_waits_for_active_drain_then_continues(self):
        def available(jobs):return 5.9 if any(not job.closed for job in jobs) else 32
        report,jobs,_=self.run_stub(pairs=10,ram_after_first=available)
        self.assertEqual(len(jobs),20)
        self.assertEqual(report['peak_active_cases'],1)
        self.assertEqual(report['effective_workers'],20)
        self.assertTrue(report['batch_acceptance'])

    def test_stop_or_ram_pressure_preserves_unrun(self):
        for options,reason in (({'stop':True},'STOP'),({'pressure':True},'memory_pressure')):
            report,jobs,_=self.run_stub(**options)
            self.assertEqual(jobs,[]);self.assertEqual(len(report['unrun']),4)
            self.assertEqual(report['stop_reason'],reason);self.assertFalse(report['batch_acceptance'])

    def test_queue_mutation_invalidates_all_provisional_results(self):
        report,jobs,files=self.run_stub(tamper=True)
        self.assertEqual(len(jobs),4);self.assertEqual(report['status'],'integrity_failure')
        self.assertFalse(report['batch_acceptance']);self.assertTrue(all(not value['accepted'] for value in files))

    def test_one_wall_timeout_is_censored_other_cases_finish_no_full_pass(self):
        report,jobs,_=self.run_stub(timeout=True)
        self.assertEqual(len(jobs),4);self.assertEqual(report['classification_counts']['censored'],1)
        self.assertEqual(report['classification_counts']['defeat'],2)
        self.assertFalse(report['replay_acceptance']);self.assertFalse(report['pilot_acceptance'])
        self.assertTrue(report['owned_processes_dead']);self.assertEqual(report['paired_stats']['complete_pairs'],1)


if __name__=='__main__':unittest.main()
