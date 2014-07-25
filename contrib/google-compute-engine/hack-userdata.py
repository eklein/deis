#!/usr/bin/python

import sys

try:
    import yaml
except ImportError:
    print "You need PyYaml."
    sys.exit(1)

import yaml

inject = {}
userdata = {}

with open("gce-inject.yaml", "r") as fin:
    inject = yaml.load(fin.read())

with open(sys.argv[1], "r") as fin:
    userdata = yaml.load(fin.read())

for unit in inject["units"]:
    userdata["coreos"]["units"].append(unit)

with open(sys.argv[2], "w") as fout:
    fout.write("#cloud-config\n\n")
    fout.write(yaml.dump(userdata))

