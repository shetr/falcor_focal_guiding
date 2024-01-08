from falcor import *

def render_graph_SimplePathTracer():
    g = RenderGraph("SimplePathTracer")
    AccumulatePass = createPass("AccumulatePass", {'enabled': True, 'precisionMode': 'Single'})
    g.addPass(AccumulatePass, "AccumulatePass")
    ToneMapper = createPass("ToneMapper", {'autoExposure': False, 'exposureCompensation': 0.0})
    g.addPass(ToneMapper, "ToneMapper")
    SimplePathTracer = createPass("SimplePathTracer", {'maxBounces': 1, 'computeDirect': True})
    g.addPass(SimplePathTracer, "SimplePathTracer")
    VBufferRT = createPass("VBufferRT", {'samplePattern': 'Stratified', 'sampleCount': 16})
    g.addPass(VBufferRT, "VBufferRT")
    g.addEdge("AccumulatePass.output", "ToneMapper.src")
    g.addEdge("VBufferRT.vbuffer", "SimplePathTracer.vbuffer")
    g.addEdge("VBufferRT.viewW", "SimplePathTracer.viewW")
    g.addEdge("SimplePathTracer.color", "AccumulatePass.input")
    g.markOutput("ToneMapper.dst")
    return g

SimplePathTracer = render_graph_SimplePathTracer()
try: m.addGraph(SimplePathTracer)
except NameError: None
