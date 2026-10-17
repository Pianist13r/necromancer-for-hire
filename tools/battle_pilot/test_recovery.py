"""Bounded collection recovery; no model or engine is launched."""
import tempfile
import json
import copy
import threading
import time
from pathlib import Path
import unittest
from unittest.mock import patch
import collect
import feedback
import schema

P={'version':1,'hypothesis':'test','map':'archive','difficulty':'normal',
   'candidate':{'bot':'hold','profile':'base'}}

class RecoveryTests(unittest.TestCase):
    def test_prior_prediction_not_exposed_as_observed_result(self):
        false_prediction='Boss/intern already showed release losing all 10 pairs to selective (control-only)'
        prior={'proposal':P|{'hypothesis':false_prediction},'control':schema.CONTROL,
               'pairs':[],'seeds':list(range(10)),'raw_receipts':[{'path':'private'}]}
        original=copy.deepcopy(prior)
        history={'rows':[['boss','intern','release','base',10,[10,0,0,0],None]]}
        detail,latest=collect.observed_feedback(prior,history)
        self.assertNotIn(false_prediction,json.dumps(detail))
        self.assertNotIn('hypothesis',detail['proposal'])
        self.assertNotIn('raw_receipts',detail)
        self.assertEqual(prior,original)
        self.assertEqual(latest['pairs'],10)
        self.assertEqual(latest['control_wins'],10);self.assertEqual(latest['candidate_wins'],10)
        self.assertEqual(latest['paired_win_counts'],{'both_win':10,'control_only':0,'candidate_only':0,'both_lose':0})
        self.assertEqual(latest['map'],'boss');self.assertEqual(latest['difficulty'],'intern')
        self.assertEqual(latest['candidate'],{'bot':'release','profile':'base'})

    def test_latest_mixed_counts_and_empty_context(self):
        self.assertEqual(collect.observed_feedback(None,{'rows':[]}),(None,None))
        prior={'proposal':P,'control':schema.CONTROL}
        history={'rows':[['archive','normal','hold','base',10,[2,3,4,1],None]]}
        _,latest=collect.observed_feedback(prior,history)
        self.assertEqual(latest['pairs'],10)
        self.assertEqual(latest['control_wins'],5);self.assertEqual(latest['candidate_wins'],6)
        self.assertEqual(latest['paired_win_counts'],{'both_win':2,'control_only':3,'candidate_only':4,'both_lose':1})

    def test_full_prompt_filters_old_hypothesis_and_retains_counts_at_capacity(self):
        ctx=feedback.empty()
        false_prediction='Boss/intern already showed release losing all 10 pairs to selective (control-only)'
        ctx['prior_battle']={'proposal':P|{'hypothesis':false_prediction},'control':schema.CONTROL,
                            'pairs':['x'*12000],'raw_receipts':[]}
        original=copy.deepcopy(ctx)
        history={'rows':[['gatehouse','normal','selective','novice',10,[3,4,2,1],
                           [[10,-1.234e308] for _ in range(5)]] for _ in range(336)],
                 'numeric_rows_omitted':0}
        with patch.object(feedback,'history',return_value=history):
            _,_,request,_=self.run_selection([P],ctx)
        prompt=request.call_args.args[2]
        prompt['prior_rejections']=[{'attempt':i,'error':'x'*512} for i in (1,2)]
        text=collect.prompt_text(prompt)
        self.assertNotIn(false_prediction,text)
        self.assertEqual(ctx,original)
        self.assertEqual(prompt['latest_verified_outcome']['candidate_wins'],5)
        self.assertLess(list(prompt).index('latest_verified_outcome'),list(prompt).index('previous_actual_battles'))
        self.assertEqual(len(prompt['verified_history']['rows']),336)
        self.assertLessEqual(len((collect.SYSTEM+text).encode('utf-8')),48*1024)

    def test_full_capacity_history_is_bounded_without_losing_outcomes(self):
        rows=[['gatehouse','normal','selective','novice',10,[3,4,2,1],
               [[10,-1.234e308] for _ in range(5)]] for _ in range(336)]
        prompt={'verified_history':{'rows':rows,'numeric_rows_omitted':0},
                'latest_details':'x'*12000,'prior_rejections':[]}
        collect.bound_history_detail(prompt)
        self.assertEqual(len(rows),336)
        self.assertTrue(all(row[:6]==['gatehouse','normal','selective','novice',10,[3,4,2,1]] for row in rows))
        self.assertGreater(prompt['verified_history']['numeric_rows_omitted'],0)
        prompt['prior_rejections']=[{'attempt':i,'error':'x'*512} for i in (1,2)]
        self.assertLessEqual(len((collect.SYSTEM+collect.prompt_text(prompt)).encode()),collect.MAX_PROMPT_BYTES)

    def test_oversized_prompt_cannot_start_http(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(collect,'urlopen') as post:
            with self.assertRaisesRegex(ValueError,'byte budget'):
                collect.request_proposal('http://127.0.0.1:8081','local',{'x':'x'*50000},Path(tmp),10)
            post.assert_not_called()

    def run_selection(self, responses, ctx=None):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup)
        out=Path(tmp.name)
        state={'worker_runs':0,'model_request_runs':0,'attempts':[]}
        with patch.object(collect,'request_proposal',side_effect=responses) as request:
            result=collect.select_proposal('http://127.0.0.1:8081','local',ctx or feedback.empty(),
                list(range(10)),out,60,state,lambda:None)
        return result,state,request,out

    def test_duplicate_then_valid(self):
        ctx=feedback.empty();ctx['comparison_fingerprints']=[schema.comparison_fingerprint(P,list(range(10)))]
        valid=P|{'map':'boss'}
        result,state,request,out=self.run_selection([P,valid],ctx)
        self.assertEqual(result,valid);self.assertEqual(state['model_request_runs'],2)
        self.assertEqual(state['selection_source'],'model')
        self.assertIn('duplicate',request.call_args.args[2]['prior_rejections'][0]['error'])
        self.assertTrue((out/'attempts/001/proposal.json').exists())

    def test_three_rejections_choose_new_fallback(self):
        ctx=feedback.empty();ctx['comparison_fingerprints']=[schema.comparison_fingerprint(P,list(range(10)))]
        result,state,request,out=self.run_selection([P,ValueError('malformed'),TimeoutError('timeout')],ctx)
        self.assertEqual(request.call_count,3)
        self.assertEqual(state['selection_source'],'fallback')
        self.assertNotIn(schema.comparison_fingerprint(result,list(range(10))),ctx['comparison_fingerprints'])
        self.assertTrue((out/'fallback.json').exists())

    def test_coverage_turn_rejects_legal_outside_menu(self):
        result,state,request,out=self.run_selection([P|{'map':'wasteland'},P])
        self.assertEqual(state['model_request_runs'],2)
        self.assertIn('coverage_required',state['attempts'][0]['error'])
        self.assertEqual(result,P)

    def test_stop_never_falls_back(self):
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp);(out/'STOP').touch()
            with patch.object(collect,'request_proposal') as request,self.assertRaises(InterruptedError):
                collect.select_proposal('', '',feedback.empty(),list(range(10)),out,60,{},lambda:None)
            request.assert_not_called()

    def test_programming_integrity_error_not_retried(self):
        with self.assertRaisesRegex(RuntimeError,'integrity'):
            self.run_selection([RuntimeError('integrity')])

    def test_blocked_http_wall_deadline_no_late_artifact_writes(self):
        done=threading.Event()
        returned=threading.Event()
        def blocked(*args,**kwargs):
            done.wait(2)
            returned.set()
            raise TimeoutError('late socket timeout')
        with tempfile.TemporaryDirectory() as tmp,patch.object(collect,'urlopen',side_effect=blocked):
            out=Path(tmp);start=time.monotonic()
            try:
                with self.assertRaisesRegex(collect.RequestWallTimeout,'wall deadline'):
                    collect.request_proposal('http://127.0.0.1:8081','local',{},out,.08)
                self.assertLess(time.monotonic()-start,.5)
                self.assertFalse((out/'response.bin').exists())
            finally:done.set()
            self.assertTrue(returned.wait(1))
            self.assertFalse((out/'response.bin').exists())

    def test_request_wall_timeout_fallback_without_second_request(self):
        result,state,request,out=self.run_selection([collect.RequestWallTimeout('wall deadline')])
        self.assertEqual(request.call_count,1)
        self.assertEqual(state['selection_source'],'fallback')
        self.assertEqual(state['fallback_reason'],'request_wall_timeout')
        self.assertTrue(state['attempts'][0]['response_incomplete'])
        (out/'attempts/001/request.json').write_text('{}')
        state['attempt_receipts']={str(f.relative_to(out)):feedback.digest(f) for f in out.rglob('*') if f.is_file()}
        feedback.verify_attempts(state,out,schema.make_queue(result,list(range(10))))
        state['fallback_reason']='bounded_rejections'
        with self.assertRaisesRegex(ValueError,'invalid fallback'):
            feedback.verify_attempts(state,out,schema.make_queue(result,list(range(10))))

    def test_audited_attempt_seal_and_raw_acceptance(self):
        class Response:
            def __enter__(self):return self
            def __exit__(self,*args):pass
            def read(self,*args):return json.dumps({'choices':[{'finish_reason':'stop',
                'message':{'content':json.dumps(P)}}]}).encode()
        with tempfile.TemporaryDirectory() as tmp,patch.object(collect,'urlopen',return_value=Response()):
            out=Path(tmp);state={}
            p=collect.select_proposal('http://127.0.0.1:8081','local',feedback.empty(),list(range(10)),out,60,state,lambda:None)
            q=schema.make_queue(p,list(range(10)))
            state['attempt_receipts']={str(f.relative_to(out)):feedback.digest(f) for f in out.rglob('*') if f.is_file()}
            feedback.verify_attempts(state,out,q)
            (out/'attempts/001/response.bin').write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError,'receipts changed'):feedback.verify_attempts(state,out,q)

    def test_stop_after_response_no_fallback_or_second_request(self):
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp)
            def response(*args):
                (out/'STOP').touch();return P
            with patch.object(collect,'request_proposal',side_effect=response) as request:
                with self.assertRaises(InterruptedError):
                    collect.select_proposal('','',feedback.empty(),list(range(10)),out,60,{},lambda:None)
            self.assertEqual(request.call_count,1);self.assertFalse((out/'fallback.json').exists())

if __name__=='__main__':unittest.main()
