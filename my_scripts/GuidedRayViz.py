from falcor import *

def render_graph_GuidedRayViz():
    g = RenderGraph('GuidedRayViz')
    AccumulatePass = createPass("AccumulatePass", {'enabled': True, 'precisionMode': 'Single'})
    g.addPass(AccumulatePass, "AccumulatePass")
    ToneMapper = createPass("ToneMapper", {'autoExposure': False, 'exposureCompensation': 0.0})
    g.addPass(ToneMapper, "ToneMapper")
    FocalGuiding = createPass("FocalGuiding", {'maxBounces': 3, 'computeDirect': True})
    g.addPass(FocalGuiding, "FocalGuiding")
    VBufferRT = createPass("VBufferRT", {'samplePattern': 'Stratified', 'sampleCount': 16})
    g.addPass(VBufferRT, "VBufferRT")
    FocalDensities = createPass("FocalDensities", {'maxPasses': 5, 'limitedPasses': True})
    g.addPass(FocalDensities, "FocalDensities")
    g.addEdge("VBufferRT.vbuffer", "FocalDensities.vbuffer")
    g.addEdge("VBufferRT.viewW", "FocalDensities.viewW")
    g.addEdge("FocalDensities", "FocalGuiding")
    g.addEdge("AccumulatePass.output", "ToneMapper.src")
    g.addEdge("VBufferRT.vbuffer", "FocalGuiding.vbuffer")
    g.addEdge("VBufferRT.viewW", "FocalGuiding.viewW")
    g.addEdge("FocalGuiding.color", "AccumulatePass.input")
    # visualization
    GuidedRayViz = createPass("GuidedRayViz", {})
    g.addPass(GuidedRayViz, "GuidedRayViz")
    VBufferViz = createPass("VBufferRT", {'sampleCount': 16})
    g.addPass(VBufferViz, "VBufferViz")
    GuidedRays = createPass("GuidedRays", {'maxBounces': 3, 'computeDirect': True})
    g.addPass(GuidedRays, "GuidedRays")
    g.addEdge("FocalGuiding", "GuidedRays")
    g.addEdge("VBufferViz.vbuffer", "GuidedRays.vbuffer")
    g.addEdge("VBufferViz.viewW", "GuidedRays.viewW")
    g.addEdge("GuidedRays", "GuidedRayViz")
    #g.addEdge("VBufferViz.vbuffer", "GuidedRayViz.vbuffer")
    #g.addEdge("VBufferViz.viewW", "GuidedRayViz.viewW")

    #composite
    Composite = createPass("Composite", {})
    g.addPass(Composite, "Composite")
    g.addEdge("ToneMapper.dst", "Composite.A")
    g.addEdge("GuidedRayViz.output", "Composite.B")

    # focal viz
    FocalViz = createPass("FocalViz", {})
    g.addPass(FocalViz, "FocalViz")
    g.addEdge("FocalDensities", "FocalViz")
    g.addEdge("VBufferRT.vbuffer", "FocalViz.vbuffer")
    g.addEdge("VBufferRT.viewW", "FocalViz.viewW")

    # outputs
    g.markOutput("Composite.out")
    g.markOutput("FocalViz.color")
    g.markOutput("ToneMapper.dst")
    g.markOutput("GuidedRays.color")
    g.markOutput("GuidedRayViz.output")
    return g


GuidedRayViz = render_graph_GuidedRayViz()
try: m.addGraph(GuidedRayViz)
except NameError: None
