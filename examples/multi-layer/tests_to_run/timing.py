################################################
#
# timing.py
# Avi Schwarzschild
# python script to run several runs
#   of GeoClaw to test new mulitlayer AMR
#
################################################

import os

### Run list:
### Single thread:
#        AMR on
#        AMR off
#   Multi thread (4 threads):
#        AMR on
#        AMR off



def run_test(outdir):
    for i in xrange(5):
        outdir = outdir + str(i)
        # Command strings
        run_cmd = 'touch setrun.py; make .output'
        plot_stats_cmd = 'python plot_timing_stats.py'
        save_cmd = 'mv _output %s' %(outdir)
        img_save_cmd = 'mv *.png %s/' %(outdir)

        os.system(run_cmd)
        os.system(plot_stats_cmd)
        os.system(save_cmd)
        os.system(img_save_cmd)

# two setrun files: setrun1.py setrun2.py
# setrun1.py has AMR at 4 levels with ratios [2,2,4]
#   and coarsest mesh at 120x120
# setrun2.py had no AMR and the resolution 
#   and the coarsest mesh at 1920x1920

def mt_on():
    os.environ["OMP_NUM_THREADS"] = '4'
    os.environ["FFLAGS"] = '-fopenmp'
    os.environ["OMP_STACKSIZE"] = '16M'
    os.system('ulimit -s unlimited')
    os.system('make new')

def mt_off():
    os.environ["FFLAGS"] = ''
    os.system('make new')

# First run:
    # setrun1 - single thread
os.system('cp setrun1.py setrun.py')
mt_off()
run_test('amr_single_thread_one_layer')


# Second run:
    # setrun1 - multithread
os.system('cp setrun1.py setrun.py')
mt_on()
run_test('amr_multi_thread_one_layer')


# Third run:
    # setrun2 - single thread
os.system('cp setrun2.py setrun.py')
mt_off()
run_test('no_amr_single_thread_one_layer')


# Fourth run:
    # setrun2 - multithread
os.system('cp setrun2.py setrun.py')
mt_on()
run_test('no_amr_multi_thread_one_layer')
