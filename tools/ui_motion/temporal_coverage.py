"""Bounded recorded-frame timing; no UI, decoding or interpolated-frame claims."""
from __future__ import annotations
import json,math,statistics

MAX_BYTES=1<<20
POLICY=dict(baselineSeconds=.100,firstPostSeconds=.0334,earlyWindowSeconds=.200,
            maximumEarlyGapSeconds=.0505,settledSeconds=.450,decodeToleranceSeconds=.002,
            minimumObservedLagSeconds=-.025,maximumObservedLagSeconds=.500)
REPORT_FIELDS=set('source width height requestedFPS maximumFrames diagnosticSampling queueDepth actionUptimeSeconds frames skippedInactiveFrames droppedEncoderFrames streamStopped writerCompleted videoBytes failureCode captureGeometry'.split())
FRAME_FIELDS=set('presentationSeconds receivedUptimeSeconds contentWidth contentHeight contentX contentY contentScale scaleFactor'.split())

class InvalidCapture(ValueError):pass

def number(value):
    if type(value)not in(int,float)or not math.isfinite(value):raise InvalidCapture('Finite numeric capture value required')
    return float(value)

def integer(value,lower,upper):
    if type(value)is not int or not lower<=value<=upper:raise InvalidCapture('Integer capture bound')
    return value

def decode(data):
    if not isinstance(data,bytes)or len(data)>MAX_BYTES:raise InvalidCapture('Capture report byte bound')
    def unique(pairs):
        result={}
        for key,value in pairs:
            if key in result:raise InvalidCapture('Duplicate capture field')
            result[key]=value
        return result
    value=json.loads(data,object_pairs_hook=unique)
    if not isinstance(value,dict)or set(value)-REPORT_FIELDS:raise InvalidCapture('Capture report fields')
    return value

def percentile(values,fraction):
    ordered=sorted(values)
    return ordered[max(0,math.ceil(len(ordered)*fraction)-1)]if ordered else None

def analyze(report,mode):
    if mode not in('full','reduced','off')or not isinstance(report,dict)or set(report)-REPORT_FIELDS:
        raise InvalidCapture('Capture mode or fields')
    if report.get('source')!='ScreenCaptureKit.currentProcess/single-window':raise InvalidCapture('Generated single-window source required')
    width=integer(report.get('width'),1,1280);height=integer(report.get('height'),1,800)
    if width*height>1152*800:raise InvalidCapture('Capture pixel bound')
    if report.get('requestedFPS')not in(60,120)or type(report['requestedFPS'])is not int:raise InvalidCapture('Requested rate')
    maximum=integer(report.get('maximumFrames'),3,180);integer(report.get('queueDepth'),1,8)
    integer(report.get('skippedInactiveFrames'),0,100000);dropped=integer(report.get('droppedEncoderFrames'),0,100000)
    integer(report.get('videoBytes'),1,4<<20)
    for name in('streamStopped','writerCompleted','diagnosticSampling'):
        if type(report.get(name))is not bool:raise InvalidCapture('Capture state type')
    failure=report.get('failureCode')
    if failure is not None:integer(failure,-(1<<31),(1<<31)-1)
    frames=report.get('frames')
    if not isinstance(frames,list)or not 3<=len(frames)<=maximum:raise InvalidCapture('Delivered frame bound')
    action=number(report.get('actionUptimeSeconds'));pts=[];received=[]
    for frame in frames:
        if not isinstance(frame,dict)or set(frame)-FRAME_FIELDS:raise InvalidCapture('Frame fields')
        pts.append(number(frame.get('presentationSeconds')));received.append(number(frame.get('receivedUptimeSeconds')))
        for field in FRAME_FIELDS-{'presentationSeconds','receivedUptimeSeconds'}:
            if frame.get(field)is not None:number(frame[field])
    if any(b<=a for a,b in zip(pts,pts[1:]))or any(b<a for a,b in zip(received,received[1:])):
        raise InvalidCapture('Nonmonotonic capture times')
    gaps=[b-a for a,b in zip(pts,pts[1:])];lags=[b-a for a,b in zip(pts,received)]
    aligned=all(POLICY['minimumObservedLagSeconds']<=lag<=POLICY['maximumObservedLagSeconds']for lag in lags)
    offsets=[x-action for x in pts]if aligned else []
    before=[x for x in offsets if -POLICY['baselineSeconds']<=x<0]
    after=[x for x in offsets if x>=0]
    early=[b-a for a,b in zip(offsets,offsets[1:])if b>=0 and a<=POLICY['earlyWindowSeconds']]
    checks=dict(observedClockComparisonAvailable=aligned,baselinePresent=bool(before),
        firstPostWithinBound=bool(after and after[0]<=POLICY['firstPostSeconds']),
        earlyGapsWithinBound=bool(early and max(early)<=POLICY['maximumEarlyGapSeconds']),
        settledSamplePresent=bool(after and after[-1]>=POLICY['settledSeconds']),
        encoderHadNoDrops=dropped==0,streamAndWriterCompleted=report['streamStopped']and report['writerCompleted']and failure is None)
    sufficient=all(checks.values())
    return dict(deliveredFrames=len(frames),requestedFPS=report['requestedFPS'],mode=mode,
        timingCoverage='sufficient'if sufficient else'insufficient'if aligned else'unavailable-clock-comparison',
        smoothnessApplicable=mode!='off',productVisualVerdict=None,checks=checks,
        observedMedianGapSeconds=statistics.median(gaps),observedP95GapSeconds=percentile(gaps,.95),observedMaximumGapSeconds=max(gaps),
        observedCallbackLagMedianSeconds=statistics.median(lags),observedCallbackLagP95Seconds=percentile(lags,.95),
        observedCallbackLagMaximumSeconds=max(lags),firstPostActionSeconds=after[0]if after else None,
        maximumEarlyGapSeconds=max(early)if early else None,actionOffsetsSeconds=offsets)

def validate_decoded(report,review,clip):
    if not isinstance(review,dict)or review.get('allDeliveredFramesDecoded')is not True or type(review.get('synthesizedFrames'))is not int or review['synthesizedFrames']!=0:
        raise InvalidCapture('Actual complete decoder proof required')
    if not isinstance(clip,dict)or clip.get('captureGeometryVerified')is not True or clip.get('decodedFrames')!=len(report['frames']):
        raise InvalidCapture('Decoded count or geometry differs')
    rows=clip.get('perFrame')
    if not isinstance(rows,list)or len(rows)!=len(report['frames']):raise InvalidCapture('Decoded per-frame count')
    action=number(report['actionUptimeSeconds'])
    for frame,row in zip(report['frames'],rows):
        if not isinstance(row,dict)or abs(number(row.get('actionSeconds'))-(number(frame['presentationSeconds'])-action))>POLICY['decodeToleranceSeconds']:
            raise InvalidCapture('Decoded action timing differs')
    return True
