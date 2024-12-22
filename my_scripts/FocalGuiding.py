from falcor import *

def render_graph_FocalGuiding():
    g = RenderGraph("FocalGuiding")
    AccumulatePass = createPass("AccumulatePass", {'enabled': True, 'precisionMode': 'Single'})
    g.addPass(AccumulatePass, "AccumulatePass")
    ToneMapper = createPass("ToneMapper", {'autoExposure': False, 'exposureCompensation': 0.0})
    g.addPass(ToneMapper, "ToneMapper")
    FocalGuiding = createPass("FocalGuiding", {'maxBounces': 3, 'computeDirect': True})
    g.addPass(FocalGuiding, "FocalGuiding")
    VBufferRT = createPass("VBufferRT", {'samplePattern': 'Stratified', 'sampleCount': 16})
    g.addPass(VBufferRT, "VBufferRT")
    FocalDensities = createPass("FocalDensities", {'maxPasses': 5, 'limitedPasses': True, 'useNarrowing': True})
    g.addPass(FocalDensities, "FocalDensities")
    g.addEdge("VBufferRT.vbuffer", "FocalDensities.vbuffer")
    g.addEdge("VBufferRT.viewW", "FocalDensities.viewW")
    g.addEdge("FocalDensities", "FocalGuiding")
    g.addEdge("AccumulatePass.output", "ToneMapper.src")
    g.addEdge("VBufferRT.vbuffer", "FocalGuiding.vbuffer")
    g.addEdge("VBufferRT.viewW", "FocalGuiding.viewW")
    g.addEdge("FocalGuiding.color", "AccumulatePass.input")
    # visualization
    FocalViz = createPass("FocalViz", {})
    g.addPass(FocalViz, "FocalViz")
    g.addEdge("FocalDensities", "FocalViz")
    g.addEdge("VBufferRT.vbuffer", "FocalViz.vbuffer")
    g.addEdge("VBufferRT.viewW", "FocalViz.viewW")
    # outputs
    g.markOutput("ToneMapper.dst")
    g.markOutput("FocalViz.color")
    return g

FocalGuiding = render_graph_FocalGuiding()
try: m.addGraph(FocalGuiding)
except NameError: None
