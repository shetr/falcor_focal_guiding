from falcor import *

def render_graph_FocalGuiding():
    g = RenderGraph("FocalGuiding")
    # general passes
    AccumulatePass = createPass("AccumulatePass", {'enabled': True, 'precisionMode': 'Single'})
    g.addPass(AccumulatePass, "AccumulatePass")
    ToneMapper = createPass("ToneMapper", {'autoExposure': False, 'exposureCompensation': 0.0})
    g.addPass(ToneMapper, "ToneMapper")
    VBufferRT = createPass("VBufferRT", {'samplePattern': 'Stratified', 'sampleCount': 16})
    g.addPass(VBufferRT, "VBufferRT")
    # focal guiding
    FocalGuiding = createPass("FocalGuiding", {'maxBounces': 3, 'computeDirect': True})
    g.addPass(FocalGuiding, "FocalGuiding")
    FocalDensities = createPass("FocalDensities", {'maxPasses': 5, 'limitedPasses': True, 'useNarrowing': True})
    g.addPass(FocalDensities, "FocalDensities")
    NodeSplitting = createPass("NodeSplitting", {'maxPasses': 5, 'limitedPasses': True})
    g.addPass(NodeSplitting, "NodeSplitting")
    NodePruning = createPass("NodePruning", {'usePruning': True, 'runInFrame': 6})
    g.addPass(NodePruning, "NodePruning")
    g.addEdge("VBufferRT.vbuffer", "FocalDensities.vbuffer")
    g.addEdge("VBufferRT.viewW", "FocalDensities.viewW")
    g.addEdge("FocalDensities", "NodeSplitting")
    g.addEdge("NodeSplitting", "NodePruning")
    g.addEdge("NodePruning", "FocalGuiding")
    g.addEdge("VBufferRT.vbuffer", "FocalGuiding.vbuffer")
    g.addEdge("VBufferRT.viewW", "FocalGuiding.viewW")
    g.addEdge("FocalGuiding.color", "AccumulatePass.input")
    g.addEdge("AccumulatePass.output", "ToneMapper.src")
    # outputs
    g.markOutput("ToneMapper.dst")
    return g


