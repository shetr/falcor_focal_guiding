from falcor import *

def render_graph_GuidedRayVizTest():
    g = RenderGraph('GuidedRayViz')
    GuidedRayViz = createPass("GuidedRayViz")
    g.addPass(GuidedRayViz, "GuidedRayViz")
    g.markOutput("GuidedRayViz.output")
    return g

GuidedRayVizTest = render_graph_GuidedRayVizTest()
try: m.addGraph(GuidedRayVizTest)
except NameError: None
