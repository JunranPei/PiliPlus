import unittest
from startup_resource_profile import startup_resource_profile, wait_startup_memory

class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.build={'buildMode':'release','leanTrace':True,
                    'defines':['PLAYBACK_TRACE_GEOMETRY=false']}

    def test_default_keeps_existing_thresholds_for_heavy_work(self):
        self.assertEqual(startup_resource_profile('default',seconds=60,build={},heavy=True),
            {'name':'default','startCommitGiB':8,'startPhysicalGiB':6,
             'abortCommitGiB':3,'abortPhysicalGiB':1})

    def test_qualified_short_run_retains_abort_and_physical_floors(self):
        result=startup_resource_profile('lean-short',seconds=22,build=self.build,heavy=False)
        self.assertEqual((result['startCommitGiB'],result['startPhysicalGiB'],
                          result['abortCommitGiB'],result['abortPhysicalGiB']),(7,6,3,1))

    def test_monitored_cohort_has_explicit_floor_and_stricter_runtime_stop(self):
        result=startup_resource_profile('lean-monitored',seconds=22,build=self.build,heavy=False)
        self.assertEqual((result['startCommitGiB'],result['startPhysicalGiB'],
                          result['abortCommitGiB'],result['abortPhysicalGiB']),(7,5,3,2))

    def test_heavy_long_or_unqualified_run_cannot_use_profile(self):
        for seconds,build,heavy in [(26,self.build,False),(22,self.build,True),
            (22,{**self.build,'buildMode':'profile'},False),
            (22,{**self.build,'leanTrace':False},False),(22,{},False),
            (22,{**self.build,'defines':['PLAYBACK_TRACE_GEOMETRY=true']},False),
            (22,{**self.build,'defines':self.build['defines']+['PLAYBACK_STARTUP_DEEP=true']},False)]:
            with self.subTest(seconds=seconds,build=build,heavy=heavy),self.assertRaises(ValueError):
                startup_resource_profile('lean-short',seconds=seconds,build=build,heavy=heavy)
            with self.subTest(profile='lean-monitored',seconds=seconds,build=build,heavy=heavy),self.assertRaises(ValueError):
                startup_resource_profile('lean-monitored',seconds=seconds,build=build,heavy=heavy)

class SettlingTests(unittest.TestCase):
    profile={'startCommitGiB':7,'startPhysicalGiB':6}

    def run_samples(self, rows, maximum=15):
        clock=[0.0]; observed=[];samples=iter(rows);last=[rows[-1]]
        def read():
            row=next(samples,last[0]);last[0]=row
            return {'commitHeadroomGiB':row[0],'availableRamGiB':row[1]}
        def sleep(seconds):clock[0]+=seconds
        result=wait_startup_memory(read,self.profile,maximum,
            monotonic=lambda:clock[0],sleep=sleep,observe=observed.append)
        self.assertEqual(result['samples'],observed)
        return result

    def test_one_transient_pass_does_not_release_input(self):
        result=self.run_samples([(8,5.9),(7,6),(7,5.9),(7,6),(7,6),(7,6)])
        self.assertTrue(result['ready'])
        self.assertEqual(len(result['samples']),6)
        self.assertEqual(result['elapsedSeconds'],12.5)

    def test_either_floor_failure_times_out_without_lowering_threshold(self):
        for row in [(6.99,8),(9,5.99)]:
            with self.subTest(row=row):
                result=self.run_samples([row],maximum=6)
                self.assertFalse(result['ready'])
                self.assertEqual(result['elapsedSeconds'],6)
                self.assertEqual((result['startCommitGiB'],result['startPhysicalGiB']),(7,6))

    def test_valid_boundaries_require_three_consecutive_samples(self):
        result=self.run_samples([(7,6)])
        self.assertTrue(result['ready'])
        self.assertEqual(result['elapsedSeconds'],5)
        self.assertEqual(len(result['samples']),3)

    def test_unbounded_or_zero_wait_is_rejected(self):
        for maximum in [0,-1,91,float('inf')]:
            with self.subTest(maximum=maximum),self.assertRaises(ValueError):
                wait_startup_memory(lambda:None,self.profile,maximum)


if __name__=='__main__':unittest.main()
