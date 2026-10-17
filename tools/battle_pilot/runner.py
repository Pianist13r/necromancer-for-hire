"""Bounded complete battles from a paired, data-only queue. No model or source edits."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import statistics
import subprocess
import time

import psutil

HERE = Path(__file__).resolve().parent
ENGINE = Path('C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe')
MAIN_ENGINE = Path('C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64.exe')
OWNER_REL = Path('Godot/app_userdata/Некромант на аутсорсе')
MIN_RAM = 4 * 1024 ** 3
ADMISSION_HEADROOM = 1024 ** 3
WORKER_RESERVATION = 1024 ** 3
CASE_LIMIT = 900
GROUP_LIMIT = 1200
METRICS = ('hp','t','kills','lost','cauldron_dmg','army','avg_army','idle_unit_seconds')
ENV_KEYS = ('SystemRoot','WINDIR','PATH','PATHEXT','COMSPEC','TEMP','TMP','USERPROFILE','HOMEDRIVE',
            'HOMEPATH','LOCALAPPDATA','ProgramData','ProgramFiles','ProgramFiles(x86)','PROCESSOR_ARCHITECTURE')
BENIGN_EXIT = re.compile(r'^ERROR: 2 resources still in use at exit \(run with --verbose for details\)\.$')


def module(name, path):
    spec = importlib.util.spec_from_file_location(name,path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


schema = module('battle_schema',HERE/'schema.py')
feedback = module('battle_feedback',HERE/'feedback.py')


def stamp():
    return dt.datetime.now(dt.timezone(dt.timedelta(hours=5))).isoformat()


def save(path, value):
    path.parent.mkdir(parents=True,exist_ok=True)
    temp = path.with_suffix(path.suffix+'.tmp')
    temp.write_text(json.dumps(value,ensure_ascii=False,indent=2,allow_nan=False)+'\n',encoding='utf-8')
    end=time.monotonic()+3.0
    while True:
        try:
            temp.replace(path)
            return
        except PermissionError:
            if time.monotonic()>=end:raise
            time.sleep(.05)


def record(path):
    stat = path.lstat()
    if path.is_symlink() or getattr(stat,'st_file_attributes',0) & 0x400 or not path.is_file():
        raise RuntimeError(f'input is not an ordinary file: {path}')
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda:source.read(1024*1024),b''):
            digest.update(block)
    after = path.stat()
    if (stat.st_size,stat.st_mtime_ns) != (after.st_size,after.st_mtime_ns):
        raise RuntimeError(f'input changed while hashing: {path}')
    return {'sha256':digest.hexdigest(),'size':after.st_size,'mtime_ns':after.st_mtime_ns}


def ordinary_files(root, *, python_only=False, cache=False):
    if not root.exists():
        return []
    result = []
    for directory, subdirs, names in os.walk(root):
        path = Path(directory)
        if path.is_symlink() or getattr(path.lstat(),'st_file_attributes',0) & 0x400:
            raise RuntimeError(f'linked runtime directory: {path}')
        subdirs[:] = [name for name in subdirs if name != '__pycache__' and (not cache or name != '.godot')]
        for name in names:
            file = path/name
            if not python_only or file.suffix == '.py':
                result.append(file)
    return sorted(result)


def runtime_manifest(repo):
    """Shared collector/runner source footprint, including untracked runtime files."""
    paths = ordinary_files(repo/'godot',cache=True)
    for folder in ('night_pilot','battle_pilot'):
        paths += ordinary_files(repo/'tools'/folder,python_only=True)
    return {str(path.resolve()):record(path) for path in sorted(set(paths))}


def owner_manifest():
    root = Path(os.environ['APPDATA'])/OWNER_REL
    return {'exists':root.exists(),'files':{str(path.resolve()):record(path) for path in ordinary_files(root)}}


def content(manifest):
    return {key:value['sha256'] for key,value in manifest.items()}


def snapshot(repo, queue):
    return {'runtime':runtime_manifest(repo),'owner':owner_manifest(),
            'engine':record(ENGINE),'main_engine':record(MAIN_ENGINE),'queue':record(queue),
            'collection_receipts':{str(p.relative_to(queue.parent)):record(p) for p in queue.parent.rglob('*')
                if p.is_file() and p.name!='STOP'},
            'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip()}


def guard_changes(before, after):
    changes = {}
    for scope in ('runtime',):
        left,right = content(before[scope]),content(after[scope])
        diff = sorted(key for key in left.keys()|right.keys() if left.get(key)!=right.get(key))
        if diff:changes[scope]=diff
    if before['owner'] != after['owner']:changes['owner']=True
    for name in ('engine','main_engine','queue','head','collection_receipts'):
        if before[name] != after[name]:changes[name]=True
    return changes


def verify_collection(queue_path, queue, current):
    directory = queue_path.parent
    summary_path = directory/'collection-summary.json'
    summary = json.loads(summary_path.read_text(encoding='utf-8'))
    if 'attempt_protocol' in summary:feedback.verify_attempts(summary,directory,queue)
    if (summary.get('status')!='completed' or summary.get('collection_success') is not True
            or summary.get('queued')!=len(queue['cases']) or summary.get('manifest_errors')!={}
            or summary.get('queue_sha256')!=current['queue']['sha256']
            or summary.get('unchanged',{}).get('runtime') is not True
            or summary.get('unchanged',{}).get('owner') is not True):
        raise RuntimeError('battle collection was not successful and intact')
    before = json.loads((directory/'before.json').read_text(encoding='utf-8'))
    after = json.loads((directory/'after.json').read_text(encoding='utf-8'))
    if not before.get('runtime') or content(before['runtime']) != content(after.get('runtime',{})):
        raise RuntimeError('collection runtime source changed')
    if content(after['runtime']) != content(current['runtime']):
        raise RuntimeError('collection source does not match replay source')
    return {'summary_path':str(summary_path),'collection_success':True,'queued':len(queue['cases'])}


def build_command(case, repo, engine=ENGINE):
    case = schema.validate_case(case)
    return [str(engine),'--headless','--path',str(repo/'godot'),'--fixed-fps','60','--quit-after','60000',
            '--script','res://tests/legion_balance_runner.gd','--','--mute','--trace','--bot',case['bot'],
            '--seed',str(case['seed']),'--map',case['map'],'--quit-on-end','--dev','profile='+case['profile'],
            '--dev','difficulty='+case['difficulty'],'--dev','steps=8']


def _finite(value):
    if isinstance(value,float) and not math.isfinite(value):return False
    if isinstance(value,dict):return all(_finite(x) for x in value.values())
    if isinstance(value,list):return all(_finite(x) for x in value)
    return True


def classify_log(case, text, exit_code, *, stop_kind=None):
    case = schema.validate_case(case)
    result = {'classification':'invalid','reason':None,'terminal':None,'trace':[],
              'diagnostics':[],'errors':[],'profile_identity_evidence':'validated launch + frozen balance runner; terminal does not emit profile'}
    terminals, malformed = [], []
    for line in text.splitlines():
        if 'SCRIPT ERROR' in line or 'ERROR:' in line:
            result['diagnostics'].append(line)
            if 'SCRIPT ERROR' in line or not BENIGN_EXIT.fullmatch(line):result['errors'].append(line)
        if line.startswith('{'):
            try:
                value = json.loads(line)
                if type(value) is not dict or not _finite(value):raise ValueError('invalid/nonfinite JSON row')
                if 'result' in value:terminals.append(value)
                else:result['trace'].append(value)
            except (ValueError,TypeError) as exc:malformed.append(str(exc))
    if result['errors'] or malformed:
        result['reason']='engine_errors_or_malformed_json';result['parse_errors']=malformed
        return result
    if stop_kind in ('STOP','deadline','memory_pressure','group_timeout','batch_error'):
        result.update(classification='aborted',reason=stop_kind)
        return result
    if stop_kind=='wall_timeout' or 'BALANCE TIMEOUT:' in text:
        result.update(classification='censored',reason=stop_kind or 'simulation_timeout')
        return result
    if not terminals and exit_code==0:
        result.update(classification='invalid',reason='missing_terminal_frame_limit_unproven')
        return result
    if exit_code!=0 or len(terminals)!=1:
        result['reason']='unexpected_exit_or_terminal_count'
        return result
    terminal = terminals[0]
    identity = type(terminal.get('seed')) is int and all(terminal.get(key)==case[key] for key in ('map','seed','bot','difficulty'))
    numbers = all(type(terminal.get(key)) in (int,float) and math.isfinite(terminal[key]) for key in ('t','hp'))
    counters = all(type(terminal.get(key)) is int and terminal[key]>=0 for key in ('army','wave'))
    if not identity or not numbers or not counters or terminal.get('result') not in ('victory','defeat'):
        result['reason']='terminal_schema_or_identity_mismatch'
        return result
    if not 0<=terminal['t']<=1800.1 or not result['trace']:
        result['reason']='terminal_time_or_missing_trace'
        return result
    result.update(classification=terminal['result'],terminal=terminal,reason='complete_battle')
    return result


def paired_statistics(queue, results):
    indexed = {result['index']:result for result in results}
    pairs = []
    wins = dict(both_win=0,control_only=0,candidate_only=0,both_lose=0)
    distributions = {key:[] for key in METRICS}
    for pair_index,seed in enumerate(queue['seeds']):
        left,right = indexed.get(pair_index*2),indexed.get(pair_index*2+1)
        def side(value,index):
            terminal=value.get('terminal') or {} if value else {}
            return {'index':index,'classification':value['classification'] if value else 'unrun',
                    'result':terminal.get('result'),'case_sha256':queue['case_sha256'][index],
                    'metrics':{metric:terminal[metric] for metric in METRICS if type(terminal.get(metric)) in (int,float)}}
        pair = {'seed':seed,'control':side(left,pair_index*2),'candidate':side(right,pair_index*2+1),
                'comparable':False,'delta':{}}
        if left and right and all(value['classification'] in ('victory','defeat') for value in (left,right)):
            pair['comparable']=True
            a,b = left['terminal'],right['terminal']
            key = ('both_win' if a['result']==b['result']=='victory' else 'both_lose' if a['result']==b['result']=='defeat'
                   else 'control_only' if a['result']=='victory' else 'candidate_only')
            wins[key]+=1
            for metric in METRICS:
                if type(a.get(metric)) in (int,float) and type(b.get(metric)) in (int,float):
                    delta=b[metric]-a[metric]
                    pair['delta'][metric]=delta;distributions[metric].append(delta)
        pairs.append(pair)
    return {'planned_pairs':len(pairs),'complete_pairs':sum(p['comparable'] for p in pairs),
            'pairs':pairs,'paired_win_counts':wins,'delta_direction':'candidate minus control',
            'metric_deltas':{key:{'n':len(values),'values':values,'mean':statistics.mean(values),
                                 'median':statistics.median(values),'min':min(values),'max':max(values)}
                             for key,values in distributions.items() if values},
            'scope':'one map/difficulty/configuration contrast, fixed coordinator seeds; automated bot evidence'}


def parse_deadline(value):
    parsed = dt.datetime.fromisoformat(value)
    if parsed.tzinfo is None or parsed.utcoffset() is None:raise ValueError('deadline requires UTC offset')
    return parsed


def foreign_runner(info):
    """Match executable identity or an actual Python server invocation, not argument paths."""
    name=(info.get('name') or '').lower()
    argv=[str(x).lower() for x in info.get('cmdline') or []]
    if 'godot' in name or 'necromancer' in name:return True
    if name.startswith('llama') or 'ollama_llama_server' in name:return True
    if 'ollama' in name and ('runner' in name or any(x in ('run','runner') for x in argv[1:])):return True
    if 'python' in name:
        if '-m' in argv:
            index=argv.index('-m')
            if index+1<len(argv) and argv[index+1] in ('llama_cpp.server','llama_cpp.server.__main__'):return True
        scripts={Path(arg).name for arg in argv[1:] if arg.endswith('.py')}
        if scripts & {'llama-server.py','llama_cpp_server.py'}:return True
    return False


def run_batch(repo, queue_path, out, *, workers=20, deadline=None):
    if workers not in (1,2,4,20):raise ValueError('workers must be1/2/4/20')
    repo,queue_path,out = Path(repo).resolve(),Path(queue_path).resolve(),Path(out).resolve()
    if out.exists():raise ValueError('out must be fresh')
    if not (repo/'godot/project.godot').is_file():raise ValueError('repo is not a Godot project')
    queue_record = record(queue_path)
    if queue_record['size']>100000:raise ValueError('queue too large')
    queue = schema.validate_queue(json.loads(queue_path.read_text(encoding='utf-8')))
    if deadline is not None and (deadline.tzinfo is None or deadline.utcoffset() is None):
        raise ValueError('deadline must be timezone-aware')
    job_module = module('battle_owned_job',repo/'tools/night_pilot/owned_job.py')
    start=time.monotonic();remaining=GROUP_LIMIT
    if deadline is not None:remaining=min(remaining,(deadline-dt.datetime.now(dt.timezone.utc)).total_seconds())
    cleanup_reserve=workers*5+10
    work_deadline=start+remaining-cleanup_reserve
    out.mkdir(parents=True)
    report={'protocol':1,'workload':'battle','mode':'queued','status':'running','started_at':stamp(),
            'rounds_requested':1,'cases_requested':len(queue['cases']),'planned_pairs':len(queue['seeds']),
            'queue':str(queue_path),'queue_sha256':queue_record['sha256'],'case_sha256':queue['case_sha256'],
            'model_runs':0,'engine_runs':0,'queue_replayed':0,'replay_complete':False,'proposal':queue['proposal'],
            'workers':workers,'cleanup_reserve_s':cleanup_reserve,'records':[],'errors':[],
            'requested_workers':workers,'effective_workers':0,'peak_active_cases':0,
            'memory_admission':{'minimum_available_ram':MIN_RAM,'headroom_bytes':ADMISSION_HEADROOM,
                                'per_worker_reservation_bytes':WORKER_RESERVATION,'initial_available_bytes':None},
            'minimum_available_ram':MIN_RAM,'worker_priority':'BELOW_NORMAL_PRIORITY_CLASS'}
    before=None;active={};jobs=[];logs=[];owned={};death=[]
    completed={};stop_reason=None;pending=list(enumerate(queue['cases']))
    peaks={'peak_owned_rss':0,'minimum_available_ram':None,'peak_host_cpu_percent':0,'sample_count':0,'peak_live_cases':0}

    def event(kind, **data):
        item={'at':stamp(),'monotonic':time.monotonic(),'event':kind,**data}
        with (out/'events.jsonl').open('a',encoding='utf-8') as stream:stream.write(json.dumps(item)+'\n')
        return item

    def resources():
        memory=psutil.virtual_memory();cores=psutil.cpu_percent(percpu=True)
        processes=[]
        for job in jobs:
            if job.closed:continue
            for identity in job.remaining():
                if identity.get('create_time') is None:continue
                owned[identity['pid']]=identity
                try:
                    process=psutil.Process(identity['pid'])
                    if abs(process.create_time()-identity['create_time'])>.001:continue
                    nice=process.nice()
                    if nice!=psutil.BELOW_NORMAL_PRIORITY_CLASS:process.nice(psutil.BELOW_NORMAL_PRIORITY_CLASS);nice=process.nice()
                    cpu=process.cpu_times();rss=process.memory_info().rss
                    processes.append({**identity,'rss':rss,'cpu_s':cpu.user+cpu.system,'actual_priority':int(nice)})
                except psutil.Error:continue
        row={'at':stamp(),'monotonic':time.monotonic(),'memory_available':memory.available,
             'cpu_percent_per_core':cores,'owned_processes':processes,'active_cases':len(active),
             'live_cases':sum(worker['process'].poll() is None for worker in active.values())}
        with (out/'resources.jsonl').open('a',encoding='utf-8') as stream:stream.write(json.dumps(row)+'\n')
        peaks['sample_count']+=1;peaks['peak_owned_rss']=max(peaks['peak_owned_rss'],sum(p['rss'] for p in processes))
        peaks['peak_live_cases']=max(peaks['peak_live_cases'],row['live_cases'])
        peaks['minimum_available_ram']=memory.available if peaks['minimum_available_ram'] is None else min(peaks['minimum_available_ram'],memory.available)
        peaks['peak_host_cpu_percent']=max(peaks['peak_host_cpu_percent'],sum(cores)/len(cores) if cores else 0)

    def check():
        if (out/'STOP').exists():return 'STOP'
        if psutil.virtual_memory().available<MIN_RAM:return 'memory_pressure'
        if time.monotonic()>=work_deadline:return 'deadline'
        return None

    def foreign():
        for job in jobs:
            if not job.closed:
                for identity in job.remaining():
                    if identity.get('create_time') is not None:owned[identity['pid']]=identity
        found=[]
        for process in psutil.process_iter(['pid','name','cmdline','create_time']):
            try:
                info=process.info;identity=owned.get(info['pid'])
                if identity and abs(info['create_time']-identity['create_time'])<.001:continue
                if foreign_runner(info):found.append(info['pid'])
            except psutil.Error:continue
        if found:raise RuntimeError(f'foreign game/engine/model runner present: {found}')

    def finish(index, worker, stop_kind=None):
        observed=event('engine_end',index=index,exit_code=worker['process'].poll(),stop_kind=stop_kind)
        proof=worker['job'].stop(timeout=5);death.append({'index':index,**proof})
        worker['process'].wait(timeout=5)
        worker['log'].close();worker['job'].close()
        text=(worker['directory']/'engine.log').read_text(encoding='utf-8',errors='replace')
        result=classify_log(worker['case'],text,worker['process'].returncode,stop_kind=stop_kind)
        trace=result.pop('trace')
        save(worker['directory']/'trace.json',trace)
        result.update(index=index,label='control' if index%2==0 else 'candidate',case=worker['case'],
                      case_sha256=schema.case_fingerprint(worker['case']),started_at=worker['started_at'],
                      ended_at=observed['at'],identity=worker['identity'],wall_s=observed['monotonic']-worker['start'],
                      command=worker['command'],exit_code=worker['process'].returncode,
                      raw_log=record(worker['directory']/'engine.log'),trace_file='cases/'+f'{index:03}'+'/trace.json',
                      trace_sha256=record(worker['directory']/'trace.json')['sha256'],
                      guard_pending=True,accepted=None,death_proof=proof)
        save(worker['directory']/'result.json',result);completed[index]=result
        if not proof['owned_processes_dead']:raise RuntimeError('case job not empty after cleanup')

    try:
        foreign()
        event('guard_start',label='before');before=snapshot(repo,queue_path);save(out/'before.json',before);event('guard_end',label='before')
        if before['queue']!=queue_record:raise RuntimeError('queue changed between parsing and guard')
        report['collection']=verify_collection(queue_path,queue,before)
        initial_available=psutil.virtual_memory().available
        effective_workers=min(workers,max(0,int((initial_available-MIN_RAM-ADMISSION_HEADROOM)//WORKER_RESERVATION)))
        report['effective_workers']=effective_workers
        report['memory_admission']['initial_available_bytes']=initial_available
        event('memory_admission_plan',requested_workers=workers,effective_workers=effective_workers,
              **report['memory_admission'])
        admission_waiting=False
        psutil.cpu_percent(percpu=True)
        while pending or active:
            stop_reason=check()
            if stop_reason:break
            foreign()
            if not effective_workers:
                stop_reason='memory_admission';break
            while pending and len(active)<effective_workers:
                stop_reason=check()
                if stop_reason:break
                # Reserve a full slot for every active/newborn process, irrespective
                # of its tiny initial RSS. Deliberately conservative during startup.
                available=psutil.virtual_memory().available
                required=MIN_RAM+ADMISSION_HEADROOM+(len(active)+1)*WORKER_RESERVATION
                if available<required:
                    if not admission_waiting:
                        event('memory_admission_wait',available_bytes=available,required_bytes=required,
                              active_cases=len(active),pending_cases=len(pending))
                    admission_waiting=True
                    if not active:stop_reason='memory_admission'
                    break
                if admission_waiting:event('memory_admission_resumed',available_bytes=available,required_bytes=required)
                admission_waiting=False
                index,case=pending.pop(0);directory=out/'cases'/f'{index:03}';directory.mkdir(parents=True)
                appdata=directory/'appdata';appdata.mkdir()
                env={key:os.environ[key] for key in ENV_KEYS if key in os.environ}
                env.update(APPDATA=str(appdata),NECRO_NO_DEV_BRIDGE='1',NECRO_NO_METRICS='1')
                job=job_module.OwnedJob();jobs.append(job)
                log=(directory/'engine.log').open('w',encoding='utf-8');logs.append(log)
                command=build_command(case,repo)
                began=event('engine_start_requested',index=index)
                process,identity=job.spawn(command,cwd=repo,env=env,stdout=log,stderr=subprocess.STDOUT,
                                            creationflags=subprocess.BELOW_NORMAL_PRIORITY_CLASS)
                owned[identity['pid']]=identity
                worker={'case':case,'directory':directory,'job':job,'log':log,'process':process,
                        'identity':identity,'started_at':began['at'],'start':began['monotonic'],'command':command}
                active[index]=worker;report['engine_runs']+=1
                report['peak_active_cases']=max(report['peak_active_cases'],len(active))
                save(directory/'launch.json',{'at':began['at'],'case':case,'identity':identity,
                     'command':command,'appdata':str(appdata),'priority':'BELOW_NORMAL_PRIORITY_CLASS'})
                event('engine_started',index=index,identity=identity)
            resources()
            finished=[]
            for index,worker in list(active.items()):
                if worker['process'].poll() is not None:finished.append((index,worker,None))
                elif time.monotonic()-worker['start']>=CASE_LIMIT:finished.append((index,worker,'wall_timeout'))
            for index,worker,kind in finished:
                finish(index,worker,kind);del active[index]
            if stop_reason:break
            save(out/'progress.json',{'at':stamp(),'launched':report['engine_runs'],'classified':len(completed),'active':sorted(active),'pending':[i for i,c in pending]})
            time.sleep(.5)
        report['status']='stopped' if stop_reason else 'completed'
    except Exception as exc:
        report['status']='error';report['errors'].append(repr(exc));stop_reason='batch_error'
    finally:
        for index,worker in list(active.items()):
            try:finish(index,worker,stop_reason or 'batch_error')
            except Exception as exc:report['errors'].append(f'cleanup/result {index}: {exc!r}')
        for job in jobs:
            if not job.closed:
                try:death.append({'index':None,**job.stop(timeout=5)})
                except Exception as exc:death.append({'owned_processes_dead':False,'error':repr(exc)})
                finally:job.close()
        for log in logs:log.close()
        report['worker_cleanup']=death;report['owned_processes_dead']=all(p.get('owned_processes_dead') is True for p in death)
        report['owned_identities']=list(owned.values());report['records']=[completed[i] for i in sorted(completed)]
        report['unrun']=[{'index':i,'case':case} for i,case in enumerate(queue['cases']) if i not in completed]
        report['stop_reason']=stop_reason or 'batch_complete';report['resource_peaks']=peaks
        try:
            event('guard_start',label='after');after=snapshot(repo,queue_path);save(out/'after.json',after);event('guard_end',label='after')
            report['guard_changes']=guard_changes(before,after) if before is not None else {'before_missing':True}
        except Exception as exc:report['guard_changes']={'guard_error':repr(exc)}
        incomplete_guard=any(key in report['guard_changes'] for key in ('guard_error','before_missing'))
        report['unchanged']={key:not incomplete_guard and not report['guard_changes'].get(key)
                             for key in ('runtime','owner','engine','main_engine','queue','collection_receipts','head')}
        report['manifest_errors']={key:value for key,value in report['guard_changes'].items() if key in ('guard_error','before_missing')}
        if report['guard_changes']:report['status']='integrity_failure'
        report['classification_counts']={name:sum(r['classification']==name for r in report['records']) for name in ('victory','defeat','censored','invalid','aborted')}
        report['queue_replayed']=sum(r['classification']!='aborted' for r in report['records'])
        report['all_classified']=len(completed)==len(queue['cases'])
        report['data_integrity']=not report['guard_changes'] and report['owned_processes_dead'] and not report['errors'] and not report['classification_counts']['invalid']
        report['replay_complete']=report['all_classified'] and all(r['classification'] in ('victory','defeat') for r in report['records'])
        report['batch_complete']=report['replay_complete']
        report['batch_acceptance']=report['status']=='completed' and report['replay_complete'] and report['data_integrity']
        report['replay_acceptance']=report['batch_acceptance'];report['pilot_acceptance']=report['batch_acceptance']
        for result in report['records']:
            result.update(guard_pending=False,accepted=report['data_integrity'] and result['classification'] in ('victory','defeat'))
            save(out/'cases'/f'{result["index"]:03}'/'result.json',result)
        report['paired_stats']=paired_statistics(queue,report['records'])
        report['finished_at']=stamp();report['wall_s']=time.monotonic()-start
        save(out/'summary.json',report)
    return report


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo',type=Path,required=True);parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--queue',type=Path,required=True);parser.add_argument('--workers',type=int,choices=(1,2,4,20),default=20)
    parser.add_argument('--deadline',type=parse_deadline)
    args=parser.parse_args()
    result=run_batch(args.repo,args.queue,args.out,workers=args.workers,deadline=args.deadline)
    print(json.dumps({key:result[key] for key in ('status','batch_acceptance','classification_counts','owned_processes_dead','wall_s')},ensure_ascii=False))
    return 0 if result['batch_acceptance'] else 1


if __name__=='__main__':raise SystemExit(main())
