from falcor import *

def render_graph_DirectRayTracer():
    g = RenderGraph("DirectRayTracer")
    AccumulatePass = createPass("AccumulatePass", {'enabled': True, 'precisionMode': 'Single'})
    g.addPass(AccumulatePass, "AccumulatePass")
    ToneMapper = createPass("ToneMapper", {'autoExposure': False, 'exposureCompensation': 0.0})
    g.addPass(ToneMapper, "ToneMapper")
    DirectRayTracer = createPass("DirectRayTracer", {})
    g.addPass(DirectRayTracer, "DirectRayTracer")
    VBufferRT = createPass("VBufferRT", {'samplePattern': 'Stratified', 'sampleCount': 16})
    g.addPass(VBufferRT, "VBufferRT")
    g.addEdge("AccumulatePass.output", "ToneMapper.src")
    g.addEdge("VBufferRT.vbuffer", "DirectRayTracer.vbuffer")
    g.addEdge("VBufferRT.viewW", "DirectRayTracer.viewW")
    g.addEdge("DirectRayTracer.color", "AccumulatePass.input")
    g.markOutput("ToneMapper.dst")
    return g

DirectRayTracer = render_graph_DirectRayTracer()
try: m.addGraph(DirectRayTracer)
except NameError: None
