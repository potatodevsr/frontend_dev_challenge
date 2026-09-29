#!/usr/bin/env python3
"""Capture the native VM data used by DevTools; requires a debug Flutter app.

Usage: python3 tool/capture_home_profile.py VM_SERVICE_URL OUTPUT_PREFIX
Runs against the supplied fake backend and scrolls the loaded Home catalog.
Simulator/debug values are diagnostic, never release-performance claims.
"""
import collections
import gzip
import json
import pathlib
import sys
import time
import urllib.parse
import urllib.request

base = sys.argv[1].rstrip('/') + '/'
prefix = pathlib.Path(sys.argv[2])
prefix.parent.mkdir(parents=True, exist_ok=True)


def rpc(method, **params):
    url = base + method + '?' + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=30) as response:
        data = json.load(response)
    if 'error' in data:
        raise RuntimeError(data['error'])
    return data['result']


vm = rpc('getVM')
isolate = next(i['id'] for i in vm['isolates'] if i['name'] == 'main')


def action(name, **params):
    return rpc('ext.rescu.homeProfile', isolateId=isolate, action=name, **params)


def snapshot():
    return {**action('snapshot'), 'memory': rpc('getMemoryUsage', isolateId=isolate)}


def scroll_to(target):
    action('scroll', to=target)
    time.sleep(1)


# Load the unmodified backend catalog using the normal pagination controller.
action('load')
rpc('setVMTimelineFlags', recordedStreams='[Dart,Embedder,GC]')
rpc('ext.flutter.profileWidgetBuilds', isolateId=isolate, enabled='true')
initial = snapshot()
rpc('clearVMTimeline')
time.sleep(5)
idle = rpc('getVMTimeline')
with gzip.open(prefix.parent / (prefix.name + '-idle-timeline.json.gz'), 'wt') as file:
    json.dump(idle, file)
rpc('clearVMTimeline')
for _ in range(2):
    scroll_to('bottom')
    scroll_to('top')
scroll = rpc('getVMTimeline')
with gzip.open(prefix.parent / (prefix.name + '-scroll-timeline.json.gz'), 'wt') as file:
    json.dump(scroll, file)
final = snapshot()
rpc('ext.flutter.profileWidgetBuilds', isolateId=isolate, enabled='false')


def counts(timeline):
    return dict(collections.Counter(e['name'] for e in timeline['traceEvents']
                                    if e.get('ph') in ('B', 'X')))


summary = {'runtime': {key: vm.get(key) for key in
                       ['version', 'operatingSystem', 'targetCPU']},
           'scenario': 'load catalog, idle 5s, two 4s down/up scroll cycles',
           'before_scroll': initial, 'after_scroll': final,
           'idle_events': counts(idle), 'scroll_events': counts(scroll),
           'idle_retained_seconds': idle.get('timeExtentMicros', 0) / 1e6,
           'scroll_retained_seconds': scroll.get('timeExtentMicros', 0) / 1e6}
(prefix.parent / (prefix.name + '-summary.json')).write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2))
