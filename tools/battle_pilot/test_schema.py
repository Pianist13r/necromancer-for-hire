"""Battle proposal/queue boundaries; no engines or models."""
import copy
import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('tested_battle_schema',Path(__file__).with_name('schema.py'))
schema=importlib.util.module_from_spec(spec);spec.loader.exec_module(schema)


def proposal():
    return {'version':1,'hypothesis':'Holding lines changes the paired losses.','map':'fork',
            'difficulty':'normal','candidate':{'bot':'hold','profile':'base'}}


class SchemaTests(unittest.TestCase):
    def test_twenty_fixed_coordinator_cases_and_control_order(self):
        queue=schema.make_queue(proposal(),list(range(101,111)))
        self.assertEqual(len(queue['cases']),20)
        self.assertEqual(queue['cases'][0]['bot'],'selective')
        self.assertEqual(queue['cases'][1]['bot'],'hold')
        self.assertEqual(queue['cases'][0]['seed'],queue['cases'][1]['seed'])
        self.assertEqual(schema.validate_queue(queue),queue)

    def test_only_documented_enums_and_integer_seed(self):
        case=schema.make_queue(proposal(),[101])['cases'][0]
        for field,value in (('seed',True),('seed',-1),('seed',2**31),('map','gen:1'),('bot','off'),
                            ('profile','custom'),('difficulty','expert'),('version',True)):
            with self.subTest(field=field,value=value),self.assertRaises(ValueError):
                schema.validate_case(dict(case,**{field:value}))

    def test_extra_dev_and_model_seed_fields_are_rejected(self):
        for extra in ({'seeds':[1]},{'dev':{'invuln':1}},{'code':'quit()'}):
            with self.assertRaises(ValueError):schema.validate_proposal(dict(proposal(),**extra))
        with self.assertRaises(ValueError):schema.validate_case(dict(schema.make_queue(proposal(),[1])['cases'][0],dev='stat_hp=999'))

    def test_identical_control_and_duplicate_seeds_rejected(self):
        with self.assertRaises(ValueError):schema.make_queue(dict(proposal(),candidate=dict(schema.CONTROL)),[1])
        with self.assertRaises(ValueError):schema.make_queue(proposal(),[1,1])

    def test_queue_cannot_change_case_hash_seed_label_or_order(self):
        queue=schema.make_queue(proposal(),[1,2])
        variants=[]
        value=copy.deepcopy(queue);value['cases'].reverse();variants.append(value)
        value=copy.deepcopy(queue);value['case_sha256'][0]='0'*64;variants.append(value)
        value=copy.deepcopy(queue);value['cases'][0]['seed']=3;variants.append(value)
        value=copy.deepcopy(queue);value['control']['bot']='hold';variants.append(value)
        value=copy.deepcopy(queue);value['coordinator']['seed_authority']='model';variants.append(value)
        for value in variants:
            with self.assertRaises(ValueError):schema.validate_queue(value)

    def test_rewording_hypothesis_does_not_make_new_comparison(self):
        a=proposal();b=dict(a,hypothesis='Same configuration with another explanation.')
        self.assertEqual(schema.comparison_fingerprint(a,[1,2]),schema.comparison_fingerprint(b,[1,2]))
        self.assertNotEqual(schema.proposal_fingerprint(a),schema.proposal_fingerprint(b))


if __name__=='__main__':unittest.main()
