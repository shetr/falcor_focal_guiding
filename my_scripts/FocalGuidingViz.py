from falcor import *

def render_graph_FocalGuidingViz():
    g = RenderGraph("FocalGuidingViz")
    FocalDensities = createPass("FocalDensities", {})
    g.addPass(FocalDensities, "FocalDensities")
    FocalViz = createPass("FocalViz", {})
    g.addPass(FocalViz, "FocalViz")
    VBufferRT = createPass("VBufferRT", {'sampleCount': 16})
    g.addPass(VBufferRT, "VBufferRT")
    g.addEdge("VBufferRT.vbuffer", "FocalDensities.vbuffer")
    g.addEdge("VBufferRT.viewW", "FocalDensities.viewW")
    g.addEdge("FocalDensities", "FocalViz")
    g.addEdge("VBufferRT.vbuffer", "FocalViz.vbuffer")
    g.addEdge("VBufferRT.viewW", "FocalViz.viewW")
    g.markOutput("FocalViz.color")
    return g

FocalGuidingViz = render_graph_FocalGuidingViz()
try: m.addGraph(FocalGuidingViz)
except NameError: None
