#!/usr/bin/env python

import sys
import random

from optparse import OptionParser

parser = OptionParser()
parser.add_option("-n", "--model-num", action="store", dest="n_model",
                  help="number of models to train", type="int")
parser.add_option("-r", "--sample-ratio", action="store", dest="ratio",
                  help="ratio to sample for each ensemble", type="float")

options, args = parser.parse_args(sys.argv)

random.seed(6505)

for ind, line in enumerate(sys.stdin):
    # TODO
    # Note: The following lines are only there to help 
    #       you get started (and to have a 'runnable' program). 
    #       You may need to change some or all of the lines below.
    #       Follow the pseudocode given in the PDF.
    m = random.random()
    if m < options.ratio:
        key = ind 
        value = line.strip()
        print "%d\t%s" % (key, value)
