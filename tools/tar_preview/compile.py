#!/usr/bin/env python3
"""One observed driver, serial explicit Swift primary jobs and final link."""
import json
import subprocess
import sys

config = json.load(open(sys.argv[1]))
common = ['xcrun', 'swiftc', '-frontend', '-c', config['optimization'], '-parse-as-library', '-target', 'arm64-apple-macos15.0', '-sdk', config['sdk'], '-warnings-as-errors', '-swift-version', '6', '-strict-concurrency=complete', '-module-name', 'TARPreviewQualification', '-module-cache-path', config['cache'], '-I', config['module']]
objects = []
for index, primary in enumerate(config['files']):
    output = config['output'] + '-primary-' + str(index) + '.o'
    subprocess.run(common + ['-primary-file', primary] + [p for p in config['files'] if p != primary] + ['-o', output], check=True)
    objects.append(output)
subprocess.run(['xcrun', 'swiftc', '-target', 'arm64-apple-macos15.0', '-sdk', config['sdk'], *objects, config['coreObject'], '-o', config['output']], check=True)
